//! Rational deadlines for discrete simulation. Host presentation rate never sets movement
//! speed. Gameplay follows the original's tick counter: a frame waits two ticks, and a frame
//! that ends late restarts the clock (the level scene's catch-up walks).
const std = @import("std");

pub const Cadence = struct {
    units_per_second: u32,
    units_per_tick: u32,
    initial_gap_ticks: u32,
    regular_gap_ticks: u32,
};

pub const jungle: Cadence = .{
    .units_per_second = 1193182,
    .units_per_tick = 17024,
    .initial_gap_ticks = 3,
    .regular_gap_ticks = 2,
};
// Inventory polls follow the VGA refresh rather than the gameplay interrupt cadence.
// Entry/exit work and its phase relative to gameplay remain part of scheduler acceptance.
pub const inventory: Cadence = .{
    .units_per_second = 25175000,
    .units_per_tick = 420000,
    .initial_gap_ticks = 1,
    .regular_gap_ticks = 1,
};

pub const Clock = struct {
    cadence: Cadence,
    origin_ns: u64,
    next_tick: u64 = 0,
    emitted: u64 = 0,
    elapsed_ns: u64 = 0,
    remainder: u64 = 0,

    pub fn init(cadence: Cadence, origin_ns: u64) !Clock {
        const largest_gap = @as(u64, cadence.units_per_tick) * @max(
            cadence.initial_gap_ticks,
            cadence.regular_gap_ticks,
        );
        if (cadence.units_per_second == 0 or
            cadence.units_per_tick == 0 or
            cadence.initial_gap_ticks == 0 or
            cadence.regular_gap_ticks == 0 or
            largest_gap > (std.math.maxInt(u64) - @as(u64, cadence.units_per_second)) / std.time.ns_per_s) return error.InvalidCadence;
        return .{ .cadence = cadence, .origin_ns = origin_ns };
    }

    pub fn deadline(self: Clock) u64 {
        return self.origin_ns +| self.elapsed_ns +| @as(u64, @intFromBool(self.remainder != 0));
    }

    pub fn due(self: Clock, now_ns: u64) bool {
        return now_ns >= self.deadline();
    }

    pub fn consume(self: *Clock) void {
        self.advance(if (self.emitted == 0) self.cadence.initial_gap_ticks else self.cadence.regular_gap_ticks);
        self.emitted += 1;
    }

    /// Moves the deadline `ticks` ticks later.
    pub fn advance(self: *Clock, ticks: u32) void {
        const numerator = @as(u64, ticks) * self.cadence.units_per_tick * std.time.ns_per_s + self.remainder;
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
    /// deadlines keep the interrupt phase.
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
    var clock = try Clock.init(jungle, 100);
    clock.consume();
    try clock.restart(1_010_000_100);
    try std.testing.expect(clock.due(1_010_000_100));
    const tick = clock.next_tick;
    clock.consume();
    try std.testing.expectEqual(tick + 2, clock.next_tick);
    try std.testing.expect(!clock.due(1_010_000_100));
}

test "a frame is late once a tick has passed after its wait, and a restart drops the time lost" {
    var clock = try Clock.init(jungle, 0);
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
    var clock = try Clock.init(jungle, 50);
    try std.testing.expectEqual(@as(u64, 50), clock.deadline());
    clock.consume();
    try std.testing.expectEqual(@as(u64, 3), clock.next_tick);
    const deadline = clock.deadline();
    try std.testing.expect(!clock.due(deadline - 1));
    try std.testing.expect(clock.due(deadline));
    for (0..10000) |_| clock.consume();
    try std.testing.expectEqual(@as(u64, 20003), clock.next_tick);
    const expected: u64 = 50 + @as(
        u64,
        @intCast((@as(u128, 20003) * 17024 * std.time.ns_per_s + 1193181) / 1193182),
    );
    try std.testing.expectEqual(expected, clock.deadline());
    var invalid = jungle;
    invalid.units_per_second = 0;
    try std.testing.expectError(error.InvalidCadence, Clock.init(invalid, 0));
}
