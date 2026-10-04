//! Cinematic presentation owns one imported film. A logical hold clock and presentation
//! cadence are independent of the host's refresh rate; no DOS program state is retained.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/vector_cinematic.zig");
const film = @import("../vector_film.zig");

const Cadence = struct {
    // English reference profile: calibrated hold ticks and the measured video cadence.
    const timer_numerator: u64 = 17_024 * std.time.ns_per_s;
    const timer_denominator: u64 = 1_193_182;
    const refresh_ns: u64 = 16_683_217;
    deadline_ns: u64 = 0,

    fn hold(self: *Cadence, ticks: u32) !void {
        if (ticks == 0) return;
        if (self.deadline_ns > 3600 * std.time.ns_per_s) return error.CinematicDurationTooLarge;
        const elapsed_ticks = self.deadline_ns * timer_denominator / timer_numerator;
        const target_tick = try std.math.add(u64, elapsed_ticks, ticks);
        const whole = target_tick / timer_denominator;
        const rest = target_tick % timer_denominator;
        const target_ns = try std.math.add(u64, try std.math.mul(u64, whole, timer_numerator), try std.math.divCeil(u64, try std.math.mul(u64, rest, timer_numerator), timer_denominator));
        self.deadline_ns = try std.math.mul(u64, target_ns / refresh_ns + 1, refresh_ns);
    }
};

pub const Player = struct {
    movie: content.OwnedFilm,
    playback: film.Playback,
    cadence: Cadence,
    origin_ns: ?u64 = null,

    pub fn open(allocator: std.mem.Allocator, source: platform.AssetSource, name: []const u8, entry: u16) !Player {
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
        if (self.needsCatchup(now_ns)) {
            if (try self.playback.advance(self.movie.view(), self.playback.next_tick)) {
                try self.cadence.hold(self.movie.frames[self.playback.frame].hold_ticks);
            }
        }
        return self.playback.finished;
    }
    pub fn needsCatchup(self: *const Player, now_ns: u64) bool {
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
