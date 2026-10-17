//! Small indexed vector illustrations. Coverage uses quantized edge slopes and explicit
//! vertex coverage; indexed tinting is separate from geometry and clipping.
const std = @import("std");
pub const Point = struct {
    x: i16,
    y: i16,
};
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};
pub const Ink = union(enum) {
    color: u8,
    mask: u8,
};
pub const Canvas = struct {
    pixels: []u8,
    width: u16,
    height: u16,
    clip: Rect,

    fn plot(self: Canvas, x: i32, y: i32, ink: Ink) void {
        if (x < self.clip.x or
            y < self.clip.y or
            x >= @as(i32, self.clip.x) + self.clip.width or
            y >= @as(i32, self.clip.y) + self.clip.height or
            x < 0 or
            y < 0 or
            x >= self.width or
            y >= self.height) {
            return;
        }
        const pixel = &self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
        switch (ink) {
            .color => |color| pixel.* = color,
            .mask => |mask| pixel.* |= mask,
        }
    }

    fn line(self: Canvas, first: Point, second: Point, ink: Ink) void {
        const a = if (first.y <= second.y) first else second;
        const b = if (first.y <= second.y) second else first;
        var x: i32 = a.x;
        var y: i32 = a.y;
        const dx: i32 = @intCast(@abs(@as(i32, b.x) - x));
        const dy: i32 = @intCast(@abs(@as(i32, b.y) - y));
        const sx: i32 = if (x < b.x) 1 else -1;
        const sy: i32 = if (y < b.y) 1 else -1;
        const steep = dy > dx;
        const major = if (steep) dy else dx;
        const minor = if (steep) dx else dy;
        var balance = 2 * minor - major;
        self.plot(x, y, ink);
        var remaining = major;
        while (remaining > 0) : (remaining -= 1) {
            if (balance >= 0) {
                if (steep) {
                    x += sx;
                } else {
                    y += sy;
                }
                balance -= 2 * major;
            }
            if (steep) {
                y += sy;
            } else {
                x += sx;
            }
            balance += 2 * minor;
            self.plot(x, y, ink);
        }
    }

    fn ellipseSpan(self: Canvas, center: Point, row: i32, radius: i32, ink: Ink) void {
        const top = @max(@as(i32, self.clip.y), 0);
        const bottom = @min(@as(i32, self.clip.y) + self.clip.height, self.height);
        const lower = @as(i32, center.y) + row;
        const upper = @as(i32, center.y) - row;
        if ((lower < top or lower >= bottom) and (upper < top or upper >= bottom)) return;
        const left = @max(@as(i32, center.x) - radius, self.clip.x);
        const right = @min(
            @as(i32, center.x) + radius,
            @as(i32, self.clip.x) + self.clip.width - 1,
        );
        var x = left;
        while (x <= right) : (x += 1) {
            self.plot(x, @as(i32, center.y) + row, ink);
            if (row != 0) {
                self.plot(x, @as(i32, center.y) - row, ink);
            }
        }
    }

    /// Integer boundary traversal with explicit tie rules. Scanline spans are emitted once,
    /// then clipped by the canvas, so indexed tinting cannot accumulate through overdraw.
    pub fn ellipse(self: Canvas, center: Point, radius_x: u16, radius_y: u16, ink: Ink) !void {
        if (self.pixels.len != @as(usize, self.width) * self.height) {
            return error.InvalidVectorShape;
        }
        if (radius_x > std.math.maxInt(i16) or
            radius_y > std.math.maxInt(i16)) {
            return error.UnsupportedVectorExtent;
        }
        const xx: i32 = @as(i32, radius_x) * radius_x;
        const yy: i32 = @as(i32, radius_y) * radius_y;
        var x: i32 = radius_x;
        var y: i32 = 0;
        // Preserve the original cross-word multiply: only the high word of its
        // upper partial product contributes. Error accumulators then wrap at 32 bits.
        const initial = @as(i32, radius_x) * (2 * yy & 65535) +
            ((@as(i32, radius_x) * (2 * yy >> 16)) >> 16);
        var horizontal_slope = 2 *% initial;
        var vertical_slope: i32 = 0;
        var horizontal_error = 2 * xx -% initial +% yy;
        var vertical_error = 2 * yy -% horizontal_slope +% xx;
        while (vertical_error < 0) {
            if (x != 0) {
                self.ellipseSpan(center, y, x, ink);
            }
            y += 1;
            vertical_slope +%= 4 *% xx;
            if (horizontal_error < 0) {
                horizontal_error +%= vertical_slope +% 2 * xx;
                vertical_error +%= vertical_slope;
            } else {
                x -= 1;
                horizontal_slope -%= 4 *% yy;
                horizontal_error +%= vertical_slope +% 2 * xx -% horizontal_slope;
                vertical_error +%= vertical_slope +% 2 * yy -% horizontal_slope;
            }
        }
        var row_written = false;
        while (x >= 0) : (x -= 1) {
            if (!row_written and x != 0) {
                self.ellipseSpan(center, y, x, ink);
                row_written = true;
            }
            horizontal_slope -%= 4 *% yy;
            if (vertical_error < 0) {
                y += 1;
                row_written = false;
                vertical_slope +%= 4 *% xx;
                vertical_error +%= vertical_slope -% horizontal_slope +% 2 * yy;
            } else {
                vertical_error +%= 2 * yy -% horizontal_slope;
            }
        }
        if (row_written) {
            y += 1;
        }
        while (y <= radius_y) : (y += 1) {
            self.ellipseSpan(center, y, 0, ink);
        }
    }

    /// Clockwise illustrations with one filled span per row. The picture importer rejects unsupported
    /// curves and unsupported extents instead of substituting a different rasterization.
    pub fn draw(self: Canvas, points: []const Point, ink: Ink) !void {
        if (self.pixels.len != @as(usize, self.width) * self.height or
            points.len == 0 or
            points.len > 64) {
            return error.InvalidVectorShape;
        }
        if (points.len == 1) {
            self.plot(points[0].x, points[0].y, ink);
            return;
        }
        if (points.len == 2) {
            self.line(points[0], points[1], ink);
            return;
        }
        var top: i32 = points[0].y;
        var top_index: usize = 0;
        var bottom = top;
        var min_x: i32 = points[0].x;
        var max_x = min_x;
        for (points, 0..) |point, i| {
            if (point.x < -4096 or
                point.x > 4096 or
                point.y < -4096 or
                point.y > 4096) {
                return error.UnsupportedVectorExtent;
            }
            if (point.y < top) {
                top = point.y;
                top_index = i;
            }
            bottom = @max(bottom, point.y);
            min_x = @min(min_x, point.x);
            max_x = @max(max_x, point.x);
        }
        if (top == bottom) {
            var x = @max(min_x, self.clip.x);
            while (x <= @min(max_x, @as(i32, self.clip.x) + self.clip.width - 1)) : (x += 1) {
                self.plot(x, top, ink);
            }
            return;
        }
        var left_storage: [64]Edge = undefined;
        var right_storage: [64]Edge = undefined;
        // Above the viewport each side starts from its last vertex there, walking from the top
        // vertex, so a notch that the clip row cuts off is skipped.
        const clipped = top < self.clip.y;
        const left_start = if (clipped)
            lastAbove(points, top_index, self.clip.y, true)
        else
            top_index;
        const right_start = if (clipped)
            lastAbove(points, top_index, self.clip.y, false)
        else
            top_index;
        const left_edges = try edges(points, left_start, bottom, true, &left_storage);
        const right_edges = try edges(points, right_start, bottom, false, &right_storage);
        var left_index: usize = 0;
        var right_index: usize = 0;
        var y = @max(top, self.clip.y);
        while (y <= @min(bottom, @as(i32, self.clip.y) + self.clip.height - 1)) : (y += 1) {
            while (left_index + 1 < left_edges.len and
                y >= left_edges[left_index].end.y) {
                left_index += 1;
            }
            while (right_index + 1 < right_edges.len and
                y >= right_edges[right_index].end.y) {
                right_index += 1;
            }
            const left = left_edges[left_index];
            const right = right_edges[right_index];
            var first = left.at(y, self.clip.y, true);
            var last = right.at(y, self.clip.y, false);
            if (y == bottom) {
                // The closing row uses endpoint caps, not another interpolated edge step.
                first = @as(i32, left.end.x) * 65536;
                if (left.step >= 65536) {
                    first -= @divTrunc(left.step, 2);
                }
                var closing_x = right.end.x;
                if (right.end_index != left.end_index) {
                    var closing = (right.end_index + 1) % points.len;
                    while (closing != left.end_index) : (closing = (closing + 1) % points.len) {
                        closing_x = points[closing].x;
                    }
                }
                last = @as(i32, closing_x) * 65536;
                if (right.step < 0) {
                    last -= @divTrunc(right.step, 2);
                }
            }
            var x = @max(first >> 16, self.clip.x);
            const end = @min(last >> 16, @as(i32, self.clip.x) + self.clip.width - 1);
            while (x <= end) : (x += 1) {
                self.plot(x, y, ink);
            }
        }
    }
};

