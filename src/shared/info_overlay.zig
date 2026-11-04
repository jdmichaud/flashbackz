//! The information overlay that F3 shows or hides (PLAN UX-4), at the top left of the picture:
//!
//!     FPS 60  TPF   0.9 MS  UPS 35
//!     EARTH CITY
//!     ROOM 34  X 144  Y 142
//!
//! FPS counts the frames presented in the last whole second, and UPS the updates. TPF is the game's
//! mean work for each of those frames, in milliseconds: the updates, the drawing and the sound,
//! but not the host's present, which can wait for the display (with vsync, the frames are
//! 16.7 ms apart however little the work takes). In a level, the next lines give the level, the
//! view room and Conrad's position in his room; outside a level only FPS and TPF show. As the
//! pads' messages are, it is drawn over the presented picture only: the page and the agent's
//! hashes never hold it.
const std = @import("std");
const font_mod = @import("content/font.zig");
const rgba_text = @import("render/rgba_text.zig");

/// The top left corner of the first line.
const left = 8;
const top = 8;

/// What a level adds to the overlay.
pub const Level = struct {
    /// The level's name in the data set, for example `earth_city`.
    name: []const u8,
    view_room: u8,
    /// Conrad's room and position.
    room: u8,
    x: i16,
    y: i16,
};

/// The game's totals at a presented frame.
pub const Totals = struct {
    frames: u64,
    updates: u64,
    /// The time of the game's own work.
    work_ns: u64,
};

pub const InfoOverlay = struct {
    shown: bool = false,
    /// The second being counted: when it started, and the totals then.
    second_start_ns: ?u64 = null,
    at_start: Totals = .{ .frames = 0, .updates = 0, .work_ns = 0 },
    /// The rates of the last whole second.
    fps: u64 = 0,
    ups: u64 = 0,
    /// The mean work for each frame of the last whole second, in nanoseconds.
    tpf_ns: u64 = 0,

    /// Counts the rates at a presented frame. An update total that went back (a new game)
    /// restarts the count.
    pub fn count(self: *InfoOverlay, now_ns: u64, totals: Totals) void {
        const start = self.second_start_ns orelse {
            self.restart(now_ns, totals);
            return;
        };
        if (totals.updates < self.at_start.updates) {
            self.restart(now_ns, totals);
            return;
        }
        const elapsed = now_ns -| start;
        if (elapsed < std.time.ns_per_s) return;
        const frames = totals.frames - self.at_start.frames;
        self.fps = frames * std.time.ns_per_s / elapsed;
        if (frames > 0) {
            self.tpf_ns = (totals.work_ns -| self.at_start.work_ns) / frames;
        }
        self.ups = (totals.updates - self.at_start.updates) * std.time.ns_per_s / elapsed;
        self.restart(now_ns, totals);
    }

    fn restart(self: *InfoOverlay, now_ns: u64, totals: Totals) void {
        self.second_start_ns = now_ns;
        self.at_start = totals;
    }

    /// The lines of the overlay, written in `buffer`.
    pub fn lines(self: *const InfoOverlay, level: ?Level, buffer: *[3][32]u8) [3][]const u8 {
        var result: [3][]const u8 = .{ "", "", "" };
        // The milliseconds with one decimal, padded with spaces to three digits before the point.
        const tpf_ms = @as(f64, @floatFromInt(self.tpf_ns)) / std.time.ns_per_ms;
        const level_shown = level orelse {
            result[0] = std.fmt.bufPrint(&buffer[0], "FPS {d}  TPF {d:>5.1} MS", .{
                self.fps,
                tpf_ms,
            }) catch unreachable;
            return result;
        };
        result[0] = std.fmt.bufPrint(&buffer[0], "FPS {d}  TPF {d:>5.1} MS  UPS {d}", .{
            self.fps,
            tpf_ms,
            self.ups,
        }) catch unreachable;
        const name = buffer[1][0..@min(level_shown.name.len, buffer[1].len)];
        for (name, level_shown.name[0..name.len]) |*out, character| {
            out.* = if (character == '_') ' ' else std.ascii.toUpper(character);
        }
        result[1] = name;
        result[2] = if (level_shown.room == level_shown.view_room)
            std.fmt.bufPrint(&buffer[2], "ROOM {d}  X {d}  Y {d}", .{
                level_shown.view_room,
                level_shown.x,
                level_shown.y,
            }) catch unreachable
        else
            std.fmt.bufPrint(&buffer[2], "ROOM {d}  CONRAD {d} {d} {d}", .{
                level_shown.view_room,
                level_shown.room,
                level_shown.x,
                level_shown.y,
            }) catch unreachable;
        return result;
    }

    /// Draws the overlay over `frame`, an RGBA picture of `width` × `height`, when it is shown.
    pub fn draw(
        self: *const InfoOverlay,
        frame: []u8,
        width: usize,
        height: usize,
        font: *const font_mod.Font,
        level: ?Level,
    ) void {
        if (!self.shown) return;
        var buffer: [3][32]u8 = undefined;
        for (self.lines(level, &buffer), 0..) |line, row| {
            const y = top + row * (font_mod.glyph_height + 2);
            rgba_text.draw(frame, width, height, font, line, left, y, 255);
        }
    }
};

