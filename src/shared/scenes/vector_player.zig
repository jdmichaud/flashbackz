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
/// Backspace or Tab, or the joystick's inventory button with the joystick option. Escape does
/// too, although the original ignores it in films (user decision, 2026-10-09), and so does a
/// pad's START (PLAN GS-3). A key already held when the film opened does not count, even as it
/// repeats.
pub fn skips(input: platform.Event.Payload, joystick: bool) bool {
    return switch (input) {
        .key_down => |key| !key.repeat and (key.key == .tab or key.key == .backspace or key.key == .escape),
        .controller_button_down => |change| (joystick and change.button == .y) or change.button == .start,
        else => false,
    };
}

pub const Player = struct {
    movie: content.OwnedFilm,
    playback: film.Playback,
    cadence: Cadence,
    origin_ns: ?u64 = null,
    confirmed: bool = false,
    /// P's toggle as the film last saw it.
    pause_requested: bool = false,
    /// Since when the film stands still for P.
    paused_at: ?u64 = null,
    pub fn interactive(self: *const Player) bool {
        for (self.movie.frames) |frame| if (frame.input_loop_start != null or frame.confirm_ends) return true;
        return false;
    }
    pub fn awaitingInput(self: *const Player) bool {
        if (self.playback.finished or self.confirmed) return false;
        if (self.movie.frames[self.playback.frame].confirm_ends) return true;
        for (self.movie.frames, 0..) |frame, end| if (frame.input_loop_start) |start| {
            if (self.playback.frame >= start and self.playback.frame <= end) return true;
        };
        return false;
    }
    fn staticInputWait(self: *const Player) bool {
        const frame = self.movie.frames[self.playback.frame];
        return frame.input_loop_start == self.playback.frame and frame.loop_ticks == 0;
    }
    /// How long the frame shown now stays: until its loop starts again while unconfirmed.
    fn shownTicks(self: *const Player) u32 {
        const frame = self.movie.frames[self.playback.frame];
        return if (frame.input_loop_start != null and !self.confirmed) frame.loop_ticks else frame.hold_ticks;
    }
    pub fn confirm(self: *Player) void {
        if (self.awaitingInput()) self.confirmed = true;
    }

    /// P's toggle, which the original's film player reads between its commands: the film
    /// stops after the picture it is presenting (a film not started yet, before its first),
    /// and when P is pressed again the next picture comes at once, its hold having run out
    /// meanwhile. The music plays on.
    pub fn setPaused(self: *Player, paused: bool, now_ns: u64) void {
        self.pause_requested = paused;
        if (paused) {
            if (self.origin_ns == null and self.paused_at == null) self.paused_at = now_ns;
            return;
        }
        if (self.paused_at == null) return;
        self.paused_at = null;
        if (self.origin_ns) |*origin| origin.* = now_ns -| self.cadence.deadline_ns;
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
        if (self.paused_at != null) return self.playback.finished;
        if (self.origin_ns == null) self.origin_ns = now_ns;
        if (!self.needsCatchup(now_ns)) return self.playback.finished;
        try self.present(now_ns);
        if (self.pause_requested) self.paused_at = now_ns;
        return self.playback.finished;
    }

    fn present(self: *Player, now_ns: u64) !void {
        if (self.movie.frames[self.playback.frame].confirm_ends and self.confirmed) {
            self.playback.finished = true;
            return;
        }
        if (self.movie.frames[self.playback.frame].input_loop_start) |start| {
            if (!self.confirmed) {
                self.playback.frame = start;
                try self.cadence.hold(self.shownTicks());
                self.rebase();
                return;
            }
            if (self.staticInputWait()) self.origin_ns = now_ns -| self.cadence.deadline_ns;
            self.confirmed = false;
        }
        if (self.playback.advance(self.movie.view())) {
            try self.cadence.hold(self.shownTicks());
        }
    }
    /// A page waits for its answer as long as the player does. After ten minutes the film's
    /// time origin moves forward, its next deadline staying where it is, so that the cadence's
    /// arithmetic stays within its bound.
    fn rebase(self: *Player) void {
        const origin = &(self.origin_ns orelse return);
        if (self.cadence.deadline_ns < 600 * std.time.ns_per_s) return;
        const shift = (self.cadence.deadline_ns / Cadence.refresh_ns - 1) * Cadence.refresh_ns;
        self.cadence.deadline_ns -= shift;
        origin.* += shift;
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
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 8, .input_loop_start = 0, .loop_ticks = 8 },
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

test "a map terminal's blink repeats until a confirmation, which ends it after the picture shown" {
    const allocator = std.testing.allocator;
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    // The marker on (a confirmation then ends the film), the marker off (the loop back, the
    // film's last picture: nothing follows it once confirmed).
    const frames = [_]film.Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4, .confirm_ends = true },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 0, .input_loop_start = 0, .loop_ticks = 4 },
    };
    for ([_]usize{ 0, 1 }) |confirmed_on| {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        var player: Player = .{
            .movie = .{ .allocator = allocator, .arena = arena, .frames = &frames },
            .playback = try film.Playback.init(.{ .frames = &frames }),
            .cadence = .{},
            .origin_ns = 0,
        };
        defer player.deinit();
        try player.cadence.hold(frames[0].hold_ticks);
        // Unanswered, it blinks: 0, 1, 0, 1, each picture shown for a while.
        for (0..4) |_| {
            const shown = player.cadence.deadline_ns;
            try std.testing.expect(!try player.update(shown));
            try std.testing.expect(player.cadence.deadline_ns > shown);
        }
        try std.testing.expectEqual(@as(usize, 0), player.playback.frame);
        if (confirmed_on == 1) try std.testing.expect(!try player.update(player.cadence.deadline_ns));
        try std.testing.expectEqual(confirmed_on, player.playback.frame);
        try std.testing.expect(player.awaitingInput());
        player.confirm();
        try std.testing.expect(try player.update(player.cadence.deadline_ns));
    }
}

