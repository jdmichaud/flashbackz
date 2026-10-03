//! Rational deadlines for discrete simulation. Host presentation rate never sets movement
//! speed. The jungle development profile uses the observed display-counter cadence; full
//! original loading/late-frame scheduling is a separate acceptance gate.
const std = @import("std");

pub const Cadence = struct {
    units_per_second: u32,
    units_per_tick: u32,
    initial_gap_ticks: u32,
    regular_gap_ticks: u32,
};

pub const jungle: Cadence = .{ .units_per_second = 1193182, .units_per_tick = 17024, .initial_gap_ticks = 3, .regular_gap_ticks = 2 };

pub const Clock = struct {
    cadence: Cadence,
    origin_ns: u64,
    next_tick: u64 = 0,
    emitted: u64 = 0,
    elapsed_ns: u64 = 0,
    remainder: u64 = 0,

    pub fn init(cadence: Cadence, origin_ns: u64) !Clock {
        const largest_gap = @as(u64, cadence.units_per_tick) * @max(cadence.initial_gap_ticks, cadence.regular_gap_ticks);
        if (cadence.units_per_second == 0 or cadence.units_per_tick == 0 or cadence.initial_gap_ticks == 0 or cadence.regular_gap_ticks == 0 or
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
        const gap = if (self.emitted == 0) self.cadence.initial_gap_ticks else self.cadence.regular_gap_ticks;
        const numerator = @as(u64, gap) * self.cadence.units_per_tick * std.time.ns_per_s + self.remainder;
        self.elapsed_ns +|= numerator / self.cadence.units_per_second;
        self.remainder = numerator % self.cadence.units_per_second;
        self.next_tick += gap;
        self.emitted += 1;
    }
};

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
    const expected: u64 = 50 + @as(u64, @intCast((@as(u128, 20003) * 17024 * std.time.ns_per_s + 1193181) / 1193182));
    try std.testing.expectEqual(expected, clock.deadline());
    var invalid = jungle;
    invalid.units_per_second = 0;
    try std.testing.expectError(error.InvalidCadence, Clock.init(invalid, 0));
}
