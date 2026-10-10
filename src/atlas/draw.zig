//! Drawing on an RGB canvas: images with their coverage, the game font scaled up, the soft
//! light a map casts on the black around it, and the tags that mark a join.
const std = @import("std");
const flashbackz = @import("flashbackz");
const Font = flashbackz.content.font.Font;
const glyph_size = flashbackz.content.font.glyph_width;

pub const Rgb = [3]u8;
pub const black: Rgb = .{ 0, 0, 0 };

/// An image with the pixels it covers; the rest is see-through.
pub const Image = struct {
    width: u32,
    height: u32,
    rgb: []u8,
    covered: []bool,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const rgb = try allocator.alloc(u8, @as(usize, width) * height * 3);
        errdefer allocator.free(rgb);
        const covered = try allocator.alloc(bool, @as(usize, width) * height);
        @memset(rgb, 0);
        @memset(covered, false);
        return .{ .width = width, .height = height, .rgb = rgb, .covered = covered };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgb);
        allocator.free(self.covered);
        self.* = undefined;
    }

    /// Copies an opaque `width` by `height` RGB image with its top-left at x, y.
    pub fn paste(self: *Image, rgb: []const u8, width: u32, height: u32, x: i32, y: i32) void {
        for (0..height) |row| {
            const ty = y + @as(i32, @intCast(row));
            if (ty < 0 or ty >= self.height) continue;
            for (0..width) |column| {
                const tx = x + @as(i32, @intCast(column));
                if (tx < 0 or tx >= self.width) continue;
                const to = @as(usize, @intCast(ty)) * self.width + @as(usize, @intCast(tx));
                const from = row * width + column;
                self.rgb[to * 3 ..][0..3].* = rgb[from * 3 ..][0..3].*;
                self.covered[to] = true;
            }
        }
    }
};

