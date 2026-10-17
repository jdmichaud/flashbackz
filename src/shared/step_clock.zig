//! Exact deadlines on the original's clocks, whatever the host's rate. A clock counts ticks of
//! a fixed rate: the PC timer's for play, the VGA refresh for the modal screens. Each deadline
//! is the exact time of a tick, kept as a whole part and a fraction, so no error of rounding adds
//! up over a long run.
const std = @import("std");

/// The PC's interval timer counts at 1,193,182 Hz, and the original has it interrupt every
/// 17,024 counts: the game's tick, about 70.09 a second.
pub const timer_hz = 1_193_182;
pub const counts_per_tick = 17_024;
/// A tick, rounded down to the nanosecond.
pub const tick_ns: u64 = counts_per_tick * std.time.ns_per_s / timer_hz;

/// The VGA's 25.175 MHz dot clock draws 800 by 525 dots a frame: 59.94 frames a second.
pub const vga_dots_per_second = 25_175_000;
pub const vga_dots_per_frame = 800 * 525;
/// A VGA frame, rounded down to the nanosecond.
pub const vga_frame_ns: u64 = vga_dots_per_frame * std.time.ns_per_s / vga_dots_per_second;

/// Whole timer ticks in `ns` nanoseconds.
pub fn ticksIn(ns: u64) u64 {
    const counts = ns / std.time.ns_per_s * timer_hz +
        ns % std.time.ns_per_s * timer_hz / std.time.ns_per_s;
    return counts / counts_per_tick;
}

/// A tick rate and the gaps between deadlines. A tick lasts `units_per_tick` units of a clock
/// that counts `units_per_second` a second. The first gap is `initial_gap_ticks`, and the
/// later gaps are `regular_gap_ticks`.
pub const Cadence = struct {
    units_per_second: u32,
    units_per_tick: u32,
    initial_gap_ticks: u32,
    regular_gap_ticks: u32,
};

/// Every level's: three ticks after the first frame, then two ticks a frame.
pub const level: Cadence = .{
    .units_per_second = timer_hz,
    .units_per_tick = counts_per_tick,
    .initial_gap_ticks = 3,
    .regular_gap_ticks = 2,
};
/// The modal screens' polls follow the VGA refresh, not the timer: one poll every refresh. The
/// inventory, the options dialog and the continue screen use it. A world message uses it with
/// gaps of three refreshes.
pub const inventory: Cadence = .{
    .units_per_second = vga_dots_per_second,
    .units_per_tick = vga_dots_per_frame,
    .initial_gap_ticks = 1,
    .regular_gap_ticks = 1,
};