/// A contour is converted to two downward edge chains. A short upward notch advances its
/// horizontal origin without rewinding the scanline. This preserves the source's one-span
/// coverage for its slightly concave illustrations, while keeping edge traversal explicit.
const Edge = struct {
    start: Point,
    end: Point,
    step: i32,
    end_index: usize,
    fn outwardHalf(step: i32) i32 {
        // This boundary compares the integer part of a positive slope with one. Thus
        // slopes in [1,2) retain a half-pixel bias instead of a half-slope bias.
        return if (step < 131072) 32768 else @divTrunc(step, 2);
    }
    fn at(self: Edge, y: i32, clip_top: i32, left: bool) i32 {
        const step = self.step;
        const elapsed = y - self.start.y;
        var x = @as(i32, self.start.x) * 65536;
        const half = if (step >= -65536 and step < 0) @as(i32, 32768) else @divTrunc(step, 2);
        if (self.start.y < clip_top) {
            x = (@as(i32, self.start.x) -
                @divTrunc(
                    (@as(i32, self.start.y) - clip_top) * (@as(i32, self.end.x) - self.start.x),
                    @as(i32, self.end.y) - self.start.y,
                )) * 65536;
            const magnitude: i32 = @intCast(@abs(step));
            x += if (left)
                -@divTrunc(if (magnitude < 65536) @as(i32, -65536) else magnitude, 2)
            else
                @divTrunc(@max(magnitude, 65536), 2);
            return x + step * (y - clip_top);
        }
        if (left) {
            if (step < 0) {
                x += half + step * elapsed;
            } else if (elapsed > 0) {
                x += outwardHalf(step) + step * (elapsed - 1);
            }
        } else {
            if (step >= 0) {
                x += outwardHalf(step) + step * elapsed;
            } else if (elapsed > 0) {
                x += half + step * (elapsed - 1);
            }
        }
        return x;
    }
};