pub const Canvas = struct {
    width: u32,
    height: u32,
    rgb: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const rgb = try allocator.alloc(u8, @as(usize, width) * height * 3);
        @memset(rgb, 0);
        return .{ .width = width, .height = height, .rgb = rgb };
    }

    pub fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        allocator.free(self.rgb);
        self.* = undefined;
    }

    fn put(self: *Canvas, x: i32, y: i32, color: Rgb) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const at = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 3;
        self.rgb[at..][0..3].* = color;
    }

    pub fn fill(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Rgb) void {
        var row = y;
        while (row < y + h) : (row += 1) {
            var column = x;
            while (column < x + w) : (column += 1) self.put(column, row, color);
        }
    }

    /// Draws the covered pixels of `image` with its top-left at x, y.
    pub fn draw(self: *Canvas, image: *const Image, x: i32, y: i32) void {
        for (0..image.height) |row| for (0..image.width) |column| {
            const from = row * image.width + column;
            if (!image.covered[from]) continue;
            self.put(x + @as(i32, @intCast(column)), y + @as(i32, @intCast(row)), image.rgb[from * 3 ..][0..3].*);
        };
    }

    /// Adds the light `image` (at x, y) casts around it: its colors averaged over 16-pixel
    /// blocks, blurred (a Gaussian of 160 pixels' deviation), scaled by `strength` and
    /// stretched back, out to 512 pixels beyond its edges.
    pub fn glow(
        self: *Canvas,
        allocator: std.mem.Allocator,
        image: *const Image,
        x: i32,
        y: i32,
        strength: f32,
    ) !void {
        const block = 16;
        const pad = 512;
        const sigma = 160.0 / @as(f32, block);
        const full_w = image.width + 2 * pad;
        const full_h = image.height + 2 * pad;
        const small_w = full_w / block;
        const small_h = full_h / block;
        const small = try allocator.alloc(f32, small_w * small_h * 3);
        defer allocator.free(small);
        @memset(small, 0);
        for (0..image.height) |row| for (0..image.width) |column| {
            const from = row * image.width + column;
            if (!image.covered[from]) continue;
            const sx = (column + pad) / block;
            const sy = (row + pad) / block;
            if (sx >= small_w or sy >= small_h) continue;
            for (0..3) |c| small[(sy * small_w + sx) * 3 + c] += @floatFromInt(image.rgb[from * 3 + c]);
        };
        for (small) |*v| v.* /= block * block;
        try blur(allocator, small, small_w, small_h, sigma);
        for (small) |*v| v.* *= strength;

        // Bilinear, sample centers aligned, clamped at the edges.
        const scale_x = @as(f32, @floatFromInt(small_w)) / @as(f32, @floatFromInt(full_w));
        const scale_y = @as(f32, @floatFromInt(small_h)) / @as(f32, @floatFromInt(full_h));
        for (0..full_h) |row| {
            const ty = y - pad + @as(i32, @intCast(row));
            if (ty < 0 or ty >= self.height) continue;
            const fy = std.math.clamp((@as(f32, @floatFromInt(row)) + 0.5) * scale_y - 0.5, 0, @as(f32, @floatFromInt(small_h - 1)));
            const y0: usize = @intFromFloat(@floor(fy));
            const y1 = @min(y0 + 1, small_h - 1);
            const wy = fy - @floor(fy);
            for (0..full_w) |column| {
                const tx = x - pad + @as(i32, @intCast(column));
                if (tx < 0 or tx >= self.width) continue;
                const fx = std.math.clamp((@as(f32, @floatFromInt(column)) + 0.5) * scale_x - 0.5, 0, @as(f32, @floatFromInt(small_w - 1)));
                const x0: usize = @intFromFloat(@floor(fx));
                const x1 = @min(x0 + 1, small_w - 1);
                const wx = fx - @floor(fx);
                const at = (@as(usize, @intCast(ty)) * self.width + @as(usize, @intCast(tx))) * 3;
                for (0..3) |c| {
                    const top = small[(y0 * small_w + x0) * 3 + c] * (1 - wx) + small[(y0 * small_w + x1) * 3 + c] * wx;
                    const bottom = small[(y1 * small_w + x0) * 3 + c] * (1 - wx) + small[(y1 * small_w + x1) * 3 + c] * wx;
                    const light = top * (1 - wy) + bottom * wy;
                    const sum = @as(f32, @floatFromInt(self.rgb[at + c])) + @min(light, 255);
                    self.rgb[at + c] = @intFromFloat(@min(sum, 255));
                }
            }
        }
    }

    /// Writes `text` in the game font, each font pixel a `scale`-sized square: the letters in
    /// `color`, their built-in shadow in `shadow`.
    pub fn text(self: *Canvas, font: *const Font, string: []const u8, x: i32, y: i32, scale: i32, color: Rgb, shadow: Rgb) void {
        for (string, 0..) |character, i| {
            const glyph = font.glyph(character) orelse continue;
            for (glyph, 0..) |value, p| {
                if (value == 0) continue;
                const px = x + (@as(i32, @intCast(i)) * glyph_size + @as(i32, @intCast(p % glyph_size))) * scale;
                const py = y + @as(i32, @intCast(p / glyph_size)) * scale;
                self.fill(px, py, scale, scale, if (value == shadow_index) shadow else color);
            }
        }
    }

    /// A tag centered on cx, cy: a square in `color`, outlined in black, with `letter` on it.
    pub fn tag(self: *Canvas, font: *const Font, letter: u8, cx: i32, cy: i32, color: Rgb) void {
        const scale = 6;
        const half = tag_size / 2;
        self.fill(cx - half - 4, cy - half - 4, tag_size + 8, tag_size + 8, black);
        self.fill(cx - half, cy - half, tag_size, tag_size, color);
        const ink: Rgb = .{ 14, 14, 18 };
        self.text(font, &.{letter}, cx - 4 * scale, cy - 4 * scale, scale, ink, darker(color, 0.62));
    }
};

pub const tag_size = 64;

/// The font's shadow color index; its letters use the others.
const shadow_index = 2;

