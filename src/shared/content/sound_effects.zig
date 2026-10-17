//! GLOBAL.FIB import into immutable signed PCM. The directory and delta coding stay here;
//! the mixer consumes ordinary samples addressed by opaque sound IDs.
const std = @import("std");
pub const Sample = struct {
    pcm: []i8,
};
pub const Bank = struct {
    allocator: std.mem.Allocator,
    samples: []Sample,
    pub fn deinit(self: *Bank) void {
        for (self.samples) |sample| {
            self.allocator.free(sample.pcm);
        }
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};
const deltas = [_]i8{ -34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21 };
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Bank {
    if (bytes.len < 2) return error.InvalidSoundArchive;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    const directory_end = 2 + @as(usize, count) * 6;
    if (count == 0 or count > 256 or directory_end > bytes.len) return error.InvalidSoundArchive;
    const samples = try allocator.alloc(Sample, count);
    var loaded: usize = 0;
    errdefer {
        for (samples[0..loaded]) |sample| {
            allocator.free(sample.pcm);
        }
        allocator.free(samples);
    }
    var total: usize = 0;
    for (samples, 0..) |*sample, index| {
        const record = bytes[2 + index * 6..][0..6];
        const offset = std.mem.readInt(u32, record[0..4], .little);
        const length = std.mem.readInt(u16, record[4..6], .little);
        if (length != 0 and
            (offset < directory_end or
                offset > bytes.len or
                length > bytes.len - offset)) {
            return error.InvalidSoundExtent;
        }
        total += @as(usize, length) * 2;
        if (total > 4 * 1024 * 1024) return error.SoundArchiveTooLarge;
        sample.pcm = try allocator.alloc(i8, @as(usize, length) * 2);
        loaded += 1;
        if (length == 0) continue;
        const source = bytes[offset..][0..length];
        var amplitude: i8 = @bitCast(source[0]);
        sample.pcm[0] = amplitude;
        sample.pcm[1] = amplitude;
        for (source[1..], 1..) |pair, i| {
            amplitude +%= deltas[pair >> 4];
            sample.pcm[i * 2] = amplitude;
            amplitude +%= deltas[pair & 15];
            sample.pcm[i * 2 + 1] = amplitude;
        }
    }
    return .{ .allocator = allocator, .samples = samples };
}

test "sound delta decoding duplicates the first amplitude and wraps signed additions" {
    const bytes = [_]u8{ 1, 0, 8, 0, 0, 0, 3, 0, 127, 0xff, 0x08 };
    var bank = try decode(std.testing.allocator, &bytes);
    defer bank.deinit();
    try std.testing.expectEqualSlices(
        i8,
        &.{ 127, 127, -108, -87, -121, -121 },
        bank.samples[0].pcm,
    );
    try std.testing.expectError(
        error.InvalidSoundExtent,
        decode(std.testing.allocator, bytes[0..10]),
    );
    try std.testing.expectError(
        error.InvalidSoundArchive,
        decode(std.testing.allocator, &.{ 255, 255 }),
    );
}