test "the rates are those of the last whole second" {
    var overlay: InfoOverlay = .{};
    overlay.count(0, .{ .frames = 0, .updates = 0, .work_ns = 0 });
    overlay.count(500_000_000, .{ .frames = 30, .updates = 17, .work_ns = 15_000_000 });
    try std.testing.expectEqual(@as(u64, 0), overlay.fps);
    // 60 frames and 60 ms of work: 1 ms a frame, though the frames are 16.7 ms apart.
    overlay.count(1_000_000_000, .{ .frames = 60, .updates = 35, .work_ns = 60_000_000 });
    try std.testing.expectEqual(@as(u64, 60), overlay.fps);
    try std.testing.expectEqual(@as(u64, 35), overlay.ups);
    try std.testing.expectEqual(@as(u64, 1_000_000), overlay.tpf_ns);
    // Two seconds with 100 frames, 70 updates and 250 ms of work: 50 and 35 a second, 2.5 ms a
    // frame.
    overlay.count(3_000_000_000, .{ .frames = 160, .updates = 105, .work_ns = 310_000_000 });
    try std.testing.expectEqual(@as(u64, 50), overlay.fps);
    try std.testing.expectEqual(@as(u64, 35), overlay.ups);
    try std.testing.expectEqual(@as(u64, 2_500_000), overlay.tpf_ns);
    // A new game's update total goes back: the count starts again, the last rates stay.
    overlay.count(3_100_000_000, .{ .frames = 166, .updates = 3, .work_ns = 320_000_000 });
    try std.testing.expectEqual(@as(u64, 35), overlay.ups);
    overlay.count(4_100_000_000, .{ .frames = 226, .updates = 38, .work_ns = 380_000_000 });
    try std.testing.expectEqual(@as(u64, 35), overlay.ups);
    try std.testing.expectEqual(@as(u64, 1_000_000), overlay.tpf_ns);
}

test "the lines give the rates, and in a level its name, the room and Conrad" {
    var overlay: InfoOverlay = .{ .fps = 60, .ups = 35, .tpf_ns = 912_345 };
    var buffer: [3][32]u8 = undefined;
    const outside = overlay.lines(null, &buffer);
    try std.testing.expectEqualStrings("FPS 60  TPF   0.9 MS", outside[0]);
    try std.testing.expectEqualStrings("", outside[1]);
    const level: Level = .{ .name = "earth_city", .view_room = 34, .room = 34, .x = 144, .y = -2 };
    const inside = overlay.lines(level, &buffer);
    try std.testing.expectEqualStrings("FPS 60  TPF   0.9 MS  UPS 35", inside[0]);
    try std.testing.expectEqualStrings("EARTH CITY", inside[1]);
    try std.testing.expectEqualStrings("ROOM 34  X 144  Y -2", inside[2]);
    var away = level;
    away.room = 35;
    try std.testing.expectEqualStrings(
        "ROOM 34  CONRAD 35 144 -2",
        overlay.lines(away, &buffer)[2],
    );
    // The padding keeps the point in place from 1 to 999 ms; more widens the line.
    overlay.tpf_ns = 16_666_666;
    try std.testing.expectEqualStrings("FPS 60  TPF  16.7 MS", overlay.lines(null, &buffer)[0]);
    overlay.fps = 0;
    overlay.tpf_ns = 1_234_560_000;
    try std.testing.expectEqualStrings("FPS 0  TPF 1234.6 MS", overlay.lines(null, &buffer)[0]);
}

test "the overlay draws only when shown" {
    var font = try rgba_text.testFont(std.testing.allocator);
    defer font.deinit();
    var frame: [64 * 32 * 4]u8 = @splat(100);
    var overlay: InfoOverlay = .{};
    overlay.draw(&frame, 64, 32, &font, null);
    try std.testing.expectEqual(@as(u8, 100), frame[(top * 64 + left) * 4]);
    overlay.shown = true;
    overlay.draw(&frame, 64, 32, &font, null);
    try std.testing.expectEqual(@as(u8, 255), frame[(top * 64 + left) * 4]);
}
