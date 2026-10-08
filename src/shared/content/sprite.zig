//! Original sprite records become owned row-major frames with a drawing origin. Compression,
//! column ordering and legacy offset tables are confined to this importer.
const std = @import("std");
const bitmap = @import("bitmap.zig");

pub const Frame = struct {
    image: bitmap.IndexedImage,
    origin_x: i16,
    origin_y: i16,
    color_bits: enum { local4, full8 } = .local4,

    pub fn deinit(self: *Frame) void {
        self.image.deinit();
        self.* = undefined;
    }
};

/// The offset index is a compatibility identifier. Scene and animation definitions keep
/// references to decoded frames, rather than looking up DOS records while drawing.
pub fn fromArchive(
    allocator: std.mem.Allocator,
    sprites: []const u8,
    offsets: []const u8,
    index: u16,
) !Frame {
    if (sprites.len < 12 or
        !std.mem.eql(u8, sprites[0..3], "SPP")) return error.InvalidSpriteArchive;
    if (offsets.len < 2 or
        (offsets.len - 2) % 6 != 0 or
        (offsets.len - 2) / 6 > 4096) return error.InvalidSpriteDirectory;
    if (std.mem.readInt(
        u16,
        offsets[offsets.len - 2 ..][0..2],
        .little,
    ) != 0xffff) return error.InvalidSpriteDirectory;
    var found: ?u32 = null;
    var cursor: usize = 0;
    while (cursor + 2 < offsets.len) : (cursor += 6) {
        const id = std.mem.readInt(u16, offsets[cursor..][0..2], .little);
        if (id == 0xffff) return error.InvalidSpriteDirectory;
        if (id == index) {
            if (found != null) return error.DuplicateSprite;
            found = std.mem.readInt(u32, offsets[cursor + 2 ..][0..4], .little);
        }
    }
    const offset = found orelse return error.MissingSprite;
    // An explicitly null entry clears the actor image (for example during transport).
    // An identifier absent from this library still falls through to another library.
    if (offset == 0xffffffff) {
        const pixels = try allocator.alloc(u8, 1);
        pixels[0] = 0;
        return .{
            .image = .{ .allocator = allocator, .width = 1, .height = 1, .pixels = pixels },
            .origin_x = 0,
            .origin_y = 0,
        };
    }
    const body = sprites[12..];
    if (offset >= body.len) return error.InvalidSpriteOffset;
    return decode(allocator, body[offset..]);
}

/// Interface icons use an offset directory and 16x16 packed four-bit pixels, without runs.
pub fn fromIcons(allocator: std.mem.Allocator, file: []const u8, index: u16) !Frame {
    if (file.len < 2) return error.InvalidIconDirectory;
    const directory_length = std.mem.readInt(u16, file[0..2], .little);
    if (directory_length < 2 or
        directory_length % 2 != 0 or
        directory_length > file.len) return error.InvalidIconDirectory;
    if (index >= directory_length / 2) return error.MissingIcon;
    const offset: usize = std.mem.readInt(u16, file[@as(usize, index) * 2 ..][0..2], .little);
    if (offset < directory_length or
        offset > file.len or
        file.len - offset < 130) return error.TruncatedIcon;
    const pixels = try allocator.alloc(u8, 256);
    for (file[offset + 2 ..][0..128], 0..) |byte, i| {
        pixels[i * 2] = byte >> 4;
        pixels[i * 2 + 1] = byte & 15;
    }
    return .{
        .image = .{ .allocator = allocator, .width = 16, .height = 16, .pixels = pixels },
        .origin_x = 0,
        .origin_y = 0,
    };
}

