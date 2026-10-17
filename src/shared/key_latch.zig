//! The original's key latch on its modal screens (the title menu and its pages, the options
//! dialog, the inventory, films): a held direction registers again only when the keyboard
//! repeats it, no sooner than 20 timer ticks after the press and then every 12 (flashback-re
//! engine-presentation 6.1a). Other keys register once per press.
const std = @import("std");
const input = @import("input.zig");
const step_clock = @import("step_clock.zig");

/// One tick of the original's timer, in nanoseconds (rounded down).
const tick_ns = step_clock.tick_ns;

pub const DirectionRepeat = struct {
    /// When a repeated direction may register again.
    next_ns: u64 = 0,

    /// Whether a direction's key-down counts: a press always, a repeat once the delay since
    /// the last registration has run out.
    pub fn accept(self: *DirectionRepeat, repeat: bool, time_ns: u64) bool {
        if (!repeat) {
            self.next_ns = time_ns + 20 * tick_ns;
            return true;
        }
        if (time_ns < self.next_ns) return false;
        self.next_ns = time_ns + 12 * tick_ns;
        return true;
    }

    /// Whether a press registers: a direction as `accept` says, another key only when pressed,
    /// not when repeated.
    pub fn registers(self: *DirectionRepeat, press: input.Change, time_ns: u64) bool {
        return if (press.action.isDirection())
            self.accept(press.repeat, time_ns)
        else
            !press.repeat;
    }
};

test "a held direction repeats after 20 ticks, then every 12" {
    var repeat: DirectionRepeat = .{};
    try std.testing.expect(repeat.accept(false, 0));
    try std.testing.expect(!repeat.accept(true, 19 * tick_ns));
    try std.testing.expect(repeat.accept(true, 20 * tick_ns));
    try std.testing.expect(!repeat.accept(true, 31 * tick_ns));
    try std.testing.expect(repeat.accept(true, 32 * tick_ns));
    // A new press always registers.
    try std.testing.expect(repeat.accept(false, 33 * tick_ns));
    // A direction already held when the screen opened registers on its first repeat.
    var fresh: DirectionRepeat = .{};
    try std.testing.expect(fresh.accept(true, 5 * tick_ns));
    // Other keys register once per press.
    try std.testing.expect(fresh.registers(.{ .action = .use, .down = true }, 6 * tick_ns));
    try std.testing.expect(
        !fresh.registers(.{ .action = .use, .down = true, .repeat = true }, 600 * tick_ns),
    );
}
