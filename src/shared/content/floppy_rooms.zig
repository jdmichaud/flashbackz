//! Installation-time LEV/BNQ/SGD artwork, decoded directly into owned room pixels.
//! Recovered from INSTALL.EXE; no installer execution or intermediate files are required.
const std = @import("std");
const backward = @import("backward_stream.zig");
const artwork = @import("room_artwork.zig");

fn slice(bytes: []const u8, start: usize, count: usize) ![]const u8 {
    if (start > bytes.len or count > bytes.len - start) return error.TruncatedRoomContent;
    return bytes[start..][0..count];
}
fn big16(bytes: []const u8, at: usize) !u16 {
    return std.mem.readInt(u16, (try slice(bytes, at, 2))[0..2], .big);
}
fn big32(bytes: []const u8, at: usize) !u32 {
    return std.mem.readInt(u32, (try slice(bytes, at, 4))[0..4], .big);
}

pub const Archive = struct {
    rooms: []const u8,
    banks: []const u8,
    background: []const u8 = &.{},
    tile_bias: u16 = 0,

    pub fn decode(
        self: Archive,
        allocator: std.mem.Allocator,
        colors: []const u8,
        room: u8,
    ) !artwork.Artwork {
        if (room >= 64 or self.rooms.len < 256) return error.InvalidRoomDirectory;
        const end = try big32(self.rooms, @as(usize, room) * 4);
        const previous = if (room == 0) 256 else try big32(self.rooms, @as(usize, room - 1) * 4);
        if (end < previous or previous < 256) return error.InvalidRoomRange;
        if (end == previous) return error.AbsentRoom;
        const description = try backward.decode(
            allocator,
            try slice(self.rooms, 256, end - 256),
            16384,
        );
        defer allocator.free(description);
        _ = try slice(description, 0, 16);
        var selectors: [4]u8 = undefined;
        for (&selectors, 0..) |*value, i| {
            const bank = try big16(description, 2 + i * 2);
            if (bank > 255) return error.InvalidPaletteBank;
            value.* = @intCast(bank);
        }
        const tiles = try self.loadTiles(allocator, description);
        defer allocator.free(tiles);
        const pixels = try allocator.alloc(u8, 256 * 224);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        const background_start = try big16(description, 10);
        if (description[1] == 0) {
            try drawTiles(
                pixels,
                try slice(description, background_start, 1792),
                tiles,
                self.tile_bias,
            );
        } else {
            try self.drawBackground(allocator, pixels, description, background_start);
        }
        try drawTiles(
            pixels,
            try slice(description, try big16(description, 12), 1792),
            tiles,
            self.tile_bias,
        );
        return artwork.fromPixels(allocator, pixels, colors, selectors);
    }

    fn loadTiles(self: Archive, allocator: std.mem.Allocator, description: []const u8) ![]u8 {
        if (self.banks.len < 6 or self.banks[0] == 0) return error.InvalidArtBankDirectory;
        const directory = @as(usize, self.banks[0]) * 6;
        _ = try slice(self.banks, 0, directory);
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.appendNTimes(allocator, 0, 32); // Tile zero is transparent.
        var at: usize = try big16(description, 14);
        for (0..256) |_| {
            const selection = try big16(description, at);
            at += 2;
            const bank: usize = selection & 0x7fff;
            if (bank >= self.banks[0]) return error.InvalidArtBank;
            const offset = try big16(self.banks, bank * 6 + 2);
            // A negative size marks a raw bank, as the original's BNQ routine reads it
            // (flashback-re docs/floppy-gameplay-entry.md); MBK banks use a flag bit instead.
            const count: i16 = @bitCast(try big16(self.banks, bank * 6 + 4));
            const size = @as(usize, @abs(count)) * 32;
            if (count == 0 or size > 32768 or offset < directory) return error.InvalidArtBank;
            const bytes = if (count < 0) try allocator.dupe(u8, try slice(self.banks, offset, size)) else try backward.decode(
                allocator,
                try slice(self.banks, directory, offset - directory),
                size,
            );
            defer allocator.free(bytes);
            if (bytes.len != size) return error.ArtBankSizeMismatch;
            const selected = (try slice(description, at, 1))[0];
            at += 1;
            if (selected == 255) {
                try result.appendSlice(allocator, bytes);
            } else {
                const indices = try slice(description, at, @as(usize, selected) + 1);
                at += indices.len;
                for (indices) |index| try result.appendSlice(
                    allocator,
                    try slice(bytes, @as(usize, index) * 32, 32),
                );
            }
            if (result.items.len > 32768) return error.RoomTilesTooLarge;
            if (selection & 0x8000 != 0) return result.toOwnedSlice(allocator);
        }
        return error.UnterminatedRoomBanks;
    }

    fn drawBackground(
        self: Archive,
        allocator: std.mem.Allocator,
        pixels: []u8,
        description: []const u8,
        at: usize,
    ) !void {
        const count = try big16(description, at);
        const placements = try slice(description, at + 2, @as(usize, count) * 6);
        for (0..count) |i| {
            const placement = placements[i * 6 ..][0..6];
            const code = try big16(placement, 0);
            if (code == 0xffff) continue;
            const index = code & 0x7fff;
            if (self.background.len < 4 or
                index >= self.background[0]) return error.InvalidBackgroundIndex;
            var offset: i32 = @bitCast(try big32(self.background, @as(usize, index) * 4));
            if (index == 0) offset &= 0x00ffffff;
            const start: usize = @abs(offset);
            const size = try big16(self.background, start);
            const encoded = try slice(self.background, start + 2, size);
            const decoded = if (offset < 0) try allocator.dupe(u8, encoded) else try expandRuns(allocator, encoded);
            defer allocator.free(decoded);
            try drawBackgroundPiece(
                pixels,
                decoded,
                @as(i16, @bitCast(try big16(placement, 2))),
                @as(i16, @bitCast(try big16(placement, 4))),
            );
        }
    }
};

