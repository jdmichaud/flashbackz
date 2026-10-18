//! Text over the presented RGBA picture, for this machine's own messages (the pads' messages, the
//! information overlay): the game font's letters in white and their shadow in black. The rest of
//! each glyph is transparent. The game's screens draw their own text in their indexed pages
//! (`text.zig`).
const std = @import("std");
const font_mod = @import("../content/font.zig");

const black: [3]u8 = .{ 0, 0, 0 };
const white: [3]u8 = .{ 255, 255, 255 };

/// Draws `line` with its top left corner at (`x`, `y`) over `frame`, an RGBA picture of `width` ×
/// `height`, mixed with the picture at `light` 255ths. A character without a glyph, and the
/// pixels outside the picture, draw nothing.
pub fn draw(
    frame: []u8,
    width: usize,
    height: usize,
    font: *const font_mod.Font,
    line: []const u8,
    x: usize,
    y: usize,
    light: u8,
) void {
    for (line, 0..) |character, index| {
        const glyph = font.glyph(character) orelse continue;
        const left = x + index * font_mod.glyph_width;
        for (0..font_mod.glyph_height) |row| {
            if (y + row >= height) break;
            for (0..font_mod.glyph_width) |column| {
                if (left + column >= width) break;
                const color = switch (glyph[row * font_mod.glyph_width + column]) {
                    0 => continue,
                    2 => black,
                    else => white,
                };
                const at = ((y + row) * width + left + column) * 4;
                for (frame[at..][0..3], color) |*under, over| {
                    const mixed = @as(u32, under.*) * (255 - light) + @as(u32, over) * light;
                    under.* = @intCast(mixed / 255);
                }
            }
        }
    }
}

/// A synthetic font for tests: every glyph is the foreground ink, but the space, which is
/// transparent, and `_`, which is all shadow.
pub fn testFont(allocator: std.mem.Allocator) !font_mod.Font {
    var bytes: [96 * font_mod.glyph_bytes]u8 = @splat(0xff);
    @memset(bytes[0..font_mod.glyph_bytes], 0);
    const shadow = @as(usize, '_' - font_mod.first_character) * font_mod.glyph_bytes;
    @memset(bytes[shadow..][0..font_mod.glyph_bytes], 0x22);
    return font_mod.decode(allocator, &bytes);
}

test "letters are white, shadows black, the rest and the outside untouched" {
    var font = try testFont(std.testing.allocator);
    defer font.deinit();
    const width = 32;
    const height = 16;
    var frame: [width * height * 4]u8 = @splat(100);
    draw(&frame, width, height, &font, "A _B", 4, 10, 255);
    const at = struct {
        fn red(f: []const u8, x: usize, y: usize) u8 {
            return f[(y * width + x) * 4];
        }
    }.red;
    try std.testing.expectEqual(@as(u8, 255), at(&frame, 4, 10));
    try std.testing.expectEqual(@as(u8, 100), at(&frame, 12, 10));
    try std.testing.expectEqual(@as(u8, 0), at(&frame, 20, 15));
    // "B" is cut by the right edge, and the rows below the picture are not drawn.
    try std.testing.expectEqual(@as(u8, 255), at(&frame, 31, 15));
    try std.testing.expectEqual(@as(u8, 100), at(&frame, 3, 10));
    try std.testing.expectEqual(@as(u8, 100), at(&frame, 4, 9));
    try std.testing.expectEqual(@as(u8, 100), frame[(10 * width + 4) * 4 + 3]);
}

test "a faded letter is mixed with the picture" {
    var font = try testFont(std.testing.allocator);
    defer font.deinit();
    var frame: [8 * 8 * 4]u8 = @splat(100);
    draw(&frame, 8, 8, &font, "A", 0, 0, 127);
    try std.testing.expectEqual(@as(u8, 177), frame[0]);
}
