//! A committed low roll, including motion-boundary alignment and a one-tier drop.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const std = @import("std");

pub const Phase = enum {
    running_entry,
    running_recovery,
    jump_launch,
    enter,
    tumble,
    exit,
    balance,
    rise,
    drop,
    recover,
    upright_landing,
};
pub const Clips = struct {
    running_entry: ?motion.Clip = null,
    running_recovery: ?motion.Clip = null,
    jump_launch: ?motion.Clip = null,
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
    const clips: Clips = .{
        .enter = clip,
        .tumble = clip,
        .exit = clip,
        .balance = clip,
        .rise = clip,
        .drop = clip,
        .recover = clip,
        .upright_landing = clip,
    };
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
    var pose: motion.Pose = .{
        .position = .{ .x = 32, .y = 70 },
        .facing = .left,
        .visual = .{ .id = @fromBackingInt(0) },
    };
    var state: State = .{};
    for (0..2) |_| try std.testing.expectEqual(
        .continued,
        try state.finishPhase(clips, .{}, false, &pose, Ground{}),
    );
    try std.testing.expectEqual(@as(i16, 32), pose.position.x);
    try std.testing.expectEqual(
        .continued,
        try state.finishPhase(clips, .{}, false, &pose, Ground{}),
    );
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
    try std.testing.expectEqual(
        .continued,
        try state.finishPhase(clips, .{}, false, &pose, Ground{}),
    );
    try std.testing.expectEqual(
        .standing,
        try state.finishPhase(clips, .{}, false, &pose, Ground{}),
    );
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
}
pub const Boundary = enum {
    continued,
    standing,
    turning,
    wall_collision,
    catch_ledge,
    long_fall,
    armed_recovery,
    running,
    running_jump,
    jump_flight,
    running_drop,
    brake,
    wall_stop,
    stagger_stop,
};

pub fn shiftForward(pose: *motion.Pose, amount: i16) void {
    pose.position.x +%= if (pose.facing == .right) amount else -%amount;
}

pub const State = struct {
    phase: Phase = .enter,

    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .running_entry => clips.running_entry.?,
            .running_recovery => clips.running_recovery.?,
            .jump_launch => clips.jump_launch.?,
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

    fn wallAt(environment: anytype, pose: motion.Pose, ahead: i16) !bool {
        return try environment.at(pose, .torso, ahead) and
            !try environment.at(pose, .torso, ahead - 1);
    }

    pub fn finishPhase(
        self: *State,
        clips: Clips,
        intent: controls.Intent,
        weapon_desired: bool,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        switch (self.phase) {
            .running_entry => {
                const supported = try environment.at(pose.*, .support, 1);
                shiftForward(pose, clips.alignment_forward);
                self.phase = if (supported) .enter else .drop;
            },
            .running_recovery => {
                if (try wallAt(environment, pose.*, 0)) return .wall_collision;
                if (try wallAt(environment, pose.*, 1)) return .wall_stop;
                if (!try environment.at(pose.*, .support, 1) or
                    !try environment.at(pose.*, .support, 2))
                {
                    shiftForward(pose, clips.alignment_forward);
                    return .running_drop;
                }
                if (try wallAt(environment, pose.*, 3)) {
                    shiftForward(pose, clips.alignment_forward);
                    return .stagger_stop;
                }
                if (try wallAt(environment, pose.*, 2)) return .brake;
                if (intent.action and
                    (intent.direction == pose.facing or
                        intent.neutralDirections())) return .running;
                if (intent.action and intent.vertical == .down) {
                    self.phase = .running_entry;
                } else if (intent.action and intent.vertical == .up) {
                    shiftForward(pose, clips.alignment_forward);
                    return .running_jump;
                } else return .brake;
            },
            .jump_launch => {
                if (try wallAt(environment, pose.*, 1)) return .wall_collision;
                return .jump_flight;
            },
            .enter => {
                if (!try environment.at(pose.*, .torso, 0) and
                    !try environment.at(pose.*, .support, 1))
                {
                    self.phase = .drop;
                } else {
                    const passage = try environment.rollPassage(pose.*, 0) or
                        try environment.rollPassage(pose.*, 1);
                    if (!passage and try environment.at(pose.*, .torso, 1)) return .wall_collision;
                    self.phase = .tumble;
                }
            },
            .tumble => {
                if (try environment.rollPassage(pose.*, 1)) {
                    self.phase = .exit;
                    return .continued;
                }
                if (try environment.at(pose.*, .torso, 0) and
                    !try environment.at(pose.*, .torso, -1)) return .wall_collision;
                if (try environment.at(pose.*, .torso, 1) and
                    !try environment.at(pose.*, .torso, 0))
                {
                    shiftForward(pose, clips.alignment_forward);
                    self.phase = .balance;
                } else self.phase = if (try environment.at(pose.*, .support, 1)) .exit else .drop;
            },
            .exit => {
                if (!try environment.at(pose.*, .support, 1)) {
                    self.phase = .drop;
                } else if (try environment.rollPassage(pose.*, 0)) {
                    self.phase = .enter;
                } else if (try wallAt(environment, pose.*, 1) or (intent.action and intent.direction == pose.facing)) {
                    self.phase = .balance;
                } else if (weapon_desired) {
                    shiftForward(pose, clips.alignment_forward);
                    return .armed_recovery;
                } else {
                    self.phase = .balance;
                }
                shiftForward(pose, clips.alignment_forward);
            },
            .balance => {
                if (try wallAt(environment, pose.*, 0) or
                    try wallAt(environment, pose.*, 1) or
                    try wallAt(environment, pose.*, 2))
                {
                    self.phase = .rise;
                } else if (!try environment.at(pose.*, .support, 0)) {
                    self.phase = .drop;
                } else if (!try environment.at(pose.*, .support, 1) or !try environment.at(pose.*, .support, 2)) {
                    shiftForward(pose, clips.alignment_forward);
                    self.phase = .drop;
                } else {
                    const continues_run = intent.action and
                        !intent.directions_conflict and
                        (intent.direction == null or intent.direction == pose.facing);
                    self.phase = if (continues_run) .running_recovery else if (!intent.action and
                        intent.vertical == .up) .jump_launch else .rise;
                }
            },
            .rise => {
                if (!try environment.at(pose.*, .support, 0)) {
                    self.phase = .drop;
                    return .continued;
                }
                return if (intent.direction != null and
                    intent.direction != pose.facing) .turning else .standing;
            },
            .drop => {
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= 24;
                    return .catch_ledge;
                }
                if ((try environment.at(pose.*, .torso, 0) and
                    !try environment.at(pose.*, .support, -1)) or
                    !try environment.at(pose.*, .support, 0))
                {
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