fn expandRuns(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var at: usize = 0;
    while (at < encoded.len) {
        const code = encoded[at];
        at += 1;
        const count: usize = if (code < 128) @as(usize, code) + 1 else 257 - @as(usize, code);
        if (count > 32768 - result.items.len) return error.BackgroundPieceTooLarge;
        if (code < 128) {
            try result.appendSlice(allocator, try slice(encoded, at, count));
            at += count;
        } else {
            const value = (try slice(encoded, at, 1))[0];
            at += 1;
            try result.appendNTimes(allocator, value, count);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn drawBackgroundPiece(pixels: []u8, bytes: []const u8, x: i32, y: i32) !void {
    _ = try slice(bytes, 0, 4);
    const width: usize = (@as(usize, bytes[0]) + 1) * 8;
    const height: usize = @as(usize, bytes[1]) + 1;
    const mask_size = try big16(bytes, 2);
    if (mask_size != width / 8 * height) return error.InvalidBackgroundMask;
    const mask = try slice(bytes, 4, mask_size);
    const colors = try slice(bytes, 4 + @as(usize, mask_size), width * height / 2);
    for (0..height) |row| {
        const dy = y + @as(i32, @intCast(row));
        if (dy < 0 or dy >= 224) continue;
        for (0..width) |column| {
            const dx = x + @as(i32, @intCast(column));
            if (dx < 0 or
                dx >= 256 or
                mask[row * (width / 8) + column / 8] & (@as(u8, 128) >> @as(u3, @intCast(column % 8))) == 0) continue;
            const value = colors[row * (width / 2) + column / 2];
            pixels[
                @as(usize, @intCast(dy)) * 256 + @as(usize, @intCast(dx))
            ] = if (column % 2 == 0) value >> 4 else value & 15;
        }
    }
}

fn drawTiles(pixels: []u8, cells: []const u8, tiles: []const u8, bias: u16) !void {
    for (0..896) |cell| {
        const flags = std.mem.readInt(u16, cells[cell * 2 ..][0..2], .little);
        const number = flags & 0x7ff;
        if (number == 0) continue;
        if (number < bias) return error.InvalidRoomTile;
        const tile = try slice(tiles, @as(usize, number - bias) * 32, 32);
        const bank: u8 = @intCast(((flags >> 9) & 0x30) | ((flags >> 8) & 0x80));
        const x = cell % 32 * 8;
        const y = cell / 32 * 8;
        for (0..8) |row| for (0..8) |column| {
            const sx = if (flags & 0x800 != 0) 7 - column else column;
            const sy = if (flags & 0x1000 != 0) 7 - row else row;
            const pair = tile[sy * 4 + sx / 2];
            const value = if (sx % 2 == 0) pair >> 4 else pair & 15;
            const index = (y + row) * 256 + x + column;
            if (value != 0) pixels[index] = value | bank | (pixels[index] & 0x80);
        };
    }
}

test "floppy background clipping preserves mask transparency" {
    var pixels: [256 * 224]u8 = @splat(9);
    try drawBackgroundPiece(&pixels, &.{ 0, 0, 0, 1, 0xc0, 0x12, 0, 0, 0 }, -1, 0);
    try std.testing.expectEqual(@as(u8, 2), pixels[0]);
    try std.testing.expectEqual(@as(u8, 9), pixels[1]);
    try std.testing.expectError(
        error.InvalidBackgroundMask,
        drawBackgroundPiece(&pixels, &.{ 1, 0, 0, 1 }, 0, 0),
    );
}

test "floppy tile flips retain foreground and reject missing art" {
    var pixels: [256 * 224]u8 = @splat(0x80);
    var cells: [1792]u8 = @splat(0);
    cells[0] = 1;
    cells[1] = 0x28;
    var tiles: [64]u8 = @splat(0);
    tiles[35] = 0x12;
    try drawTiles(&pixels, &cells, &tiles, 0);
    try std.testing.expectEqual(@as(u8, 0x92), pixels[0]);
    try std.testing.expectEqual(@as(u8, 0x91), pixels[1]);
    try std.testing.expectEqual(@as(u8, 0x80), pixels[2]);
    cells[0] = 2;
    try std.testing.expectError(error.TruncatedRoomContent, drawTiles(&pixels, &cells, &tiles, 0));
}