/// Deadlines on one cadence, from `origin_ns`.
pub const Clock = struct {
    cadence: Cadence,
    /// The time of tick 0 on the host's clock. The callers move it forward to skip a pause:
    /// the level scene skips a modal screen or a film this way.
    origin_ns: u64,
    /// The tick of the deadline.
    next_tick: u64 = 0,
    /// The deadlines consumed so far. The first gap is the initial one.
    emitted: u64 = 0,
    /// The deadline after `origin_ns`, exactly: `elapsed_ns + remainder / units_per_second`
    /// nanoseconds. `remainder` is below `units_per_second`.
    elapsed_ns: u64 = 0,
    remainder: u64 = 0,

    pub fn init(cadence: Cadence, origin_ns: u64) !Clock {
        const largest_gap = @as(u64, cadence.units_per_tick) *
            @max(cadence.initial_gap_ticks, cadence.regular_gap_ticks);
        if (cadence.units_per_second == 0 or
            cadence.units_per_tick == 0 or
            cadence.initial_gap_ticks == 0 or
            cadence.regular_gap_ticks == 0 or
            largest_gap >
                (std.math.maxInt(u64) - @as(u64, cadence.units_per_second)) / std.time.ns_per_s) {
            return error.InvalidCadence;
        }
        return .{ .cadence = cadence, .origin_ns = origin_ns };
    }

    /// The deadline on the host's clock. A fraction of a nanosecond rounds it up by 1 ns, so
    /// the deadline is never before the exact tick.
    pub fn deadline(self: Clock) u64 {
        return self.origin_ns +| self.elapsed_ns +| @as(u64, @intFromBool(self.remainder != 0));
    }

    pub fn due(self: Clock, now_ns: u64) bool {
        return now_ns >= self.deadline();
    }

    /// Moves to the next deadline: `initial_gap_ticks` after the first, then
    /// `regular_gap_ticks`.
    pub fn consume(self: *Clock) void {
        self.advance(
            if (self.emitted == 0)
                self.cadence.initial_gap_ticks
            else
                self.cadence.regular_gap_ticks,
        );
        self.emitted += 1;
    }

    /// Moves the deadline `ticks` ticks later.
    pub fn advance(self: *Clock, ticks: u32) void {
        const numerator = @as(u64, ticks) * self.cadence.units_per_tick * std.time.ns_per_s +
            self.remainder;
        self.elapsed_ns +|= numerator / self.cadence.units_per_second;
        self.remainder = numerator % self.cadence.units_per_second;
        self.next_tick += ticks;
    }

    /// True when `ticks` more ticks have passed since the deadline by `now_ns`.
    pub fn behind(self: Clock, now_ns: u64, ticks: u32) bool {
        var later = self;
        later.advance(ticks);
        return later.due(now_ns);
    }

    /// Drops the time up to `now_ns`: the deadline becomes the tick in progress, and later
    /// deadlines keep the interrupt phase. That tick starts at or before `now_ns`, so the
    /// deadline is due at once.
    pub fn restart(self: *Clock, now_ns: u64) !void {
        const elapsed = now_ns -| self.origin_ns;
        const rate = self.cadence.units_per_second;
        const whole = try std.math.mul(u64, elapsed / std.time.ns_per_s, rate);
        const fraction = elapsed % std.time.ns_per_s * @as(u64, rate) / std.time.ns_per_s;
        const units = try std.math.add(u64, whole, fraction);
        self.next_tick = units / self.cadence.units_per_tick;
        const aligned = self.next_tick * self.cadence.units_per_tick;
        const partial = aligned % rate * std.time.ns_per_s;
        self.elapsed_ns = aligned / rate * std.time.ns_per_s + partial / rate;
        self.remainder = partial % rate;
    }
};

test "a restart drops the lost time without shifting the timer phase" {
    var clock = try Clock.init(level, 100);
    clock.consume();
    try clock.restart(1_010_000_100);
    try std.testing.expect(clock.due(1_010_000_100));
    const tick = clock.next_tick;
    clock.consume();
    try std.testing.expectEqual(tick + 2, clock.next_tick);
    try std.testing.expect(!clock.due(1_010_000_100));
}

test "a frame is late once a tick has passed after its wait, and a restart drops the time lost" {
    var clock = try Clock.init(level, 0);
    clock.consume();
    clock.consume();
    var tick_later = clock;
    tick_later.advance(1);
    try std.testing.expect(!clock.behind(tick_later.deadline() - 1, 1));
    try std.testing.expect(clock.behind(tick_later.deadline(), 1));
    const now = tick_later.deadline() + 5 * std.time.ns_per_s;
    try clock.restart(now);
    try std.testing.expect(clock.due(now));
    try std.testing.expect(!clock.behind(now, 1));
    clock.advance(3);
    try std.testing.expect(!clock.due(now));
    try std.testing.expectEqual(tick_later.next_tick + 3 + 350, clock.next_tick);
}

test "deadlines preserve rational phase and first-step spacing without accumulated rounding" {
    var clock = try Clock.init(level, 50);
    try std.testing.expectEqual(@as(u64, 50), clock.deadline());
    clock.consume();
    try std.testing.expectEqual(@as(u64, 3), clock.next_tick);
    const deadline = clock.deadline();
    try std.testing.expect(!clock.due(deadline - 1));
    try std.testing.expect(clock.due(deadline));
    for (0..10000) |_| {
        clock.consume();
    }
    try std.testing.expectEqual(@as(u64, 20003), clock.next_tick);
    const expected: u64 = 50 +
        @as(
            u64,
            @intCast(
                (@as(u128, 20003) * counts_per_tick * std.time.ns_per_s + timer_hz - 1) / timer_hz,
            ),
        );
    try std.testing.expectEqual(expected, clock.deadline());
    var invalid = level;
    invalid.units_per_second = 0;
    try std.testing.expectError(error.InvalidCadence, Clock.init(invalid, 0));
}