/// The last vertex above `clip_top` on the walk from `first`, before one at or below it.
fn lastAbove(points: []const Point, first: usize, clip_top: i32, reverse: bool) usize {
    var index = first;
    for (0..points.len) |_| {
        const next = if (reverse)
            (index + points.len - 1) % points.len
        else
            (index + 1) % points.len;
        if (points[next].y >= clip_top) return index;
        index = next;
    }
    return first;
}

fn edges(
    points: []const Point,
    first: usize,
    bottom: i32,
    reverse: bool,
    buffer: []Edge,
) ![]const Edge {
    var index = first;
    var used: usize = 0;
    var traversed: usize = 0;
    while (points[index].y < bottom) {
        var start = points[index];
        while (true) {
            index = if (reverse)
                (index + points.len - 1) % points.len
            else
                (index + 1) % points.len;
            traversed += 1;
            if (traversed > points.len or used == buffer.len) return error.InvalidVectorShape;
            const end = points[index];
            if (end.y > start.y) {
                const step = @divTrunc(
                    (@as(i32, end.x) - start.x) * 256,
                    @as(i32, end.y) - start.y,
                ) * 256;
                buffer[used] = .{ .start = start, .end = end, .step = step, .end_index = index };
                used += 1;
                break;
            }
            start.x = end.x;
        }
    }
    if (used == 0) return error.InvalidVectorShape;
    return buffer[0..used];
}

