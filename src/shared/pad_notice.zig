//! The message that a gamepad came or went, as sorz shows it: "GAMEPAD 2 CONNECTED" or "GAMEPAD 2
//! DISCONNECTED" in the game font, centred on a black strip near the bottom of the picture, over
//! every screen and film. It shows for 3 seconds and fades out over the last one. The game does
//! not stop under it.
//!
//! The message belongs to this machine, not to the game: it is drawn over the presented RGBA
//! picture only. The indexed page, and the hashes that the agent prints from it, never hold it.
const std = @import("std");
const font_mod = @import("content/font.zig");

/// How long the message shows, and the fade out of its last part.
pub const shown_ns: u64 = 3 * std.time.ns_per_s;
pub const fade_ns: u64 = std.time.ns_per_s;

/// The text's row of 8 pixels, the fourth from the bottom, as sorz puts it.
const row_from_bottom = 4;

const black: [3]u8 = .{ 0, 0, 0 };
const white: [3]u8 = .{ 255, 255, 255 };

pub const PadNotice = struct {
    /// The pad's number: its place among the connected pads, from 1.
    number: u8,
    connected: bool,
    /// When it first showed: null until it is drawn.
    since_ns: ?u64 = null,

    pub fn text(self: PadNotice, buffer: *[24]u8) []const u8 {
        const what = if (self.connected) "CONNECTED" else "DISCONNECTED";
        return std.fmt.bufPrint(buffer, "GAMEPAD {d} {s}", .{ self.number, what }) catch
            unreachable;
    }

    /// Draws the message over `frame`, an RGBA picture of `width` × `height`, as it shows at
    /// `now_ns`. Returns false when its time is over and it drew nothing: the caller drops it.
    pub fn draw(
        self: *PadNotice,
        frame: []u8,
        width: usize,
        height: usize,
        font: *const font_mod.Font,
        now_ns: u64,
    ) bool {
        const since = self.since_ns orelse now_ns;
        self.since_ns = since;
        const age = now_ns -| since;
        if (age >= shown_ns) return false;
        const left = shown_ns - age;
        const light: u32 = if (left < fade_ns) @intCast(left * 255 / fade_ns) else 255;

        var buffer: [24]u8 = undefined;
        const line = self.text(&buffer);
        // The strip is one cell wider than the text on each side.
        const cells = line.len + 2;
        const left_x = (width / font_mod.glyph_width - cells) / 2 * font_mod.glyph_width;
        const top = height - row_from_bottom * font_mod.glyph_height;
        for (0..font_mod.glyph_height) |row| {
            for (0..cells * font_mod.glyph_width) |x| {
                const color = colorAt(line, font, x, row);
                const at = ((top + row) * width + left_x + x) * 4;
                for (frame[at..][0..3], color) |*under, over| {
                    under.* = @intCast((@as(u32, under.*) * (255 - light) + over * light) / 255);
                }
            }
        }
        return true;
    }
};

/// The color of the strip at (`x`, `row`): the text's glyph pixel there, else black. The glyphs'
/// shadow ink is black too, as the strip under it.
fn colorAt(line: []const u8, font: *const font_mod.Font, x: usize, row: usize) [3]u8 {
    const cell = x / font_mod.glyph_width;
    if (cell == 0 or cell > line.len) return black;
    const glyph = font.glyph(line[cell - 1]) orelse return black;
    return switch (glyph[row * font_mod.glyph_width + x % font_mod.glyph_width]) {
        0, 2 => black,
        else => white,
    };
}

test "the message names the pad and what it did" {
    var buffer: [24]u8 = undefined;
    const came: PadNotice = .{ .number = 1, .connected = true };
    try std.testing.expectEqualStrings("GAMEPAD 1 CONNECTED", came.text(&buffer));
    const went: PadNotice = .{ .number = 8, .connected = false };
    try std.testing.expectEqualStrings("GAMEPAD 8 DISCONNECTED", went.text(&buffer));
}

test "the message shows for 3 seconds on its strip, and fades over the last one" {
    const allocator = std.testing.allocator;
    // A synthetic font: every glyph is the foreground ink.
    const bytes: [96 * font_mod.glyph_bytes]u8 = @splat(0xff);
    var font = try font_mod.decode(allocator, &bytes);
    defer font.deinit();
    const width = 256;
    const height = 224;
    var frame: [width * height * 4]u8 = @splat(100);
    var notice: PadNotice = .{ .number = 1, .connected = true };
    const start = 5 * std.time.ns_per_s;

    // "GAMEPAD 1 CONNECTED": 19 characters, on a strip of 21 cells from cell 5, row 24.
    const top = height - 4 * 8;
    const pixel = struct {
        fn at(f: []const u8, x: usize, y: usize) u8 {
            return f[(y * width + x) * 4];
        }
    }.at;
    try std.testing.expect(notice.draw(&frame, width, height, &font, start));
    try std.testing.expectEqual(@as(u8, 0), pixel(&frame, 5 * 8, top));
    try std.testing.expectEqual(@as(u8, 255), pixel(&frame, 6 * 8, top));
    try std.testing.expectEqual(@as(u8, 0), pixel(&frame, 25 * 8 + 7, top + 7));
    try std.testing.expectEqual(@as(u8, 100), pixel(&frame, 5 * 8 - 1, top));
    try std.testing.expectEqual(@as(u8, 100), pixel(&frame, 6 * 8, top - 1));
    try std.testing.expectEqual(@as(u8, 100), frame[(top * width + 6 * 8) * 4 + 3]);

    // Half way through the fade, the strip is half over the picture.
    frame = @splat(100);
    try std.testing.expect(notice.draw(&frame, width, height, &font, start + 2_500_000_000));
    try std.testing.expectEqual(@as(u8, 50), pixel(&frame, 5 * 8, top));
    try std.testing.expectEqual(@as(u8, 177), pixel(&frame, 6 * 8, top));

    // After 3 seconds, it is over and draws nothing.
    frame = @splat(100);
    try std.testing.expect(!notice.draw(&frame, width, height, &font, start + shown_ns));
    try std.testing.expectEqual(@as(u8, 100), pixel(&frame, 6 * 8, top));
}
