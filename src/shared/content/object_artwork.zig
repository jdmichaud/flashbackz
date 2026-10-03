//! Composed DOS object art becomes an ordinary owned frame at import. Tile addresses,
//! palette-independent nibbles and per-part reflection never enter the renderer.
const std = @import("std");
const sprite = @import("sprite.zig");
const art_bank = @import("art_bank.zig");

pub fn recordAt(archive: []const u8, index: u16) ![]const u8 {
    if (archive.len < 2) return error.InvalidObjectArtDirectory;
    const directory_end = std.mem.readInt(u16, archive[0..2], .big);
    if (directory_end < 2 or directory_end % 2 != 0 or directory_end > archive.len)
        return error.InvalidObjectArtDirectory;
    if (index >= directory_end / 2) return error.MissingObjectArt;
    const offset = std.mem.readInt(u16, archive[@as(usize, index) * 2 ..][0..2], .big);
    if (offset < directory_end or offset > archive.len or archive.len - offset < 6)
        return error.InvalidObjectArtOffset;
    const length = 6 + @as(usize, archive[offset + 5]) * 4;
    if (length > archive.len - offset) return error.TruncatedObjectArt;
    return archive[offset..][0..length];
}

pub fn fromArchive(allocator: std.mem.Allocator, archive: []const u8, bindings: []const u8, banks: art_bank.Archive, index: u16) !sprite.Frame {
    const record = try recordAt(archive, index);
    if (record[0] >= bindings.len) return error.MissingObjectArtBankBinding;
    const bank = try banks.decode(allocator, bindings[record[0]]);
    defer allocator.free(bank);
    return decode(allocator, record, bank);
}

pub fn decode(allocator: std.mem.Allocator, record: []const u8, bank: []const u8) !sprite.Frame {
    if (record.len < 6 or record.len != 6 + @as(usize, record[5]) * 4) return error.TruncatedObjectArt;
    if (record[5] == 0) return error.EmptyObjectArt;
    var width: u16 = 0;
    var height: u16 = 0;
    var parts = std.mem.window(u8, record[6..], 4, 4);
    while (parts.next()) |part| {
        const shape = dimensions(part[3]);
        const offset = @as(usize, part[0]) * 32;
        if (offset > bank.len or shape.width * shape.height / 2 > bank.len - offset)
            return error.TruncatedObjectArtTile;
        width = @max(width, @as(u16, part[1]) + shape.width);
        height = @max(height, @as(u16, part[2]) + shape.height);
    }
    // The header's width/height describe source bounds; parts determine actual pixels.
    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    @memset(pixels, 0);
    parts.reset();
    while (parts.next()) |part| {
        const shape = dimensions(part[3]);
        const encoded = bank[@as(usize, part[0]) * 32 ..][0 .. shape.width * shape.height / 2];
        for (0..shape.height) |y| {
            for (0..shape.width) |x| {
                const source_x = if (part[3] & 0x10 != 0) shape.width - 1 - x else x;
                const source = y * shape.width + source_x;
                const color = if (source % 2 == 0) encoded[source / 2] >> 4 else encoded[source / 2] & 15;
                // A transparent part leaves earlier parts visible. Higher part flags are
                // ignored by the original DOS compositor, including the observed bit 5.
                if (color != 0) pixels[(part[2] + y) * width + part[1] + x] = color;
            }
        }
    }
    return .{
        .image = .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels },
        .origin_x = @as(i8, @bitCast(record[1])),
        .origin_y = @as(i8, @bitCast(record[2])),
    };
}

fn dimensions(flags: u8) struct { width: u16, height: u16 } {
    return .{ .width = (@as(u16, (flags >> 2) & 3) + 1) * 8, .height = (@as(u16, flags & 3) + 1) * 8 };
}

test "parts compose in order with local reflection, transparency and signed origins" {
    var bank: [64]u8 = @splat(0x11);
    @memset(bank[32..], 0);
    bank[32] = 0x23;
    const record = [_]u8{ 0, 0xff, 2, 1, 1, 2, 0, 0, 0, 0, 1, 2, 1, 0x30 };
    var frame = try decode(std.testing.allocator, &record, &bank);
    defer frame.deinit();
    try std.testing.expectEqual(@as(i16, -1), frame.origin_x);
    try std.testing.expectEqual(@as(i16, 2), frame.origin_y);
    try std.testing.expectEqual(@as(u16, 10), frame.image.width);
    try std.testing.expectEqual(@as(u16, 9), frame.image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 3, 2 }, frame.image.pixels[10..20]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1, 1, 0, 0 }, frame.image.pixels[20..30]);
}

test "object art aliases and truncated directories, records and tiles" {
    const allocator = std.testing.allocator;
    const archive = [_]u8{ 0, 4, 0, 4, 0, 0, 0, 8, 8, 1, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, try recordAt(&archive, 0), try recordAt(&archive, 1));
    try std.testing.expectError(error.MissingObjectArt, recordAt(&archive, 2));
    try std.testing.expectError(error.TruncatedObjectArt, recordAt(archive[0..13], 0));
    try std.testing.expectError(error.InvalidObjectArtDirectory, recordAt(&.{ 0, 3, 0 }, 0));
    try std.testing.expectError(error.TruncatedObjectArtTile, decode(allocator, archive[4..], &.{}));
    try std.testing.expectError(error.EmptyObjectArt, decode(allocator, &.{ 0, 0, 0, 0, 0, 0 }, &.{}));
}
