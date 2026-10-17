//! Indexed text rendering. Glyph styling is explicit: transparent, foreground and shadow
//! inks are content policy, and coordinates are clipped to the destination rather than hardware.
const std = @import("std");
const font_mod = @import("../content/font.zig");

pub const Style = struct {
    foreground: u8,
    shadow: u8,
    advance: u8 = 8,
    /// Some fonts use additional indexed inks beyond foreground and shadow.
    palette_bank: ?u4 = null,
};

pub fn draw(
    pixels: []u8,
    width: u16,
    height: u16,
    font: *const font_mod.Font,
    text: []const u8,
    x: i32,
    y: i32,
    style: Style,
) !void {
    if (pixels.len != @as(usize, width) * height) return error.InvalidFrameLength;
    var cursor_x = x;
    for (text) |character| {
        const glyph = font.glyph(character) orelse return error.MissingGlyph;
        for (0..font_mod.glyph_height) |row| {
            const dy = y + @as(i32, @intCast(row));
            if (dy < 0 or dy >= height) continue;
            for (0..font_mod.glyph_width) |column| {
                const dx = cursor_x + @as(i32, @intCast(column));
                if (dx < 0 or dx >= width) continue;
                const ink = glyph[row * font_mod.glyph_width + column];
                const color = switch (ink) {
                    0 => continue,
                    15 => style.foreground,
                    2 => style.shadow,
                    else => if (style.palette_bank) |bank|
                        (@as(u8, bank) << 4) | ink
                    else
                        return error.UnknownGlyphInk,
                };
                pixels[@as(usize, @intCast(dy)) * width + @as(usize, @intCast(dx))] = color;
            }
        }
        cursor_x += style.advance;
    }
}

test "text inks and negative coordinates preserve surrounding pixels" {
    var raw: [32]u8 = @splat(0);
    raw[0] = 0xf2;
    raw[4] = 0x0f;
    var font = try font_mod.decode(std.testing.allocator, &raw);
    defer font.deinit();
    var page: [4]u8 = @splat(7);
    try draw(&page, 2, 2, &font, " ", -1, 0, .{ .foreground = 3, .shadow = 1 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 7, 3, 7 }, &page);
    try std.testing.expectError(
        error.MissingGlyph,
        draw(&page, 2, 2, &font, "A", 0, 0, .{ .foreground = 3, .shadow = 1 }),
    );
    font.pixels[0] = 8;
    try std.testing.expectError(
        error.UnknownGlyphInk,
        draw(&page, 2, 2, &font, " ", 0, 0, .{ .foreground = 3, .shadow = 1 }),
    );
    try draw(
        &page,
        2,
        2,
        &font,
        " ",
        0,
        0,
        .{ .foreground = 0xed, .shadow = 0xe2, .palette_bank = 14 },
    );
    try std.testing.expectEqual(@as(u8, 0xe8), page[0]);
}