pub fn decode(allocator: std.mem.Allocator, record: []const u8) !Frame {
    if (record.len < 4) return error.TruncatedSprite;
    const columns_first = record[2] & 0x40 != 0;
    const raw = record[2] & 0x80 != 0;
    // The direct-draw path clears only the column-layout bit. Its high selector bit
    // remains in the dimension, and the pixels begin immediately after the header.
    const major = record[2] & @as(u8, if (raw) 0xbf else 0x3f);
    const minor = record[3];
    if (major == 0 or minor == 0) return error.InvalidSpriteDimensions;
    const width: u16 = if (columns_first) minor else major;
    const height: u16 = if (columns_first) major else minor;
    const area = @as(usize, width) * height;
    const pixels = try allocator.alloc(u8, area);
    errdefer allocator.free(pixels);
    if (raw) {
        if (area > record.len - 4) return error.TruncatedSprite;
        @memcpy(pixels, record[4..][0..area]);
    } else {
        if (record.len < 6) return error.TruncatedSprite;
        const length = std.mem.readInt(u16, record[4..6], .big);
        if (length > record.len - 6) return error.TruncatedSprite;
        try decodePixels(allocator, record[6..][0..length], pixels);
    }
    if (columns_first) {
        const row_major = try allocator.alloc(u8, area);
        defer allocator.free(row_major);
        for (0..height) |y| {
            for (0..width) |x| row_major[y * width + x] = pixels[x * height + y];
        }
        @memcpy(pixels, row_major);
    }
    return .{
        .image = .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels },
        .origin_x = @as(i8, @bitCast(record[0])),
        .origin_y = @as(i8, @bitCast(record[1])),
        .color_bits = if (raw) .full8 else .local4,
    };
}

const Tokens = struct {
    values: []const u8,
    position: usize = 0,

    fn remaining(self: Tokens) usize {
        return self.values.len - self.position;
    }

    fn next(self: *Tokens) !u8 {
        if (self.remaining() == 0) return error.TruncatedSpriteRun;
        const value = self.values[self.position];
        self.position += 1;
        return value;
    }
};

fn decodePixels(allocator: std.mem.Allocator, encoded: []const u8, pixels: []u8) !void {
    // The original expands nibbles 1024 bytes above its output. A sufficiently long run
    // can overwrite a token before it is read. This affects a supplied GLUE frame, so a
    // separate immutable token stream would change visible pixels. Keep the overlap here,
    // at import, without exposing scratch layout to animation or drawing.
    const token_base = 1024;
    const workspace = try allocator.alloc(u8, @max(pixels.len + 1, token_base + encoded.len * 2));
    defer allocator.free(workspace);
    for (encoded, 0..) |byte, i| {
        workspace[token_base + i * 2] = byte >> 4;
        workspace[token_base + i * 2 + 1] = byte & 15;
    }
    var input: Tokens = .{ .values = workspace[token_base..][0 .. encoded.len * 2] };
    var written: usize = 0;
    while (input.remaining() != 0) {
        var color = try input.next();
        var count: usize = 1;
        if (color == 15) {
            color = try input.next();
            count = try input.next();
            if (color == 15) {
                count = count * 16 + try input.next();
                color = try input.next();
            }
            count += 4;
        }
        if (count > pixels.len + 1 - written) return error.SpriteRunOverflow;
        @memset(workspace[written..][0..count], color);
        written += count;
    }
    // An odd nibble count is padded with one zero nibble. The DOS scratch decoder writes
    // that extra pixel, but the renderer never reads it. Do not expose padding as artwork.
    if (written < pixels.len) return error.ShortSprite;
    if (written == pixels.len + 1 and workspace[pixels.len] != 0) return error.TrailingSpriteData;
    @memcpy(pixels, workspace[0..pixels.len]);
}

test "sprite origins and column storage become ordinary image coordinates" {
    var frame = try decode(std.testing.allocator, &.{ 255, 2, 0x42, 3, 0, 3, 0x12, 0x34, 0x56 });
    defer frame.deinit();
    try std.testing.expectEqual(@as(i16, -1), frame.origin_x);
    try std.testing.expectEqual(@as(u16, 3), frame.image.width);
    try std.testing.expectEqual(@as(u16, 2), frame.image.height);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 5, 2, 4, 6 }, frame.image.pixels);
}

