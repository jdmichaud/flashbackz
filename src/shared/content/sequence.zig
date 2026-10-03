//! Streaming import of the CD's SEQ movies. Container packets assemble video records;
//! the tile decoder maintains an owned indexed image and exposes the original PCM samples.
const std = @import("std");
const platform = @import("../platform.zig");
const palette = @import("palette.zig");

pub const width = 256;
pub const height = 128;
pub const packet_size = 6144;
pub const samples_per_frame = 882;
pub const sample_rate = 22050;
pub const frame_ns = 40_000_000;
const Buffer = struct { bytes: []u8 = &.{}, used: usize = 0 };

pub const Stream = struct {
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    file: platform.OpenedAsset,
    buffers: [30]Buffer = @splat(.{}),
    packet: [packet_size]u8 = undefined,
    packet_index: usize = 0,
    pixels: []u8,
    colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    audio: [samples_per_frame]i16 = @splat(0),
    frames: usize = 0,
    changed: bool = false,

    pub fn open(allocator: std.mem.Allocator, source: platform.AssetSource, path: []const u8) !Stream {
        const file = try source.open(path);
        errdefer source.close(file.handle);
        if (file.length < 102 * packet_size or file.length > 512 * 1024 * 1024 or file.length % packet_size != 0) return error.InvalidSequenceLength;
        const pixels = try allocator.alloc(u8, width * height);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        var self: Stream = .{ .allocator = allocator, .source = source, .file = file, .pixels = pixels };
        errdefer for (&self.buffers) |*buffer| allocator.free(buffer.bytes);
        try self.readPacket();
        for (self.packet[0..256]) |byte| if (byte != 0) return error.InvalidSequenceHeader;
        var ended = false;
        for (&self.buffers, 0..) |*buffer, i| {
            const size = word(&self.packet, 256 + i * 2);
            if (size == 0) {
                ended = true;
            } else {
                if (ended) return error.InvalidSequenceBuffers;
                buffer.bytes = try allocator.alloc(u8, size);
            }
        }
        for (0..100) |_| {
            self.packet_index += 1;
            try self.readPacket();
            try self.assemble(false);
        }
        return self;
    }

    pub fn deinit(self: *Stream) void {
        self.source.close(self.file.handle);
        for (self.buffers) |buffer| self.allocator.free(buffer.bytes);
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    fn readPacket(self: *Stream) !void {
        var read: usize = 0;
        const offset = @as(u64, self.packet_index) * packet_size;
        while (read != packet_size) {
            const n = try self.source.readAt(self.file.handle, offset + read, self.packet[read..]);
            if (n == 0) return error.TruncatedSequence;
            read += n;
        }
    }

    pub fn next(self: *Stream) !bool {
        if ((self.packet_index + 1) * packet_size >= self.file.length) return false;
        self.packet_index += 1;
        try self.readPacket();
        try self.assemble(true);
        self.frames += 1;
        return true;
    }

    pub fn frameCount(self: *const Stream) usize {
        return @as(usize, @intCast(self.file.length / packet_size)) - 101;
    }

    /// Audio is read independently so the host queue can stay ahead without displaying
    /// future video frames. Reads share the immutable file, not a mutable seek position.
    pub fn readAudio(self: *const Stream, frame: usize, output: *[samples_per_frame]i16) !void {
        if (frame >= self.frameCount()) return error.SequenceAudioPastEnd;
        const base = @as(u64, frame + 101) * packet_size;
        var header: [2]u8 = undefined;
        try readExact(self.source, self.file.handle, base, &header);
        const offset = word(&header, 0);
        if (offset == 0) {
            @memset(output, 0);
            return;
        }
        if (offset < 16 or offset > packet_size - samples_per_frame * 2) return error.InvalidSequenceAudio;
        var data: [samples_per_frame * 2]u8 = undefined;
        try readExact(self.source, self.file.handle, base + offset, &data);
        for (output, 0..) |*sample, i| sample.* = std.mem.readInt(i16, data[i * 2 ..][0..2], .big);
    }

    fn assemble(self: *Stream, visible: bool) !void {
        var offsets: [4]usize = undefined;
        for (&offsets, 0..) |*offset, i| offset.* = word(&self.packet, 8 + i * 2);
        for (0..3) |part| {
            const start = offsets[part];
            if (start == 0) continue;
            var following = part + 1;
            while (following < 3 and offsets[following] == 0) : (following += 1) {}
            const end = offsets[following];
            const slot = self.packet[5 + part];
            if (slot >= self.buffers.len or start < 16 or end <= start or end > packet_size) return error.InvalidSequenceChunk;
            const buffer = &self.buffers[slot];
            const length = end - start;
            if (length > buffer.bytes.len - buffer.used) return error.SequenceBufferOverflow;
            @memcpy(buffer.bytes[buffer.used..][0..length], self.packet[start..end]);
            buffer.used += length;
        }
        self.changed = false;
        const selected = self.packet[4];
        if (selected != 255) {
            if (!visible or selected >= self.buffers.len) return error.InvalidSequenceDisplay;
            const buffer = &self.buffers[selected];
            try decodeTiles(buffer.bytes[0..buffer.used], self.pixels);
            buffer.used = 0;
            self.changed = true;
        }
        if (!visible) return;
        const color_offset = word(&self.packet, 2);
        if (color_offset != 0) {
            if (color_offset < 16 or color_offset > packet_size - 768) return error.InvalidSequencePalette;
            for (&self.colors, 0..) |*color, i| {
                const rgb = self.packet[color_offset + i * 3 ..][0..3];
                for (rgb) |component| if (component > 63) return error.InvalidSequenceColor;
                color.* = .{ .r = expand(rgb[0]), .g = expand(rgb[1]), .b = expand(rgb[2]) };
            }
            self.changed = true;
        }
        const sound_offset = word(&self.packet, 0);
        if (sound_offset == 0) {
            @memset(&self.audio, 0);
        } else {
            if (sound_offset < 16 or sound_offset > packet_size - samples_per_frame * 2) return error.InvalidSequenceAudio;
            for (&self.audio, 0..) |*sample, i| sample.* = std.mem.readInt(i16, self.packet[sound_offset + i * 2 ..][0..2], .big);
        }
    }
};

fn readExact(source: platform.AssetSource, handle: platform.AssetHandle, offset: u64, output: []u8) !void {
    var done: usize = 0;
    while (done != output.len) {
        const n = try source.readAt(handle, offset + done, output[done..]);
        if (n == 0) return error.TruncatedSequence;
        done += n;
    }
}

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn expand(value: u8) u8 {
    return (value << 2) | (value >> 4);
}

const Reader = struct {
    data: []const u8,
    cursor: usize = 0,
    fn take(self: *Reader, length: usize) ![]const u8 {
        if (length > self.data.len - self.cursor) return error.TruncatedSequenceTile;
        const result = self.data[self.cursor..][0..length];
        self.cursor += length;
        return result;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
};

pub fn decodeTiles(data: []const u8, pixels: []u8) !void {
    if (pixels.len != width * height or data.len < 128) return error.InvalidSequenceFrame;
    var input: Reader = .{ .data = data, .cursor = 128 };
    for (0..512) |tile| {
        const action = (data[tile / 4] >> @as(u3, @intCast((tile % 4) * 2))) & 3;
        const x = tile % 32 * 8;
        const y = tile / 32 * 8;
        switch (action) {
            0 => {},
            1 => {
                const format = try input.byte();
                var block: [64]u8 = undefined;
                if (format & 128 != 0) {
                    const mode = format & 3;
                    if (mode == 0 or mode == 3) continue;
                    try unpackRuns(&input, &block);
                    for (0..8) |row| for (0..8) |column| {
                        pixels[(y + row) * width + x + column] = block[if (mode == 1) row * 8 + column else column * 8 + row];
                    };
                } else {
                    if (format == 0 or format > 16) return error.InvalidTilePalette;
                    const colors = try input.take(format);
                    const bits: u4 = if (format <= 2) 1 else @intCast(std.math.log2_int(u8, format - 1) + 1);
                    const indices = try input.take(@as(usize, bits) * 8);
                    for (0..64) |i| {
                        const bit = i * bits;
                        var value: u16 = indices[bit / 8];
                        if (bit % 8 + bits > 8) value |= @as(u16, indices[bit / 8 + 1]) << 8;
                        const color = (value >> @as(u4, @intCast(bit % 8))) & ((@as(u16, 1) << bits) - 1);
                        if (color >= colors.len) return error.InvalidTileColor;
                        pixels[(y + i / 8) * width + x + i % 8] = colors[color];
                    }
                }
            },
            2 => {
                const block = try input.take(64);
                for (0..8) |row| @memcpy(pixels[(y + row) * width + x ..][0..8], block[row * 8 ..][0..8]);
            },
            3 => while (true) {
                const position = try input.byte();
                pixels[(y + ((position >> 3) & 7)) * width + x + (position & 7)] = try input.byte();
                if (position & 128 != 0) break;
            },
            else => unreachable,
        }
    }
}

fn unpackRuns(input: *Reader, output: *[64]u8) !void {
    var runs: [64]i8 = undefined;
    var count: usize = 0;
    var length: usize = 0;
    var pair: u8 = 0;
    while (length < output.len and count < runs.len) : (count += 1) {
        if (count % 2 == 0) pair = try input.byte();
        const nibble: u4 = @truncate(if (count % 2 == 0) pair else pair >> 4);
        runs[count] = @as(i4, @bitCast(nibble));
        length += @abs(runs[count]);
    }
    if (length < output.len) return error.ShortSequenceRun;
    var written: usize = 0;
    for (runs[0..count]) |run| {
        const amount: usize = @abs(run);
        const used = @min(amount, output.len - written);
        if (run < 0) @memset(output[written..][0..used], try input.byte()) else @memcpy(output[written..][0..used], (try input.take(amount))[0..used]);
        written += used;
    }
}

test "tile updates preserve previous pixels and support literals, local palettes and sparse patches" {
    var pixels: [width * height]u8 = @splat(9);
    var data: [128 + 64 + 11 + 4]u8 = @splat(0);
    data[0] = 2 | (1 << 2) | (3 << 4);
    @memset(data[128..192], 4);
    data[192..203].* = .{ 2, 6, 7, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa };
    data[203..207].* = .{ 0, 12, 0xbf, 13 };
    try decodeTiles(&data, &pixels);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 4, 4, 4, 4, 4, 4, 6, 7, 6, 7, 6, 7, 6, 7, 12 }, pixels[0..17]);
    try std.testing.expectEqual(@as(u8, 13), pixels[7 * width + 23]);
    try std.testing.expectEqual(@as(u8, 9), pixels[24]);
    try std.testing.expectError(error.TruncatedSequenceTile, decodeTiles(data[0..206], &pixels));
}

test "run-coded tiles expand either row or column order" {
    var pixels: [width * height]u8 = @splat(0);
    var data: [141]u8 = @splat(0);
    data[0] = 1;
    data[128..].* = .{ 0x82, 0x88, 0x88, 0x88, 0x88, 1, 2, 3, 4, 5, 6, 7, 8 };
    try decodeTiles(&data, &pixels);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, pixels[0..8]);
    try std.testing.expectEqualSlices(u8, pixels[0..8], pixels[7 * width ..][0..8]);
}
