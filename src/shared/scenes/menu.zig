//! Main-menu presentation and selection in game terms. Artwork and labels are supplied by
//! content; this scene neither opens legacy files nor interprets the original program.
const std = @import("std");
const bitmap = @import("../content/bitmap.zig");
const palette = @import("../content/palette.zig");
const font_mod = @import("../content/font.zig");
const text = @import("../render/text.zig");

/// The title's items; LOAD is ours (PLAN GS-5), the others the original's.
pub const Action = enum { start, load, skill, password, info, demo, quit };
pub const action_count = @typeInfo(Action).@"enum".field_names.len;

pub const Artwork = struct {
    background: *const bitmap.IndexedImage,
    colors: *const palette.Palette,
    font: *const font_mod.Font,
    labels: [action_count][]const u8,
};

pub const Layout = struct {
    left: i32 = 160,
    top: i32 = 112,
    row_height: u8 = 16,
    selected_color: u8 = 1,
    normal_color: u8 = 2,
    shadow_color: u8 = 0,
};

pub const Menu = struct {
    selected: Action = .start,

    pub fn selectedAction(self: Menu) Action {
        return self.selected;
    }

    pub fn draw(self: Menu, artwork: Artwork, layout: Layout, indices: []u8, rgba: []u8) !void {
        const background = artwork.background;
        if (indices.len != background.pixels.len) return error.InvalidFrameLength;
        @memcpy(indices, background.pixels);
        for (artwork.labels, 0..) |label, row| {
            try text.draw(indices, background.width, background.height, artwork.font, label, layout.left, layout.top + @as(i32, @intCast(row)) * layout.row_height, .{
                .foreground = if (row == @backingInt(self.selected)) layout.selected_color else layout.normal_color,
                .shadow = layout.shadow_color,
            });
        }
        try palette.writeRgba(indices, artwork.colors, rgba);
    }
};

test "menu composes supplied content and selected-item styling" {
    var raw_glyph: [32]u8 = @splat(0);
    raw_glyph[0] = 0xf0;
    var font = try font_mod.decode(std.testing.allocator, &raw_glyph);
    defer font.deinit();
    var image = try bitmap.decodePlanar(std.testing.allocator, &.{ 7, 7, 7, 7 }, 4, 1);
    defer image.deinit();
    var color_bytes: [768]u8 = @splat(0);
    color_bytes[3] = 255;
    const colors = try palette.decodeRgb8(&color_bytes);
    var indices: [4]u8 = undefined;
    var rgba: [16]u8 = undefined;
    const menu: Menu = .{};
    try menu.draw(
        .{ .background = &image, .colors = &colors, .font = &font, .labels = @splat(" ") },
        .{ .left = 0, .top = 0, .row_height = 8 },
        &indices,
        &rgba,
    );
    try std.testing.expectEqualSlices(u8, &.{ 1, 7, 7, 7 }, &indices);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, rgba[0..4]);
}
