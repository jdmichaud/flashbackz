//! Eight-by-eight glyphs, two four-bit palette indices per byte. The file has no header:
//! characters begin at ASCII space. The importer expands pixels without imposing text styling.
//! Research: bitmap-port-map 3. Glyph colors/advance remain the renderer's content policy.
const std = @import("std");

pub const first_character: u8 = 32;
pub const glyph_width = 8;
pub const glyph_height = 8;
pub const glyph_pixels = glyph_width * glyph_height;
pub const glyph_bytes = glyph_pixels / 2;

pub const Font = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,

    pub fn glyph(self: *const Font, character: u8) ?[]const u8 {
        if (character < first_character) return null;
        const offset = @as(usize, character - first_character) * glyph_pixels;
        if (offset >= self.pixels.len) return null;
        return self.pixels[offset..][0..glyph_pixels];
    }

    pub fn deinit(self: *Font) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Font {
    if (bytes.len == 0 or bytes.len % glyph_bytes != 0 or bytes.len / glyph_bytes > 256 - @as(usize, first_character))
        return error.InvalidFontLength;
    const pixels = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |value, i| {
        pixels[i * 2] = value >> 4;
        pixels[i * 2 + 1] = value & 15;
    }
    return .{ .allocator = allocator, .pixels = pixels };
}

test "glyph lookup maps characters and expands high nibble first" {
    var encoded: [64]u8 = @splat(0);
    encoded[32] = 0xf2;
    encoded[63] = 0x71;
    var font = try decode(std.testing.allocator, &encoded);
    defer font.deinit();
    const mark = font.glyph('!').?;
    try std.testing.expectEqualSlices(u8, &.{ 15, 2 }, mark[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 7, 1 }, mark[62..64]);
    try std.testing.expect(font.glyph(31) == null);
    try std.testing.expect(font.glyph('"') == null);
}

test "font length must describe whole addressable glyphs" {
    try std.testing.expectError(error.InvalidFontLength, decode(std.testing.allocator, &.{}));
    try std.testing.expectError(error.InvalidFontLength, decode(std.testing.allocator, &.{1}));
    const too_many: [225 * 32]u8 = @splat(0);
    try std.testing.expectError(error.InvalidFontLength, decode(std.testing.allocator, &too_many));
}