test "indexed shading preserves underlying inks and clips each edge" {
    var pixels: [16]u8 = @splat(2);
    const canvas: Canvas = .{
        .pixels = &pixels,
        .width = 4,
        .height = 4,
        .clip = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
    };
    try canvas.draw(
        &.{.{ .x = 0, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 3 }, .{ .x = 0, .y = 3 }},
        .{ .mask = 8 },
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 2, 2, 2, 2, 2, 10, 10, 2, 2, 10, 10, 2, 2, 2, 2, 2 },
        &pixels,
    );
}

test "closing edge caps retain the covered corner of a one-row sloped trapezoid" {
    var pixels: [30]u8 = @splat(0);
    const canvas: Canvas = .{
        .pixels = &pixels,
        .width = 10,
        .height = 3,
        .clip = .{ .x = 0, .y = 0, .width = 10, .height = 3 },
    };
    try canvas.draw(
        &.{.{ .x = 0, .y = 0 }, .{ .x = 8, .y = 0 }, .{ .x = 8, .y = 1 }, .{ .x = 1, .y = 1 }},
        .{ .color = 3 },
    );
    for (0..2) |y| {
        for (pixels[y * 10..][0..9]) |pixel| {
            try std.testing.expectEqual(@as(u8, 3), pixel);
        }
        try std.testing.expectEqual(@as(u8, 0), pixels[y * 10 + 9]);
    }
    for (pixels[20..]) |pixel| {
        try std.testing.expectEqual(@as(u8, 0), pixel);
    }
}

test "ellipse clipping and indexed tint preserve the surrounding page" {
    var pixels: [81]u8 = @splat(2);
    const canvas: Canvas = .{
        .pixels = &pixels,
        .width = 9,
        .height = 9,
        .clip = .{ .x = 2, .y = 2, .width = 5, .height = 5 },
    };
    try canvas.ellipse(.{ .x = 4, .y = 4 }, 2, 2, .{ .mask = 8 });
    try std.testing.expectEqual(@as(u8, 10), pixels[4 * 9 + 4]);
    try std.testing.expectEqual(@as(u8, 2), pixels[0]);
    try std.testing.expectEqual(@as(u8, 2), pixels[2 * 9 + 2]);
    for (0..9) |y| {
        for (0..9) |x| {
            if (x < 2 or y < 2 or x > 6 or y > 6) {
                try std.testing.expectEqual(@as(u8, 2), pixels[y * 9 + x]);
            }
        }
    }
}

test "large ellipse radii retain bounded canvas writes" {
    var pixels: [81]u8 = @splat(2);
    const canvas: Canvas = .{
        .pixels = &pixels,
        .width = 9,
        .height = 9,
        .clip = .{ .x = 2, .y = 2, .width = 5, .height = 5 },
    };
    for ([_]u16{ 196, 264, 1109, 1315 }) |radius| {
        @memset(&pixels, 2);
        try canvas.ellipse(.{ .x = 4, .y = 4 }, radius, radius, .{ .color = 7 });
        try std.testing.expectEqual(@as(u8, 7), pixels[4 * 9 + 4]);
        for (0..9) |y| {
            for (0..9) |x| {
                if (x < 2 or x >= 7 or y < 2 or y >= 7) {
                    try std.testing.expectEqual(@as(u8, 2), pixels[y * 9 + x]);
                }
            }
        }
    }
}
