//! Cinematic presentation owns one imported film. A logical hold clock and presentation
//! cadence are independent of the host's refresh rate; no DOS program state is retained.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/vector_cinematic.zig");
const film = @import("../vector_film.zig");
const palette = @import("../content/palette.zig");

/// When a film presents: a present waits for its timer ticks, then for the next display refresh.
pub const Cadence = struct {
    // English reference profile: calibrated hold ticks and the measured video cadence.
    const timer_numerator: u64 = 17_024 * std.time.ns_per_s;
    const timer_denominator: u64 = 1_193_182;
    const refresh_ns: u64 = 16_683_217;
    deadline_ns: u64 = 0,

    /// Timer ticks elapsed at the deadline.
    pub fn elapsedTicks(self: Cadence) u64 {
        return self.deadline_ns * timer_denominator / timer_numerator;
    }

    pub fn hold(self: *Cadence, ticks: u32) !void {
        if (ticks == 0) return;
        if (self.deadline_ns > 3600 * std.time.ns_per_s) return error.CinematicDurationTooLarge;
        const target_tick = try std.math.add(u64, self.elapsedTicks(), ticks);
        const whole = target_tick / timer_denominator;
        const rest = target_tick % timer_denominator;
        const target_ns = try std.math.add(
            u64,
            try std.math.mul(u64, whole, timer_numerator),
            try std.math.divCeil(
                u64,
                try std.math.mul(u64, rest, timer_numerator),
                timer_denominator,
            ),
        );
        self.deadline_ns = try std.math.mul(u64, target_ns / refresh_ns + 1, refresh_ns);
    }
};

/// The original's film player ends a film when the inventory key is pressed while it plays:
/// Backspace or Tab, or the joystick's inventory button with the joystick option. A key already
/// held when the film opened does not count, even as it repeats.
pub fn skips(input: platform.Event.Payload, joystick: bool) bool {
    return switch (input) {
        .key_down => |key| !key.repeat and (key.key == .tab or key.key == .backspace),
        .controller_button_down => |change| joystick and change.button == .y,
        else => false,
    };
}

pub const Player = struct {
    movie: content.OwnedFilm,
    playback: film.Playback,
    cadence: Cadence,
    origin_ns: ?u64 = null,
    confirmed: bool = false,
    /// When P paused the pictures; the time paused does not count.
    paused_at: ?u64 = null,
    pub fn interactive(self: *const Player) bool {
        for (self.movie.frames) |frame| if (frame.input_loop_start != null) return true;
        return false;
    }
    pub fn awaitingInput(self: *const Player) bool {
        if (self.playback.finished or self.confirmed) return false;
        for (self.movie.frames, 0..) |frame, end| if (frame.input_loop_start) |start| {
            if (self.playback.frame >= start and self.playback.frame <= end) return true;
        };
        return false;
    }
    fn staticInputWait(self: *const Player) bool {
        const frame = self.movie.frames[self.playback.frame];
        return frame.input_loop_start == self.playback.frame and frame.hold_ticks == 0;
    }
    pub fn confirm(self: *Player) void {
        if (self.awaitingInput()) self.confirmed = true;
    }

    /// P stops the pictures, and P again resumes them; the music plays on.
    pub fn togglePause(self: *Player, now_ns: u64) void {
        if (self.paused_at) |at| {
            if (self.origin_ns) |*origin| origin.* +|= now_ns -| at;
            self.paused_at = null;
        } else self.paused_at = now_ns;
    }

    pub fn open(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        name: []const u8,
        entry: u16,
    ) !Player {
        var movie = try content.load(allocator, source, name, entry);
        errdefer movie.deinit();
        const playback = try film.Playback.init(movie.view());
        var cadence: Cadence = .{};
        try cadence.hold(movie.frames[0].hold_ticks);
        return .{ .movie = movie, .playback = playback, .cadence = cadence };
    }
    pub fn deinit(self: *Player) void {
        self.movie.deinit();
        self.* = undefined;
    }
    pub fn update(self: *Player, now_ns: u64) !bool {
        if (self.origin_ns == null) self.origin_ns = now_ns;
        if (self.paused_at != null) return self.playback.finished;
        if (self.needsCatchup(now_ns)) {
            if (self.movie.frames[self.playback.frame].input_loop_start) |start| {
                if (!self.confirmed) {
                    self.playback.frame = start;
                    const ticks = self.movie.frames[start].hold_ticks;
                    self.playback.next_tick = try std.math.add(u64, self.playback.next_tick, ticks);
                    try self.cadence.hold(ticks);
                    return false;
                }
                if (self.staticInputWait()) self.origin_ns = now_ns -| self.cadence.deadline_ns;
                self.confirmed = false;
            }
            if (try self.playback.advance(self.movie.view(), self.playback.next_tick)) {
                try self.cadence.hold(self.movie.frames[self.playback.frame].hold_ticks);
            }
        }
        return self.playback.finished;
    }
    pub fn needsCatchup(self: *const Player, now_ns: u64) bool {
        if (self.paused_at != null) return false;
        if (self.staticInputWait() and !self.confirmed) return false;
        const origin = self.origin_ns orelse return false;
        return !self.playback.finished and now_ns -| origin >= self.cadence.deadline_ns;
    }
    pub fn draw(self: *const Player, indices: []u8, rgba: []u8) !void {
        try self.movie.view().draw(self.playback.frame, indices, rgba);
    }
};

