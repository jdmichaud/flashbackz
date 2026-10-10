//! The inventory's tiled source panel is assembled once into an ordinary image. Layout
//! and navigation consume named artwork, without source icon indices or executable offsets.
const std = @import("std");
const sprite = @import("sprite.zig");
const font_mod = @import("font.zig");

pub const Assets = struct {
    background: sprite.Frame,
    marker: sprite.Frame,
    previous_page: sprite.Frame,
    next_page: sprite.Frame,
    font: font_mod.Font,
    level_label: []u8,

    pub fn deinit(self: *Assets) void {
        self.font.allocator.free(self.level_label);
        self.font.deinit();
        self.background.deinit();
        self.marker.deinit();
        self.previous_page.deinit();
        self.next_page.deinit();
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    icons: []const u8,
    font_bytes: []const u8,
    label: []const u8,
) !Assets {
    const pixels = try allocator.alloc(u8, 144 * 80);
    errdefer allocator.free(pixels);
    for (0..45) |index| {
        var tile = try sprite.fromIcons(allocator, icons, @intCast(31 + index));
        defer tile.deinit();
        const x = index % 9 * 16;
        const y = index / 9 * 16;
        for (0..16) |row| @memcpy(
            pixels[(y + row) * 144 + x ..][0..16],
            tile.image.pixels[row * 16 ..][0..16],
        );
    }
    var marker = try sprite.fromIcons(allocator, icons, 76);
    errdefer marker.deinit();
    var previous = try sprite.fromIcons(allocator, icons, 77);
    errdefer previous.deinit();
    var next = try sprite.fromIcons(allocator, icons, 78);
    errdefer next.deinit();
    var font = try font_mod.decode(allocator, font_bytes);
    errdefer font.deinit();
    return .{
        .background = .{
            .image = .{ .allocator = allocator, .width = 144, .height = 80, .pixels = pixels },
            .origin_x = 0,
            .origin_y = 0,
        },
        .marker = marker,
        .previous_page = previous,
        .next_page = next,
        .font = font,
        .level_label = try allocator.dupe(u8, label),
    };
}
