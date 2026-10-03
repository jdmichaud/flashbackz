//! Clocked movie presentation with bounded streaming and a separate PCM read-ahead queue.
const std = @import("std");
const platform = @import("../platform.zig");
const sequence = @import("../content/sequence.zig");
const palette = @import("../content/palette.zig");

pub const Player = struct {
    allocator: std.mem.Allocator,
    stream: sequence.Stream,
    origin: ?u64 = null,
    audio_attempted: bool = false,
    format: ?platform.AudioFormat = null,
    audio_buffer: []i16 = &.{},
    pending_samples: usize = 0,
    pending_cursor: usize = 0,
    next_audio_frame: usize = 0,
    produced_audio_frames: u64 = 0,
    previous_sample: i16 = 0,

    pub fn open(allocator: std.mem.Allocator, source: platform.AssetSource, path: []const u8) !Player {
        return .{ .allocator = allocator, .stream = try sequence.Stream.open(allocator, source, path) };
    }

    pub fn deinit(self: *Player) void {
        self.allocator.free(self.audio_buffer);
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn stopAudio(self: *Player, p: *platform.Platform) void {
        if (self.format != null) p.audioClose();
        self.format = null;
    }

    pub fn update(self: *Player, p: *platform.Platform) !bool {
        const now = p.nowNs();
        if (self.origin == null) self.origin = now;
        if (!self.audio_attempted) {
            self.audio_attempted = true;
            self.format = p.audioOpen(.{ .sample_rate = sequence.sample_rate, .channels = 1 }) catch null;
            if (self.format) |format| {
                if (format.channels == 0 or format.channels > 8 or format.sample_rate == 0 or format.sample_rate > 192000) {
                    self.stopAudio(p);
                } else {
                    const capacity = (@as(usize, format.sample_rate) / 25 + 2) * format.channels;
                    self.audio_buffer = try self.allocator.alloc(i16, capacity);
                }
            }
        }
        try self.feedAudio(p);
        var work: usize = 0;
        while (self.needsCatchup(now) and work < 4) : (work += 1) {
            if (!try self.stream.next()) break;
        }
        const finished = now -| self.origin.? >= self.stream.frameCount() * sequence.frame_ns;
        return finished and (self.format == null or (self.next_audio_frame == self.stream.frameCount() and self.pending_cursor == self.pending_samples and p.audioStatus().queued_frames == 0));
    }

    pub fn needsCatchup(self: *const Player, now: u64) bool {
        return if (self.origin) |origin| self.stream.frames < self.stream.frameCount() and now -| origin >= self.stream.frames * sequence.frame_ns else false;
    }

    fn feedAudio(self: *Player, p: *platform.Platform) !void {
        const format = self.format orelse return;
        var work: usize = 0;
        while (work < 6) : (work += 1) {
            if (self.pending_cursor < self.pending_samples) {
                const accepted = try p.audioQueue(self.audio_buffer[self.pending_cursor..self.pending_samples]);
                self.pending_cursor += accepted * format.channels;
                if (self.pending_cursor < self.pending_samples) return;
            }
            if (p.audioStatus().queued_frames >= format.sample_rate / 8 or self.next_audio_frame == self.stream.frameCount()) return;
            var samples: [sequence.samples_per_frame]i16 = undefined;
            try self.stream.readAudio(self.next_audio_frame, &samples);
            const input_start = @as(u64, self.next_audio_frame) * sequence.samples_per_frame;
            const output_end = (input_start + sequence.samples_per_frame) * format.sample_rate / sequence.sample_rate;
            const count: usize = @intCast(output_end - self.produced_audio_frames);
            if (count * format.channels > self.audio_buffer.len) return error.MovieAudioOverflow;
            for (0..count) |i| {
                const source_sample = (self.produced_audio_frames + i) * sequence.sample_rate / format.sample_rate;
                const sample = if (source_sample < input_start) self.previous_sample else samples[@intCast(source_sample - input_start)];
                @memset(self.audio_buffer[i * format.channels ..][0..format.channels], sample);
            }
            self.previous_sample = samples[samples.len - 1];
            self.produced_audio_frames = output_end;
            self.next_audio_frame += 1;
            self.pending_samples = count * format.channels;
            self.pending_cursor = 0;
        }
    }

    pub fn draw(self: *const Player, indices: []u8, rgba: []u8) !void {
        if (indices.len != 320 * 200) return error.InvalidMovieFrame;
        @memset(indices, 0);
        for (0..sequence.height) |row| @memcpy(indices[(36 + row) * 320 + 32 ..][0..sequence.width], self.stream.pixels[row * sequence.width ..][0..sequence.width]);
        try palette.writeRgba(indices, &self.stream.colors, rgba);
    }
};
