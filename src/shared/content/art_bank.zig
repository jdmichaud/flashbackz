//! DOS MBK archive import. Packed banks end at their directory offset; raw banks begin
//! there. Callers receive owned bytes and never depend on the original bank cache. A size's
//! high bit marks a raw bank and the low 15 bits count its 32-byte units, as the original's MBK
//! loader reads them (flashback-re docs/object-artwork-map.md); the room tiles' BNQ banks use a
//! signed size instead (`floppy_rooms.zig`).
const std = @import("std");
const backward = @import("backward_stream.zig");

pub const Archive = struct {
    bytes: []const u8,
    count: u8,

    pub fn init(bytes: []const u8) !Archive {
        if (bytes.len == 0 or bytes[0] == 0 or @as(usize, bytes[0]) * 6 > bytes.len) {
            return error.InvalidArtBankDirectory;
        }
        return .{ .bytes = bytes, .count = bytes[0] };
    }

    pub fn decode(self: Archive, allocator: std.mem.Allocator, index: u8) ![]u8 {
        if (index >= self.count) return error.MissingArtBank;
        const entry = self.bytes[@as(usize, index) * 6..][0..6];
        // An entry is a big-endian u32 offset and a big-endian u16 size. DOS reads only the low
        // 16 bits of each offset, so bytes 0-1 of every entry are not used. Byte 0 of entry 0
        // holds the bank count.
        const offset: usize = std.mem.readInt(u16, entry[2..4], .big);
        const units = std.mem.readInt(u16, entry[4..6], .big);
        const size = @as(usize, units & 0x7fff) * 32;
        if (size == 0) return error.MissingArtBank;
        // A part reads at most 8,672 bytes of its bank: an offset of up to 255 units of 32
        // bytes, then at most 16 units. The limit, 16,384 bytes, is higher than that.
        if (size > 16384) return error.ArtBankTooLarge;
        const start = @as(usize, self.count) * 6;
        if (offset < start or offset > self.bytes.len) return error.InvalidArtBankOffset;
        if (units & 0x8000 != 0) {
            if (size > self.bytes.len - offset) return error.TruncatedArtBank;
            return allocator.dupe(u8, self.bytes[offset..][0..size]);
        }
        // Earlier packets can come before this packet. The backward codec reads only the words
        // of this bank, and their checksum does not include that prefix.
        const decoded = try backward.decode(allocator, self.bytes[start..offset], size);
        errdefer allocator.free(decoded);
        if (decoded.len != size) return error.ArtBankSizeMismatch;
        return decoded;
    }
};

test "raw banks use low offset bits and return independently owned storage" {
    var bytes: [44]u8 = @splat(0);
    bytes[0..12].* = .{ 2, 0, 0, 12, 0x80, 1, 0, 0, 0, 0, 0, 0 };
    bytes[12] = 0x7a;
    const archive = try Archive.init(&bytes);
    const bank = try archive.decode(std.testing.allocator, 0);
    defer std.testing.allocator.free(bank);
    bytes[12] = 0;
    try std.testing.expectEqual(@as(u8, 0x7a), bank[0]);
    try std.testing.expectEqual(@as(usize, 32), bank.len);
    try std.testing.expectError(error.MissingArtBank, archive.decode(std.testing.allocator, 1));
    try std.testing.expectError(error.MissingArtBank, archive.decode(std.testing.allocator, 2));
    try std.testing.expectError(
        error.TruncatedArtBank,
        (try Archive.init(bytes[0..43])).decode(std.testing.allocator, 0),
    );
}

test "bank directory, packet boundaries and declared output size are checked" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidArtBankDirectory, Archive.init(&.{}));
    try std.testing.expectError(
        error.InvalidArtBankDirectory,
        Archive.init(&.{ 2, 0, 0, 0, 0, 0 }),
    );
    var bytes = [_]u8{ 1, 0, 0, 18, 0, 1, 3, 0, 0x30, 0x40, 3, 0, 0x30, 0x40, 0, 0, 0, 4 };
    const archive = try Archive.init(&bytes);
    try std.testing.expectError(error.ArtBankSizeMismatch, archive.decode(allocator, 0));
    bytes[3] = 19;
    try std.testing.expectError(error.InvalidArtBankOffset, archive.decode(allocator, 0));
    bytes[3] = 5;
    try std.testing.expectError(error.InvalidArtBankOffset, archive.decode(allocator, 0));
    bytes[3] = 17;
    try std.testing.expectError(error.InvalidBitstreamLength, archive.decode(allocator, 0));
}

test "packed banks end at their offset and may follow an unrelated packet" {
    // One synthetic literal command produces the bytes 0..31. Four leading bytes are
    // deliberately outside the packet checksum; a forward-offset decoder cannot read it.
    const bytes = [_]u8{
        1,    0,    0,    54,   0,    1,    0xde, 0xad, 0xbe, 0xef,
        0x00, 0x80, 0x40, 0xc0, 0x20, 0xa0, 0x60, 0xe0, 0x10, 0x90,
        0x50, 0xd0, 0x30, 0xb0, 0x70, 0xf0, 0x08, 0x88, 0x48, 0xc8,
        0x28, 0xa8, 0x68, 0xe8, 0x18, 0x98, 0x58, 0xd8, 0x38, 0xb8,
        0x78, 0xf8, 0,    0,    0x0f, 0x47, 0,    0,    0x0f, 0x47,
        0,    0,    0,    32,
    };
    const archive = try Archive.init(&bytes);
    const decoded = try archive.decode(std.testing.allocator, 0);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 32), decoded.len);
    for (decoded, 0..) |value, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), value);
    }
}