pub fn textWidth(string: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(string.len)) * glyph_size * scale;
}

pub fn darker(color: Rgb, factor: f32) Rgb {
    var result: Rgb = undefined;
    for (color, &result) |c, *r| r.* = @intFromFloat(@as(f32, @floatFromInt(c)) * factor);
    return result;
}

pub fn hue(degrees: f32, saturation: f32, value: f32) Rgb {
    const h = @mod(degrees, 360) / 60;
    const c = value * saturation;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const m = value - c;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(h))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    var result: Rgb = undefined;
    for (rgb, &result) |v, *r| r.* = @intFromFloat((v + m) * 255);
    return result;
}

/// A separable Gaussian blur of an RGB float image, black beyond its edges.
fn blur(allocator: std.mem.Allocator, pixels: []f32, width: usize, height: usize, sigma: f32) !void {
    const radius: usize = @intFromFloat(@ceil(sigma * 3));
    const kernel = try allocator.alloc(f32, 2 * radius + 1);
    defer allocator.free(kernel);
    var total: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
        k.* = @exp(-d * d / (2 * sigma * sigma));
        total += k.*;
    }
    for (kernel) |*k| k.* /= total;
    const scratch = try allocator.alloc(f32, pixels.len);
    defer allocator.free(scratch);
    for (0..2) |pass| {
        const source = if (pass == 0) pixels else scratch;
        const target = if (pass == 0) scratch else pixels;
        for (0..height) |row| for (0..width) |column| for (0..3) |c| {
            var sum: f32 = 0;
            for (kernel, 0..) |k, i| {
                const offset = @as(isize, @intCast(i)) - @as(isize, @intCast(radius));
                const sx = @as(isize, @intCast(column)) + if (pass == 0) offset else 0;
                const sy = @as(isize, @intCast(row)) + if (pass == 1) offset else 0;
                if (sx < 0 or sy < 0 or sx >= width or sy >= height) continue;
                sum += k * source[(@as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx))) * 3 + c];
            }
            target[(row * width + column) * 3 + c] = sum;
        };
    }
}

test "hues match their primaries and the font's shadow takes its own color" {
    try std.testing.expectEqual(Rgb{ 255, 0, 0 }, hue(0, 1, 1));
    try std.testing.expectEqual(Rgb{ 0, 255, 0 }, hue(120, 1, 1));
    try std.testing.expectEqual(Rgb{ 0, 0, 255 }, hue(240, 1, 1));

    const allocator = std.testing.allocator;
    var encoded: [96 * 32]u8 = @splat(0);
    // 'A' (the 34th glyph): a letter pixel, then a shadow pixel.
    encoded[33 * 32] = 0xf2;
    var font = try flashbackz.content.font.decode(allocator, &encoded);
    defer font.deinit();
    var canvas = try Canvas.init(allocator, 8, 4);
    defer canvas.deinit(allocator);
    canvas.text(&font, "A", 0, 0, 2, .{ 9, 9, 9 }, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(u8, 9), canvas.rgb[0]);
    try std.testing.expectEqual(@as(u8, 9), canvas.rgb[(1 * 8 + 1) * 3]);
    try std.testing.expectEqual(@as(u8, 1), canvas.rgb[2 * 3]);
    try std.testing.expectEqual(@as(u8, 0), canvas.rgb[4 * 3]);
}

test "a map's glow lights the black around it and leaves far pixels dark" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 32, 32);
    defer image.deinit(allocator);
    const white: [32 * 32 * 3]u8 = @splat(255);
    image.paste(&white, 32, 32, 0, 0);
    var canvas = try Canvas.init(allocator, 1200, 1200);
    defer canvas.deinit(allocator);
    try canvas.glow(allocator, &image, 584, 584, 1.0);
    const near = (600 * 1200 + 640) * 3;
    try std.testing.expect(canvas.rgb[near] > 0);
    try std.testing.expectEqual(@as(u8, 0), canvas.rgb[0]);
}
