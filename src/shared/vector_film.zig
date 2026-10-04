//! Immutable vector frames and ordered playback. Content importers resolve source scripts
//! into pictures and holds; playback has no source commands, executable offsets or jump table.
const std = @import("std");
const shapes = @import("render/indexed_shapes.zig");
const font_mod = @import("content/font.zig");
const text_renderer = @import("render/text.zig");
const palette = @import("content/palette.zig");

pub const TextRun = struct { text: []const u8, x: i16, y: i16, foreground: u8 };

pub const Drawing = struct {
    geometry: union(enum) {
        polygon: []const shapes.Point,
        text: TextRun,
        ellipse: struct { center: shapes.Point, radius_x: u16, radius_y: u16 },
    },
    ink: shapes.Ink,
};

pub const Frame = struct {
    drawings: []const Drawing,
    colors: palette.Palette,
    hold_ticks: u32,
    background: u8 = 0xc0,
    captions: []const TextRun = &.{},
    caption_band: bool = false,
};

pub const View = struct {
    frames: []const Frame,
    font: ?font_mod.Font = null,
    width: u16 = 256,
    height: u16 = 224,
    viewport: shapes.Rect = .{ .x = 8, .y = 50, .width = 240, .height = 128 },
    background: u8 = 0,

    pub fn validate(self: View) !void {
        if (self.frames.len == 0) return error.EmptyFilm;
        if (self.frames.len > 10000 or self.width == 0 or self.height == 0) return error.InvalidFilm;
    }

    pub fn draw(self: View, frame_index: usize, pixels: []u8, rgba: []u8) !void {
        if (frame_index >= self.frames.len or pixels.len != @as(usize, self.width) * self.height) return error.InvalidFilmFrame;
        @memset(pixels, self.background);
        const frame = self.frames[frame_index];
        const canvas: shapes.Canvas = .{ .pixels = pixels, .width = self.width, .height = self.height, .clip = self.viewport };
        const left = @max(@as(i32, self.viewport.x), 0);
        const right = @min(@as(i32, self.viewport.x) + self.viewport.width, self.width);
        var y = @max(@as(i32, self.viewport.y), 0);
        const bottom = @min(@as(i32, self.viewport.y) + self.viewport.height, self.height);
        while (y < bottom) : (y += 1) {
            if (left < right) @memset(pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(left)) ..][0..@intCast(right - left)], frame.background);
        }
        for (frame.drawings) |drawing| switch (drawing.geometry) {
            .polygon => |points| try canvas.draw(points, drawing.ink),
            .ellipse => |ellipse| try canvas.ellipse(ellipse.center, ellipse.radius_x, ellipse.radius_y, drawing.ink),
            .text => |run| try self.drawText(pixels, run),
        };
        if (frame.caption_band) {
            const start = @min(pixels.len, @as(usize, self.width) * 178);
            const end = @min(pixels.len, @as(usize, self.width) * 203);
            @memset(pixels[start..end], 0xc0);
        }
        for (frame.captions) |run| try self.drawText(pixels, run);
        try palette.writeRgba(pixels, &frame.colors, rgba);
    }
    fn drawText(self: View, pixels: []u8, run: TextRun) !void {
        const font = self.font orelse return error.MissingCinematicFont;
        try text_renderer.draw(pixels, self.width, self.height, &font, run.text, run.x, run.y, .{ .foreground = run.foreground, .shadow = 0xe2, .palette_bank = 14 });
    }
};

pub const Playback = struct {
    frame: usize = 0,
    next_tick: u64,
    finished: bool = false,

    pub fn init(film: View) !Playback {
        try film.validate();
        return .{ .next_tick = film.frames[0].hold_ticks };
    }

    /// Advance at most one visible frame. A late host can call again while needsCatchup is
    /// true, preserving the order of all presentations instead of silently skipping pictures.
    pub fn advance(self: *Playback, film: View, elapsed_ticks: u64) !bool {
        if (!self.needsCatchup(elapsed_ticks)) return false;
        if (self.frame + 1 == film.frames.len) {
            self.finished = true;
            return false;
        }
        self.frame += 1;
        self.next_tick = try std.math.add(u64, self.next_tick, film.frames[self.frame].hold_ticks);
        return true;
    }

    pub fn needsCatchup(self: Playback, elapsed_ticks: u64) bool {
        return !self.finished and elapsed_ticks >= self.next_tick;
    }
};

test "late playback preserves frame order, exact hold boundaries and final completion" {
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 9 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 2 },
    };
    const film: View = .{ .frames = &frames };
    var player = try Playback.init(film);
    try std.testing.expect(!try player.advance(film, 3));
    try std.testing.expect(try player.advance(film, 4));
    try std.testing.expectEqual(@as(usize, 1), player.frame);
    try std.testing.expect(!try player.advance(film, 12));
    try std.testing.expect(try player.advance(film, 100));
    try std.testing.expectEqual(@as(usize, 2), player.frame);
    try std.testing.expect(player.needsCatchup(100));
    try std.testing.expect(!try player.advance(film, 100));
    try std.testing.expect(player.finished);
    try std.testing.expectError(error.EmptyFilm, Playback.init(.{ .frames = &.{} }));
}
