//! First-tier descents preserve how Conrad left the platform. Motion clips supply the
//! visible drop; support and ledge queries choose a landing, a catch or a longer fall.
const std = @import("std");
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const shift = conrad_roll.shiftForward;
const conrad_roll = @import("conrad_roll.zig");
pub const Phase = enum { running, reversing, unbalanced, short_jump, gliding, vertical };
pub const Clips = struct {
    running: motion.Clip,
    reversing: motion.Clip,
    unbalanced: motion.Clip,
    short_jump: motion.Clip,
    gliding: motion.Clip,
    vertical: motion.Clip,
};
pub const Boundary = enum {
    continued,
    landing,
    low_landing,
    armed_landing,
    long_fall,
    catch_ledge,
};
pub const State = struct {
    phase: Phase,
    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .running => clips.running,
            .reversing => clips.reversing,
            .unbalanced => clips.unbalanced,
            .short_jump => clips.short_jump,
            .gliding => clips.gliding,
            .vertical => clips.vertical,
        };
    }
    pub fn finishPhase(
        self: *State,
        intent: controls.Intent,
        weapon_desired: bool,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        switch (self.phase) {
            .unbalanced => {
                if (try environment.at(pose.*, .support, 0)) return .landing;
                pose.position.y +%= 56;
                return .long_fall;
            },
            .running => {
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= 16;
                    return .catch_ledge;
                }
                if (!try environment.at(pose.*, .support, 0)) {
                    pose.position.y +%= 56;
                    return .long_fall;
                }
                if (try environment.at(pose.*, .torso, 0) or
                    try environment.ledge(pose.*, .support, 0, .ahead)) return .landing;
                return .low_landing;
            },
            .reversing => {
                const supported = try environment.at(pose.*, .support, 0);
                const upright = supported and try environment.ledge(pose.*, .support, 0, .behind);
                const catchable = !supported and
                    intent.action and
                    try environment.ledge(pose.*, .support, -1, .ahead);
                pose.facing = if (pose.facing == .left) .right else .left;
                if (supported) return if (upright) .landing else .low_landing;
                if (catchable) {
                    pose.position.y +%= 16;
                    return .catch_ledge;
                }
                pose.position.y +%= 56;
                return .long_fall;
            },
            .short_jump => {
                const vertical = (try environment.at(pose.*, .torso, 1) and
                    !try environment.at(pose.*, .support, 0)) or
                    try environment.at(pose.*, .support, 2);
                shift(pose, 4);
                pose.position.y +%= 8;
                self.phase = if (vertical) .vertical else .gliding;
                return .continued;
            },
            .gliding, .vertical => {
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= 32;
                    return .catch_ledge;
                }
                if (self.phase == .gliding and try environment.ledge(pose.*, .support, 0, .ahead)) {
                    pose.position.y +%= 16;
                    return .landing;
                }
                const supported = try environment.at(pose.*, .support, 0);
                const torso = try environment.at(pose.*, .torso, 0);
                if ((self.phase == .gliding and !supported) or
                    (torso and !try environment.at(pose.*, .support, -1)))
                {
                    pose.position.y +%= 72;
                    return .long_fall;
                }
                if (torso and try environment.at(
                    pose.*,
                    .support,
                    if (self.phase == .vertical) @as(i16, -1) else 0,
                )) {
                    pose.position.y +%= 16;
                    return .landing;
                }
                if (self.phase == .vertical and !supported) {
                    pose.position.y +%= 72;
                    return .long_fall;
                }
                pose.position.y +%= 16;
                return if (self.phase == .gliding and
                    weapon_desired) .armed_landing else .low_landing;
            },
        }
    }
};

test "running off an edge prioritizes a held ledge catch over continuing the fall" {
    const Void = struct {
        pub fn at(_: @This(), _: motion.Pose, _: anytype, _: i16) !bool {
            return false;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, ahead: i16, side: anytype) !bool {
            return ahead == 1 and side == .behind;
        }
    };
    var state: State = .{ .phase = .running };
    var caught: motion.Pose = .{
        .position = .{ .x = 96, .y = 142 },
        .visual = .{ .id = @fromBackingInt(0) },
    };
    var released = caught;
    try std.testing.expectEqual(
        .catch_ledge,
        try state.finishPhase(.{ .action = true }, false, &caught, Void{}),
    );
    try std.testing.expectEqual(.long_fall, try state.finishPhase(.{}, false, &released, Void{}));
    try std.testing.expectEqual(@as(i16, 158), caught.position.y);
    try std.testing.expectEqual(@as(i16, 198), released.position.y);
}
