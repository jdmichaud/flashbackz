//! Clipped indexed sprite composition with an explicit origin, facing and layer policy.
const std = @import("std");
const sprites = @import("../content/sprite.zig");

pub const Facing = enum { original, mirrored };
pub const Style = struct {
    palette_bank: u4,
    facing: Facing = .original,
    foreground: enum { respect, overwrite } = .respect,
};

/// Position is the frame's drawing origin in the destination image. Widen coordinates
/// before clipping so off-screen positions cannot overflow into visible pixels.
pub fn draw(pixels: []u8, width: u16, height: u16, frame: *const sprites.Frame, x: i32, y: i32, style: Style) !void {
    if (pixels.len != @as(usize, width) * height) return error.InvalidFrameLength;
    const image = &frame.image;
    if (image.pixels.len != @as(usize, image.width) * image.height) return error.InvalidSpriteLength;
    const left: i64 = switch (style.facing) {
        .original => @as(i64, x) - frame.origin_x,
        .mirrored => @as(i64, x) + frame.origin_x - image.width,
    };
    const top = @as(i64, y) - frame.origin_y;
    const x_start = @max(0, left);
    const y_start = @max(0, top);
    const x_end = @min(width, left + image.width);
    const y_end = @min(height, top + image.height);
    if (x_end <= x_start or y_end <= y_start) return;
    for (@intCast(y_start)..@intCast(y_end)) |dy| {
        const sy: usize = @intCast(@as(i64, @intCast(dy)) - top);
        for (@intCast(x_start)..@intCast(x_end)) |dx| {
            const column: usize = @intCast(@as(i64, @intCast(dx)) - left);
            const sx = if (style.facing == .mirrored) image.width - 1 - column else column;
            const color = image.pixels[sy * image.width + sx];
            if (color == 0) continue;
            if (color > 15) return error.InvalidSpriteColor;
            const target = &pixels[dy * width + dx];
            if (style.foreground == .respect and target.* & 0x80 != 0) continue;
            target.* = (@as(u8, style.palette_bank) << 4) | color;
        }
    }
}

test "clipping, mirroring, transparency and foreground all apply in image space" {
    var frame = try sprites.decode(std.testing.allocator, &.{ 1, 0, 3, 2, 0, 3, 0x12, 0x30, 0x45 });
    defer frame.deinit();
    var page = [_]u8{ 7, 0x88, 7, 7, 7, 7 };
    try draw(&page, 3, 2, &frame, 0, 0, .{ .palette_bank = 4 });
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x88, 7, 0x44, 0x45, 7 }, &page);
    @memset(&page, 7);
    try draw(&page, 3, 2, &frame, 2, 0, .{ .palette_bank = 5, .facing = .mirrored });
    try std.testing.expectEqualSlices(u8, &.{ 0x53, 0x52, 0x51, 0x55, 0x54, 7 }, &page);
    const previous = page;
    try draw(&page, 3, 2, &frame, std.math.minInt(i32), std.math.maxInt(i32), .{ .palette_bank = 4 });
    try std.testing.expectEqualSlices(u8, &previous, &page);
}
