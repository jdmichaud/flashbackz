//! The committed running-jump arc and its landing decisions. Authored clips carry motion;
//! terrain decides whether Conrad catches a ledge, hits a wall or recovers into a run.
const std = @import("std");
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const shift = conrad_roll.shiftForward;
const conrad_roll = @import("conrad_roll.zig");
pub const Phase = enum {
    takeoff,
    ascending,
    crest,
    descending,
    landing,
    standing_recovery,
    running_recovery,
};
pub const Clips = struct {
    takeoff: motion.Clip,
    ascending: motion.Clip,
    crest: motion.Clip,
    descending: motion.Clip,
    landing: motion.Clip,
    standing_recovery: motion.Clip,
    running_recovery: motion.Clip,
    alignment: i16 = 16,
};
pub const Boundary = enum {
    continued,
    standing,
    resume_running,
    reverse_run,
    brake,
    wall_stop,
    settle_running,
    catch_ledge,
    wall_collision,
    gliding_drop,
    vertical_drop,
    unbalanced_drop,
};
pub const State = struct {
    phase: Phase = .takeoff,
    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .takeoff => clips.takeoff,
            .ascending => clips.ascending,
            .crest => clips.crest,
            .descending => clips.descending,
            .landing => clips.landing,
            .standing_recovery => clips.standing_recovery,
            .running_recovery => clips.running_recovery,
        };
    }
    fn wall(environment: anytype, pose: motion.Pose, ahead: i16) !bool {
        return try environment.at(pose, .torso, ahead) and
            !try environment.at(pose, .torso, ahead - 1);
    }
    pub fn finishPhase(
        self: *State,
        clips: Clips,
        intent: controls.Intent,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        switch (self.phase) {
            .takeoff => {
                shift(pose, clips.alignment);
                self.phase = .ascending;
            },
            .ascending => {
                if (try wall(environment, pose.*, -1)) {
                    shift(pose, -clips.alignment);
                    pose.position.y +%= 32;
                    return .wall_collision;
                }
                if (try wall(environment, pose.*, 0)) {
                    pose.position.y +%= 32;
                    return .wall_collision;
                }
                shift(pose, -clips.alignment);
                pose.position.y +%= 16;
                self.phase = .crest;
            },
            .crest => {
                if (try wall(environment, pose.*, 0)) {
                    pose.position.y +%= 16;
                    return .wall_collision;
                }
                if (try wall(environment, pose.*, 1)) {
                    shift(pose, clips.alignment);
                    pose.position.y +%= 16;
                    return .wall_collision;
                }
                self.phase = .descending;
            },
            .descending => {
                const collided = try wall(environment, pose.*, 1) or
                    try wall(environment, pose.*, 2);
                shift(pose, clips.alignment);
                if (collided) return .wall_collision;
                self.phase = .landing;
            },
            .landing => {
                if (intent.action and try environment.ledge(pose.*, .support, 2, .behind)) {
                    shift(pose, clips.alignment);
                    pose.position.y +%= 16;
                    return .catch_ledge;
                }
                if (try environment.ledge(pose.*, .support, 1, .ahead)) {
                    shift(pose, clips.alignment);
                    self.phase = .standing_recovery;
                } else if (!try environment.at(pose.*, .support, 1)) {
                    pose.position.y +%= 8;
                    return .gliding_drop;
                } else if (!try environment.at(pose.*, .support, 2)) {
                    pose.position.y +%= 8;
                    return .vertical_drop;
                } else if (try wall(environment, pose.*, 1) or try wall(environment, pose.*, 2)) {
                    shift(pose, clips.alignment);
                    self.phase = .standing_recovery;
                } else if (!try environment.at(pose.*, .support, 3)) {
                    return .settle_running;
                } else {
                    shift(pose, clips.alignment);
                    self.phase = if (intent.action and
                        !intent.directions_conflict and
                        intent.vertical != .down) .running_recovery else .standing_recovery;
                }
            },
            .standing_recovery => {
                if (!try environment.at(pose.*, .support, 0)) return .unbalanced_drop;
                return .standing;
            },
            .running_recovery => {
                if (try wall(environment, pose.*, 1)) return .wall_stop;
                if (try wall(environment, pose.*, 2) or
                    try wall(environment, pose.*, 3)) return .brake;
                if (intent.action and !intent.directions_conflict and intent.vertical != .down) {
                    if (intent.direction != null and
                        intent.direction != pose.facing) return .reverse_run;
                    return .resume_running;
                }
                return .brake;
            },
        }
        return .continued;
    }
};

test "running jump commits its arc after release and aligns the landing once" {
    const steps = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &steps };
    const clips: Clips = .{
        .takeoff = clip,
        .ascending = clip,
        .crest = clip,
        .descending = clip,
        .landing = clip,
        .standing_recovery = clip,
        .running_recovery = clip,
    };
    const Ground = struct {
        pub fn at(_: @This(), _: motion.Pose, height: anytype, _: i16) !bool {
            return height == .support;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    var state: State = .{};
    var pose: motion.Pose = .{
        .position = .{ .x = 40, .y = 54 },
        .facing = .right,
        .visual = .{ .id = @fromBackingInt(1) },
    };
    for (0..5) |_| try std.testing.expectEqual(
        .continued,
        try state.finishPhase(clips, .{}, &pose, Ground{}),
    );
    try std.testing.expectEqual(Phase.standing_recovery, state.phase);
    try std.testing.expectEqual(@as(i16, 72), pose.position.x);
    try std.testing.expectEqual(.standing, try state.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 72), pose.position.x);
}
