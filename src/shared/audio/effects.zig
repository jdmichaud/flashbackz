//! Four digital effect voices, mixed in short source blocks and resampled for the host.
//! The simulation submits entry events; device queueing never changes game movement.
const std = @import("std");
const platform = @import("../platform.zig");
const sounds = @import("../content/sound_effects.zig");
const SoundId = @import("../motion.zig").SoundId;
pub const Event = struct { sound: SoundId, attenuation: u2 = 0 };
const Voice = struct { sound: SoundId, cursor: usize = 0, attenuation: u2 };
pub const Mixer = struct {
    voices: [4]?Voice = @splat(null),
    block: [70]i8 = @splat(0),
    cursor: usize = 70,
    fraction: u64 = 0,
    pub fn start(self: *Mixer, bank: sounds.Bank, event: Event) void {
        const id = @backingInt(event.sound);
        if (id >= bank.samples.len or bank.samples[id].pcm.len == 0) return;
        var free: ?usize = null;
        for (self.voices, 0..) |voice, i| {
            if (voice) |playing| {
                if (playing.sound == event.sound) {
                    self.voices[i] = .{ .sound = event.sound, .attenuation = event.attenuation };
                    return;
                }
            } else if (free == null) free = i;
        }
        if (free) |index| self.voices[index] = .{ .sound = event.sound, .attenuation = event.attenuation };
    }
    fn fill(self: *Mixer, bank: sounds.Bank) void {
        var first = true;
        @memset(&self.block, 0);
        for (&self.voices) |*slot| if (slot.*) |*voice| {
            const pcm = bank.samples[@backingInt(voice.sound)].pcm;
            const count = @min(self.block.len, pcm.len - voice.cursor);
            const shift: u3 = @as(u3, voice.attenuation) * 2;
            for (pcm[voice.cursor..][0..count], self.block[0..count]) |sample, *target| {
                const value = sample >> shift;
                if (first) target.* = value else target.* +%= value;
            }
            if (first and count != 0) @memset(self.block[count..], self.block[count - 1]);
            first = false;
            voice.cursor += count;
            if (pcm.len - voice.cursor <= 4) slot.* = null;
        };
        self.cursor = 0;
    }
    pub fn render(self: *Mixer, bank: sounds.Bank, output: []i16, rate: u32) void {
        std.debug.assert(output.len % 2 == 0 and rate >= 8000);
        var i: usize = 0;
        while (i < output.len) : (i += 2) {
            if (self.cursor == self.block.len) self.fill(bank);
            const value: i16 = @as(i16, self.block[self.cursor]) * 256;
            output[i] = value;
            output[i + 1] = value;
            // Original Sound Blaster time constant: 256 - floor(1,000,000 / 6000).
            self.fraction += 1_000_000;
            const period = @as(u64, rate) * 166;
            while (self.fraction >= period) {
                self.fraction -= period;
                self.cursor += 1;
                if (self.cursor == self.block.len) self.fill(bank);
            }
        }
    }
};
pub const Output = struct {
    mixer: Mixer = .{},
    opened: bool = false,
    started: bool = false,
    rate: u32 = 44100,
    pending: [2048]i16 = undefined,
    begin: usize = 0,
    end: usize = 0,
    pub fn submit(self: *Output, bank: sounds.Bank, event: Event) void {
        self.mixer.start(bank, event);
        self.started = true;
    }
    pub fn pump(self: *Output, bank: sounds.Bank, p: *platform.Platform) !void {
        if (!self.started) return;
        if (!self.opened) {
            const format = try p.audioOpen(.{ .sample_rate = self.rate, .channels = 2 });
            if (format.channels != 2) {
                p.audioClose();
                return error.UnsupportedEffectsAudioFormat;
            }
            self.rate = format.sample_rate;
            self.opened = true;
        }
        const ahead = self.rate / 50;
        for (0..8) |_| {
            const status = p.audioStatus();
            if (!status.running or status.suspended or status.queued_frames >= ahead) return;
            if (self.begin == self.end) {
                const frames: usize = @intCast(@min(self.pending.len / 2, ahead - status.queued_frames));
                self.begin = 0;
                self.end = frames * 2;
                self.mixer.render(bank, self.pending[0..self.end], self.rate);
            }
            const accepted = try p.audioQueue(self.pending[self.begin..self.end]);
            self.begin += accepted * 2;
            if (accepted == 0) return;
        }
    }
    pub fn stop(self: *Output, p: *platform.Platform) void {
        if (self.opened) p.audioClose();
        self.* = .{};
    }
};

test "effects mixer restarts identical cues and preserves wrapping byte mixing" {
    var positive: [72]i8 = @splat(100);
    var samples = [_]sounds.Sample{ .{ .pcm = &positive }, .{ .pcm = &positive } };
    const bank: sounds.Bank = .{ .allocator = std.testing.allocator, .samples = &samples };
    var mixer: Mixer = .{};
    mixer.start(bank, .{ .sound = @fromBackingInt(0) });
    mixer.start(bank, .{ .sound = @fromBackingInt(0) });
    try std.testing.expect(mixer.voices[1] == null);
    mixer.start(bank, .{ .sound = @fromBackingInt(1) });
    var output: [2]i16 = undefined;
    mixer.render(bank, &output, 44100);
    try std.testing.expectEqual(@as(i16, -56 * 256), output[0]);
    try std.testing.expectEqual(output[0], output[1]);
}
