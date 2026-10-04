//! A committed low roll, including motion-boundary alignment and a one-tier drop.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const std = @import("std");

pub const Phase = enum { enter, tumble, exit, balance, rise, drop, recover, upright_landing };
pub const Clips = struct {
    enter: motion.Clip,
    tumble: motion.Clip,
    exit: motion.Clip,
    balance: motion.Clip,
    rise: motion.Clip,
    drop: motion.Clip,
    recover: motion.Clip,
    upright_landing: motion.Clip,
    alignment_forward: i16 = 16,
    landing_down: i16 = 8,
    long_fall_down: i16 = 64,
};

test "roll exit alignment is committed once before its recovery" {
    const hold = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &hold };
    const clips: Clips = .{ .enter = clip, .tumble = clip, .exit = clip, .balance = clip, .rise = clip, .drop = clip, .recover = clip, .upright_landing = clip };
    const Ground = struct {
        pub fn at(_: @This(), _: motion.Pose, height: anytype, _: i16) !bool {
            return height == .support;
        }
        pub fn rollPassage(_: @This(), _: motion.Pose, _: i16) !bool {
            return false;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    var pose: motion.Pose = .{ .position = .{ .x = 32, .y = 70 }, .facing = .left, .visual = .{ .id = @fromBackingInt(0) } };
    var state: State = .{};
    for (0..2) |_| try std.testing.expectEqual(.continued, try state.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 32), pose.position.x);
    try std.testing.expectEqual(.continued, try state.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
    try std.testing.expectEqual(.continued, try state.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(.standing, try state.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
}
pub const Boundary = enum { continued, standing, turning, wall_collision, catch_ledge, long_fall, terrain_requested, action_requested };

pub fn shiftForward(pose: *motion.Pose, amount: i16) void {
    pose.position.x +%= if (pose.facing == .right) amount else -%amount;
}

pub const State = struct {
    phase: Phase = .enter,

    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .enter => clips.enter,
            .tumble => clips.tumble,
            .exit => clips.exit,
            .balance => clips.balance,
            .rise => clips.rise,
            .drop => clips.drop,
            .recover => clips.recover,
            .upright_landing => clips.upright_landing,
        };
    }

    pub fn finishPhase(self: *State, clips: Clips, intent: controls.Intent, pose: *motion.Pose, environment: anytype) !Boundary {
        switch (self.phase) {
            .enter => {
                if (!try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, 1)) {
                    self.phase = .drop;
                } else {
                    const passage = try environment.rollPassage(pose.*, 0) or try environment.rollPassage(pose.*, 1);
                    if (!passage and try environment.at(pose.*, .torso, 1)) return .wall_collision;
                    self.phase = .tumble;
                }
            },
            .tumble => {
                if (try environment.rollPassage(pose.*, 1)) {
                    self.phase = .exit;
                    return .continued;
                }
                if (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .torso, -1)) return .wall_collision;
                if (try environment.at(pose.*, .torso, 1) and !try environment.at(pose.*, .torso, 0)) {
                    shiftForward(pose, clips.alignment_forward);
                    self.phase = .balance;
                } else self.phase = if (try environment.at(pose.*, .support, 1)) .exit else .drop;
            },
            .exit => {
                if (!try environment.at(pose.*, .support, 1)) {
                    self.phase = .drop;
                } else if (try environment.rollPassage(pose.*, 0)) {
                    self.phase = .enter;
                } else {
                    if (intent.vertical == .down) return .action_requested;
                    self.phase = .balance;
                }
                shiftForward(pose, clips.alignment_forward);
            },
            .balance => {
                if (!try environment.at(pose.*, .support, 0)) {
                    self.phase = .drop;
                } else if (!try environment.at(pose.*, .support, 1) or !try environment.at(pose.*, .support, 2)) {
                    shiftForward(pose, clips.alignment_forward);
                    self.phase = .drop;
                } else {
                    if ((intent.action and !intent.directions_conflict) or intent.vertical == .up) return .action_requested;
                    self.phase = .rise;
                }
            },
            .rise => {
                if (!try environment.at(pose.*, .support, 0)) {
                    self.phase = .drop;
                    return .continued;
                }
                return if (intent.direction != null and intent.direction != pose.facing) .turning else .standing;
            },
            .drop => {
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= 24;
                    return .catch_ledge;
                }
                if ((try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, -1)) or !try environment.at(pose.*, .support, 0)) {
                    pose.position.y +%= clips.long_fall_down;
                    return .long_fall;
                }
                self.phase = if (try environment.at(pose.*, .torso, 0) or try environment.ledge(pose.*, .support, 0, .ahead)) .upright_landing else .recover;
                pose.position.y +%= clips.landing_down;
            },
            .recover, .upright_landing => return .standing,
        }
        return .continued;
    }
};
