//! Immutable vector frames and ordered playback. Content importers resolve source scripts
//! into pictures and holds; playback has no source commands, executable offsets or jump table.
const std = @import("std");
const shapes = @import("render/indexed_shapes.zig");
const font_mod = @import("content/font.zig");
const text_renderer = @import("render/text.zig");
const palette = @import("content/palette.zig");

pub const TextRun = struct {
    text: []const u8,
    x: i16,
    y: i16,
    foreground: u8,
};

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
    /// At this frame, repeat the named frame range until the viewer confirms.
    input_loop_start: ?usize = null,
    /// Unconfirmed, how long this frame shows before the loop shows its first frame again;
    /// `hold_ticks` is how long it shows before the next frame once confirmed.
    loop_ticks: u32 = 0,
    /// A confirmation pending once this frame has been shown ends the film: the original
    /// checks the keys after the present and branches to the film's end (the city's map
    /// terminals, MAP entries 0 to 3, between the blinks of their marker).
    confirm_ends: bool = false,
    background: u8 = 0xc0,
    captions: []const TextRun = &.{},
    caption_band: bool = false,
    /// In the ending's replay mode the picture is presented once, with this period in timer
    /// ticks, then again `held_presents` times, every 2 ticks, for the waits that follow it. The
    /// first frame of a film is not presented by itself.
    presented: bool = true,
    present_ticks: u8 = 4,
    held_presents: u32 = 0,
    replay_present: ReplayPresent = .picture,
    /// A new background before this frame ends the hold of the picture.
    ends_hold: bool = false,
    /// Whether this present shows the caption's bottom row. Each frame restores the picture and
    /// eight rows per caption line from a saved page, one row short of the caption's last, so
    /// that row shows only on the display page the caption was drawn on.
    caption_tail: bool = true,
};

/// How a frame's own present treats the ending's credits in replay mode.
pub const ReplayPresent = enum {
    /// A new picture, with the credits typed over it. Afterwards the picture is not held.
    picture,
    /// A page the viewer could confirm: presented without the credits, then held.
    page,
    /// The shown picture held for a moment: presented again with the credits.
    hold,
};

pub const View = struct {
    frames: []const Frame,
    font: ?font_mod.Font = null,
    width: u16 = 256,
    height: u16 = 224,
    viewport: shapes.Rect = .{ .x = 8, .y = 50, .width = 240, .height = 128 },
    background: u8 = 0,
    /// The ending's replay mode leaves out the films' captions and placed texts.
    texts: bool = true,

    pub fn validate(self: View) !void {
        if (self.frames.len == 0) return error.EmptyFilm;
        if (self.frames.len > 10000 or
            self.width == 0 or
            self.height == 0) {
            return error.InvalidFilm;
        }
        for (self.frames, 0..) |frame, end| {
            if (frame.input_loop_start) |start| {
                if (start > end) return error.InvalidFilmInputLoop;
                var timed = frame.loop_ticks != 0;
                for (self.frames[start..end]) |loop_frame| {
                    timed = timed or loop_frame.hold_ticks != 0;
                }
                if (!timed and start != end) return error.UnboundedFilmInputLoop;
            }
        }
    }

    /// Frame `frame_index` as palette indices in `pixels`, and as RGBA in `rgba`.
    pub fn draw(self: View, frame_index: usize, pixels: []u8, rgba: []u8) !void {
        try self.drawPicture(frame_index, pixels);
        try palette.writeRgba(pixels, &self.frames[frame_index].colors, rgba);
    }

    /// Frame `frame_index` as palette indices.
    pub fn drawPicture(self: View, frame_index: usize, pixels: []u8) !void {
        if (frame_index >= self.frames.len or
            pixels.len != @as(usize, self.width) * self.height) {
            return error.InvalidFilmFrame;
        }
        @memset(pixels, self.background);
        const frame = self.frames[frame_index];
        const canvas: shapes.Canvas = .{
            .pixels = pixels,
            .width = self.width,
            .height = self.height,
            .clip = self.viewport,
        };
        const left = @max(@as(i32, self.viewport.x), 0);
        const right = @min(@as(i32, self.viewport.x) + self.viewport.width, self.width);
        var y = @max(@as(i32, self.viewport.y), 0);
        const bottom = @min(@as(i32, self.viewport.y) + self.viewport.height, self.height);
        while (y < bottom) : (y += 1) {
            if (left < right) {
                @memset(
                    pixels[@as(usize, @intCast(y)) * self.width +
                        @as(usize, @intCast(left))..][0..@intCast(right - left)],
                    frame.background,
                );
            }
        }
        for (frame.drawings) |drawing| {
            switch (drawing.geometry) {
                .polygon => |points| try canvas.draw(points, drawing.ink),
                .ellipse => |ellipse| try canvas.ellipse(
                    ellipse.center,
                    ellipse.radius_x,
                    ellipse.radius_y,
                    drawing.ink,
                ),
                .text => |run| if (self.texts) try self.drawText(pixels, self.height, run),
            }
        }
        if (!self.texts) return;
        if (frame.caption_band) {
            const start = @min(pixels.len, @as(usize, self.width) * 178);
            const end = @min(pixels.len, @as(usize, self.width) * 203);
            @memset(pixels[start..end], 0xc0);
        }
        const caption_rows: usize = if (frame.caption_tail)
            self.height
        else
            @min(self.height, 178 + 8 * frame.captions.len);
        for (frame.captions) |run| {
            try self.drawText(pixels[0..caption_rows * self.width], @intCast(caption_rows), run);
        }
    }
    fn drawText(self: View, pixels: []u8, rows: u16, run: TextRun) !void {
        const font = self.font orelse return error.MissingCinematicFont;
        try text_renderer.draw(
            pixels,
            self.width,
            rows,
            &font,
            run.text,
            run.x,
            run.y,
            .{ .foreground = run.foreground, .shadow = 0xe2, .palette_bank = 14 },
        );
    }
};

/// Where a film is: the frame shown, and whether it is over. The player's cadence decides when
/// the next frame comes (`scenes/vector_player.zig`).
pub const Playback = struct {
    frame: usize = 0,
    finished: bool = false,

    pub fn init(film: View) !Playback {
        try film.validate();
        return .{};
    }

    /// Shows the next frame; after the last one, the film is over. True when a frame was shown.
    pub fn advance(self: *Playback, film: View) bool {
        if (self.finished) return false;
        if (self.frame + 1 == film.frames.len) {
            self.finished = true;
            return false;
        }
        self.frame += 1;
        return true;
    }
};

test "playback shows each frame in order, then ends" {
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 9 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 2 },
    };
    const film: View = .{ .frames = &frames };
    var player = try Playback.init(film);
    try std.testing.expect(player.advance(film));
    try std.testing.expect(player.advance(film));
    try std.testing.expectEqual(@as(usize, 2), player.frame);
    try std.testing.expect(!player.advance(film));
    try std.testing.expect(player.finished);
    try std.testing.expect(!player.advance(film));
    try std.testing.expectError(error.EmptyFilm, Playback.init(.{ .frames = &.{} }));
}
