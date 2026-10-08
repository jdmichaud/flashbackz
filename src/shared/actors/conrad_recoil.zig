//! Wall impact and recovery for a living Conrad. Root motion comes from content; contact
//! probes choose a confined fall, ground recovery, or a fall off the supporting platform.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");

pub const Landing = enum { confined, staggered, prone };
pub const Phase = union(enum) {
    impact,
    falling,
    dropping,
    settling: Landing,
    resting: Landing,
    rising,
};
pub const Recovery = struct { settle: motion.Clip, rest: motion.Clip };
pub const Clips = struct {
    impact: motion.Clip,
    fall: motion.Clip,
    drop: motion.Clip,
    confined: Recovery,
    staggered: Recovery,
    prone: Recovery,
    rise: motion.Clip,
    backward_shift: i16 = 16,
    lift: i16 = 16,
    drop_entry_down: i16 = 24,
    drop_landing_down: i16 = 16,
    long_fall_down: i16 = 72,

    fn recovery(self: Clips, landing: Landing) Recovery {
        return switch (landing) {
            .confined => self.confined,
            .staggered => self.staggered,
            .prone => self.prone,
        };
    }
};
pub const Boundary = enum {
    continued,
    standing,
    low_recovery,
    catch_ledge,
    long_fall,
    terrain_requested,
};

pub const State = struct {
    phase: Phase = .impact,

    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .impact => clips.impact,
            .falling => clips.fall,
            .dropping => clips.drop,
            .settling => |landing| clips.recovery(landing).settle,
            .resting => |landing| clips.recovery(landing).rest,
            .rising => clips.rise,
        };
    }

    pub fn finishPhase(
        self: *State,
        clips: Clips,
        intent: controls.Intent,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        switch (self.phase) {
            .impact => {
                const confined = try environment.at(pose.*, .torso, -1);
                pose.position.x +%= if (pose.facing == .right) -%clips.backward_shift else clips.backward_shift;
                pose.position.y -%= clips.lift;
                self.phase = if (confined) .{ .settling = .confined } else .falling;
            },
            .falling => {
                if (try environment.at(pose.*, .torso, 0)) {
                    self.phase = .{ .settling = .staggered };
                } else {
                    const ledge = try environment.ledge(pose.*, .support, 1, .behind);
                    if (intent.action and ledge) {
                        pose.position.y +%= 16;
                        return .catch_ledge;
                    }
                    if (ledge or !try environment.at(pose.*, .support, 1)) {
                        pose.position.y +%= clips.drop_entry_down;
                        self.phase = .dropping;
                    } else self.phase = .{ .settling = .prone };
                }
            },
            .dropping => {
                if (try environment.at(pose.*, .support, 0)) {
                    pose.position.y +%= clips.drop_landing_down;
                    return .low_recovery;
                }
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= 32;
                    return .catch_ledge;
                }
                pose.position.y +%= clips.long_fall_down;
                return .long_fall;
            },
            .settling => |landing| self.phase = .{ .resting = landing },
            .resting => self.phase = .rising,
            .rising => return .standing,
        }
        return .continued;
    }
};

test "impact retreats in physical facing once, then preserves the selected recovery" {
    const std = @import("std");
    const held = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &held };
    const recovery: Recovery = .{ .settle = clip, .rest = clip };
    const clips: Clips = .{
        .impact = clip,
        .fall = clip,
        .drop = clip,
        .confined = recovery,
        .staggered = recovery,
        .prone = recovery,
        .rise = clip,
    };
    const Ground = struct {
        confined: bool,
        pub fn at(self: @This(), _: motion.Pose, height: anytype, ahead: i16) !bool {
            return height == .support or (self.confined and height == .torso and ahead == -1);
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    for ([_]motion.Facing{ .left, .right }) |facing| for ([_]bool{ false, true }) |confined| {
        var pose: motion.Pose = .{
            .position = .{ .x = 100, .y = 70 },
            .facing = facing,
            .visual = .{ .id = @fromBackingInt(0) },
        };
        var state: State = .{};
        const ground: Ground = .{ .confined = confined };
        try std.testing.expectEqual(.continued, try state.finishPhase(clips, .{}, &pose, ground));
        try std.testing.expectEqual(@as(i16, if (facing == .right) 84 else 116), pose.position.x);
        try std.testing.expectEqual(@as(i16, 54), pose.position.y);
        if (!confined) _ = try state.finishPhase(clips, .{}, &pose, ground);
        try std.testing.expectEqual(
            if (confined) Landing.confined else .prone,
            state.phase.settling,
        );
        _ = try state.finishPhase(clips, .{}, &pose, ground);
        _ = try state.finishPhase(clips, .{}, &pose, ground);
        try std.testing.expectEqual(.standing, try state.finishPhase(clips, .{}, &pose, ground));
        try std.testing.expectEqual(@as(i16, if (facing == .right) 84 else 116), pose.position.x);
    };
}
