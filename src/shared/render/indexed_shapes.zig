//! Small indexed vector illustrations. Coverage uses quantized edge slopes and explicit
//! vertex coverage; indexed tinting is separate from geometry and clipping.
const std = @import("std");
pub const Point = struct { x: i16, y: i16 };
pub const Rect = struct { x: i16, y: i16, width: u16, height: u16 };
pub const Ink = union(enum) { color: u8, mask: u8 };
pub const Canvas = struct {
    pixels: []u8,
    width: u16,
    height: u16,
    clip: Rect,

    fn plot(self: Canvas, x: i32, y: i32, ink: Ink) void {
        if (x < self.clip.x or y < self.clip.y or x >= @as(i32, self.clip.x) + self.clip.width or y >= @as(i32, self.clip.y) + self.clip.height or x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const pixel = &self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
        switch (ink) {
            .color => |color| pixel.* = color,
            .mask => |mask| pixel.* |= mask,
        }
    }

    fn line(self: Canvas, a: Point, b: Point, ink: Ink) void {
        var x: i32 = a.x;
        var y: i32 = a.y;
        const dx: i32 = @intCast(@abs(@as(i32, b.x) - x));
        const dy: i32 = -@as(i32, @intCast(@abs(@as(i32, b.y) - y)));
        const sx: i32 = if (x < b.x) 1 else -1;
        const sy: i32 = if (y < b.y) 1 else -1;
        var balance = dx + dy;
        while (true) {
            self.plot(x, y, ink);
            if (x == b.x and y == b.y) return;
            const twice = balance * 2;
            if (twice >= dy) {
                balance += dy;
                x += sx;
            }
            if (twice <= dx) {
                balance += dx;
                y += sy;
            }
        }
    }

    /// Clockwise illustrations with one filled span per row. The picture importer rejects unsupported
    /// curves and unsupported extents instead of substituting a different rasterization.
    pub fn draw(self: Canvas, points: []const Point, ink: Ink) !void {
        if (self.pixels.len != @as(usize, self.width) * self.height or points.len == 0 or points.len > 64) return error.InvalidVectorShape;
        if (points.len == 1) {
            self.plot(points[0].x, points[0].y, ink);
            return;
        }
        if (points.len == 2) {
            self.line(points[0], points[1], ink);
            return;
        }
        var top: i32 = points[0].y;
        var bottom = top;
        for (points) |point| {
            top = @min(top, point.y);
            bottom = @max(bottom, point.y);
        }
        for (points) |point| if (point.x < -4096 or point.x > 4096 or point.y < -4096 or point.y > 4096) return error.UnsupportedVectorExtent;
        var y = @max(top, self.clip.y);
        while (y <= @min(bottom, @as(i32, self.clip.y) + self.clip.height - 1)) : (y += 1) {
            var left: i32 = std.math.maxInt(i32);
            var right: i32 = std.math.minInt(i32);
            for (points, 0..) |a, index| {
                const b = points[(index + 1) % points.len];
                if (a.y == b.y) {
                    if (y == a.y) {
                        left = @min(left, @min(a.x, b.x));
                        right = @max(right, @max(a.x, b.x));
                    }
                    continue;
                }
                if (y < @min(a.y, b.y) or y >= @max(a.y, b.y)) continue;
                const is_left = b.y < a.y;
                const high = if (is_left) b else a;
                const low = if (is_left) a else b;
                const step = @divTrunc((@as(i32, low.x) - high.x) * 256, @as(i32, low.y) - high.y) * 256;
                const elapsed = y - high.y;
                var x = @as(i32, high.x) * 65536;
                const half = if (step >= -65536 and step < 0) @as(i32, 32768) else @divTrunc(step, 2);
                if (high.y < self.clip.y) {
                    x = (@as(i32, high.x) - @divTrunc((@as(i32, high.y) - self.clip.y) * (@as(i32, low.x) - high.x), @as(i32, low.y) - high.y)) * 65536;
                    const magnitude: i32 = @intCast(@abs(step));
                    x += if (is_left) -@divTrunc(if (magnitude < 65536) @as(i32, -65536) else magnitude, 2) else @divTrunc(@max(magnitude, 65536), 2);
                    x += step * (y - self.clip.y);
                } else if (is_left) {
                    if (step < 0) x += half + step * elapsed else if (elapsed > 0) x += @divTrunc(@max(step, 65536), 2) + step * (elapsed - 1);
                } else {
                    if (step >= 0) x += @divTrunc(@max(step, 65536), 2) + step * elapsed else if (elapsed > 0) x += half + step * (elapsed - 1);
                }
                x >>= 16;
                left = @min(left, x);
                right = @max(right, x);
            }
            var x = @max(left, self.clip.x);
            const end = @min(right, @as(i32, self.clip.x) + self.clip.width - 1);
            while (x <= end) : (x += 1) self.plot(x, y, ink);
        }
    }
};

test "indexed shading preserves underlying inks and clips each edge" {
    var pixels: [16]u8 = @splat(2);
    const canvas: Canvas = .{ .pixels = &pixels, .width = 4, .height = 4, .clip = .{ .x = 1, .y = 1, .width = 2, .height = 2 } };
    try canvas.draw(&.{ .{ .x = 0, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 3 }, .{ .x = 0, .y = 3 } }, .{ .mask = 8 });
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 2, 10, 10, 2, 2, 10, 10, 2, 2, 2, 2, 2 }, &pixels);
}