test "short and long nibble runs, padding and truncation" {
    const allocator = std.testing.allocator;
    var pixels: [264]u8 = undefined;
    // f,2,1 => five 2s; f,f,f,f,3 => 259 3s.
    try decodePixels(allocator, &.{ 0xf2, 0x1f, 0xff, 0xf3 }, &pixels);
    for (pixels[0..5]) |color| try std.testing.expectEqual(@as(u8, 2), color);
    for (pixels[5..]) |color| try std.testing.expectEqual(@as(u8, 3), color);
    try decodePixels(allocator, &.{0x10}, pixels[0..1]);
    try std.testing.expectError(
        error.TruncatedSpriteRun,
        decodePixels(allocator, &.{0xf2}, pixels[0..5]),
    );
    try std.testing.expectError(
        error.SpriteRunOverflow,
        decodePixels(allocator, &.{ 0xf2, 0x10 }, pixels[0..4]),
    );
    try std.testing.expectError(
        error.SpriteRunOverflow,
        decodePixels(allocator, &.{ 0x12, 0x00 }, pixels[0..2]),
    );
    try std.testing.expectError(
        error.TrailingSpriteData,
        decodePixels(allocator, &.{0x12}, pixels[0..1]),
    );
}

test "long output can replace a later token before it is decoded" {
    var pixels: [1049]u8 = undefined;
    // Four 259-zero runs, twelve zeros, then a literal 3. The twelve-zero run covers
    // the last token in the shared workspace; the original therefore outputs zero.
    try decodePixels(
        std.testing.allocator,
        &.{ 0xff, 0xff, 0x0f, 0xff, 0xf0, 0xff, 0xff, 0x0f, 0xff, 0xf0, 0xf0, 0x83 },
        &pixels,
    );
    for (pixels) |color| try std.testing.expectEqual(@as(u8, 0), color);
}

test "truncated records and absent archive entries are checked" {
    const archive = [_]u8{ 'S', 'P', 'P', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0x30 };
    const offsets = [_]u8{ 7, 0, 0, 0, 0, 0, 255, 255 };
    var selected = try fromArchive(std.testing.allocator, &archive, &offsets, 7);
    defer selected.deinit();
    try std.testing.expectEqual(@as(u8, 3), selected.image.pixels[0]);
    try std.testing.expectError(
        error.MissingSprite,
        fromArchive(std.testing.allocator, &archive, &offsets, 8),
    );
    try std.testing.expectError(
        error.InvalidSpriteDirectory,
        fromArchive(std.testing.allocator, &archive, offsets[0..7], 7),
    );
    try std.testing.expectError(
        error.TruncatedSprite,
        decode(std.testing.allocator, &.{ 0, 0, 2, 2, 0, 9 }),
    );
    // Direct-draw records keep the selector bit in the dimension: 129 pixels are required.
    try std.testing.expectError(
        error.TruncatedSprite,
        decode(std.testing.allocator, &.{ 0, 0, 0x81, 1, 16 }),
    );
    var direct: [4 + 129]u8 = @splat(16);
    direct[0..4].* = .{ 0, 0, 0x81, 1 };
    var frame = try decode(std.testing.allocator, &direct);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u16, 129), frame.image.width);
    try std.testing.expectEqual(.full8, frame.color_bits);
    try std.testing.expectEqual(@as(u8, 16), frame.image.pixels[128]);
}

test "icon offsets and nibble order are bounded independently of sprite archives" {
    var file: [132]u8 = @splat(0);
    file[0] = 2;
    file[4] = 0x1f;
    var icon = try fromIcons(std.testing.allocator, &file, 0);
    defer icon.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 15, 0, 0 }, icon.image.pixels[0..4]);
    try std.testing.expectError(error.MissingIcon, fromIcons(std.testing.allocator, &file, 1));
    try std.testing.expectError(
        error.TruncatedIcon,
        fromIcons(std.testing.allocator, file[0..131], 0),
    );
}

test "explicit null artwork becomes transparent while an absent identifier stays missing" {
    const archive = [_]u8{ 'S', 'P', 'P', 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const offsets = [_]u8{ 7, 0, 255, 255, 255, 255, 255, 255 };
    var frame = try fromArchive(std.testing.allocator, &archive, &offsets, 7);
    defer frame.deinit();
    try std.testing.expectEqualSlices(u8, &.{0}, frame.image.pixels);
    try std.testing.expectError(
        error.MissingSprite,
        fromArchive(std.testing.allocator, &archive, &offsets, 8),
    );
}