test "presentation cadence remains bounded and host-rate independent" {
    var cadence: Cadence = .{};
    try cadence.hold(4);
    const first = cadence.deadline_ns;
    try std.testing.expect(first >= 50_000_000 and first <= 70_000_000);
    try cadence.hold(32);
    try std.testing.expect(cadence.deadline_ns > first + 400_000_000);
    const before = cadence.deadline_ns;
    try cadence.hold(0);
    try std.testing.expectEqual(before, cadence.deadline_ns);
}

test "confirmation loops keep animating and one confirmation cannot skip the next page" {
    const allocator = std.testing.allocator;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]film.Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 8, .input_loop_start = 0 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 0, .input_loop_start = 2 },
    };
    var player: Player = .{
        .movie = .{ .allocator = allocator, .arena = arena, .frames = &frames },
        .playback = try film.Playback.init(.{ .frames = &frames }),
        .cadence = .{},
        .origin_ns = 0,
    };
    defer player.deinit();
    try player.cadence.hold(frames[0].hold_ticks);
    try std.testing.expect(player.awaitingInput());
    try std.testing.expect(!try player.update(player.cadence.deadline_ns));
    try std.testing.expectEqual(@as(usize, 1), player.playback.frame);
    try std.testing.expect(!try player.update(player.cadence.deadline_ns));
    try std.testing.expectEqual(@as(usize, 0), player.playback.frame);
    player.confirm();
    _ = try player.update(player.cadence.deadline_ns);
    _ = try player.update(player.cadence.deadline_ns);
    try std.testing.expectEqual(@as(usize, 2), player.playback.frame);
    try std.testing.expect(player.awaitingInput());
    try std.testing.expect(!try player.update(player.cadence.deadline_ns));
    player.confirm();
    try std.testing.expect(try player.update(player.cadence.deadline_ns));
}

test "only a fresh press of the inventory key skips a film" {
    try std.testing.expect(skips(.{ .key_down = .{ .key = .tab } }, false));
    try std.testing.expect(skips(.{ .key_down = .{ .key = .backspace } }, false));
    try std.testing.expect(!skips(.{ .key_down = .{ .key = .tab, .repeat = true } }, false));
    for ([_]platform.Key{ .escape, .enter, .space, .left_shift, .right_shift, .p }) |key| {
        try std.testing.expect(!skips(.{ .key_down = .{ .key = key } }, false));
    }
    const y: platform.Event.ControllerButtonEvent = .{ .controller = @fromBackingInt(@intCast(0)), .button = .y };
    try std.testing.expect(!skips(.{ .controller_button_down = y }, false));
    try std.testing.expect(skips(.{ .controller_button_down = y }, true));
}

test "a paused film keeps its picture and resumes where it stopped" {
    const allocator = std.testing.allocator;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]film.Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
    };
    var player: Player = .{
        .movie = .{ .allocator = allocator, .arena = arena, .frames = &frames },
        .playback = try film.Playback.init(.{ .frames = &frames }),
        .cadence = .{},
        .origin_ns = 0,
    };
    defer player.deinit();
    try player.cadence.hold(frames[0].hold_ticks);
    const due = player.cadence.deadline_ns;
    player.togglePause(due - 1);
    try std.testing.expect(!player.needsCatchup(due + std.time.ns_per_s));
    _ = try player.update(due + std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 0), player.playback.frame);
    player.togglePause(due + std.time.ns_per_s);
    try std.testing.expect(!player.needsCatchup(due + std.time.ns_per_s - 2));
    try std.testing.expect(player.needsCatchup(due + std.time.ns_per_s + 1));
    _ = try player.update(due + std.time.ns_per_s + 1);
    try std.testing.expectEqual(@as(usize, 1), player.playback.frame);
}