test "only a fresh press of the inventory key or Escape skips a film" {
    try std.testing.expect(skips(.{ .key_down = .{ .key = .tab } }, false));
    try std.testing.expect(skips(.{ .key_down = .{ .key = .backspace } }, false));
    try std.testing.expect(skips(.{ .key_down = .{ .key = .escape } }, false));
    try std.testing.expect(!skips(.{ .key_down = .{ .key = .tab, .repeat = true } }, false));
    try std.testing.expect(!skips(.{ .key_down = .{ .key = .escape, .repeat = true } }, false));
    for ([_]platform.Key{ .enter, .space, .left_shift, .right_shift, .p }) |key| {
        try std.testing.expect(!skips(.{ .key_down = .{ .key = key } }, false));
    }
    const y: platform.Event.ControllerButtonEvent = .{ .controller = @fromBackingInt(@intCast(0)), .button = .y };
    try std.testing.expect(!skips(.{ .controller_button_down = y }, false));
    try std.testing.expect(skips(.{ .controller_button_down = y }, true));
}

test "a page waiting for its answer can wait for hours" {
    const allocator = std.testing.allocator;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]film.Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 8, .input_loop_start = 0, .loop_ticks = 8 },
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
    var now: u64 = 0;
    while (now < 3 * 3600 * std.time.ns_per_s) : (now += 50 * std.time.ns_per_ms) {
        try std.testing.expect(!try player.update(now));
    }
    try std.testing.expect(player.awaitingInput());
    player.confirm();
    while (!try player.update(now)) now += 50 * std.time.ns_per_ms;
}

test "P stops a film after its picture, and the next picture comes at once when P is pressed again" {
    const allocator = std.testing.allocator;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    const colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const frames = [_]film.Frame{
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
        .{ .drawings = &.{}, .colors = colors, .hold_ticks = 4 },
    };
    var player: Player = .{
        .movie = .{ .allocator = allocator, .arena = arena, .frames = &frames },
        .playback = try film.Playback.init(.{ .frames = &frames }),
        .cadence = .{},
    };
    defer player.deinit();
    try player.cadence.hold(frames[0].hold_ticks);
    // Not started yet: it stands before its first picture, which then holds from the resume.
    player.setPaused(true, 0);
    _ = try player.update(std.time.ns_per_s);
    try std.testing.expectEqual(@as(?u64, null), player.origin_ns);
    player.setPaused(false, std.time.ns_per_s);
    _ = try player.update(std.time.ns_per_s);
    const first = std.time.ns_per_s + player.cadence.deadline_ns;
    try std.testing.expect(!player.needsCatchup(first - 1));
    // Pressed and pressed again within a hold: nothing happens.
    player.setPaused(true, first - 2);
    player.setPaused(false, first - 1);
    _ = try player.update(first);
    try std.testing.expectEqual(@as(usize, 1), player.playback.frame);
    // Pressed during a hold: the picture in progress is presented, then the film stands.
    player.setPaused(true, first + 1);
    const second = std.time.ns_per_s + player.cadence.deadline_ns;
    _ = try player.update(second);
    try std.testing.expectEqual(@as(usize, 2), player.playback.frame);
    _ = try player.update(second + 5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 2), player.playback.frame);
    // Pressed again: the next picture is due at once.
    const resume_ns = second + 5 * std.time.ns_per_s;
    player.setPaused(false, resume_ns);
    _ = try player.update(resume_ns);
    try std.testing.expectEqual(@as(usize, 3), player.playback.frame);
}
