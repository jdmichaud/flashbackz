//! Ledge movement owns grip, pull-up and release motions. Alignment is expressed as
//! distance below the ledge; source animation/state identifiers remain in content import.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");

pub const Phase = enum { running_approach, running_reach, running_brace, lowering, catching, gripping, hanging, reaching, settling_grip, climbing, standing_up, releasing, dropping, turning_release, tumbling_release, bracing, braced_lowering };
pub const Clips = struct {
    running: ?struct { approach: motion.Clip, reach: motion.Clip, brace: motion.Clip } = null,
    lower: motion.Clip,
    catch_fall: motion.Clip,
    grip: motion.Clip,
    hang: motion.Clip,
    reach: motion.Clip,
    settle_grip: motion.Clip,
    climb: motion.Clip,
    stand: motion.Clip,
    release: motion.Clip,
    drop: motion.Clip,
    turn_release: motion.Clip,
    tumble_release: motion.Clip,
    brace: motion.Clip,
    braced_lower: motion.Clip,
    grip_depth: i16 = 48,
    extended_depth: i16 = 16,
    tier_height: i16 = 72,
    falling_entry_down: i16 = 48,
    long_fall_down: i16 = 56,
    drop_catch_down: i16 = 16,
    tumble_catch_up: i16 = 8,
    tumble_drop_down: i16 = 24,
};
pub const Boundary = enum { continued, standing, upright_landing, low_recovery, long_fall, waiting, armed_draw };
pub const State = struct {
    phase: Phase,

    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            .running_approach => clips.running.?.approach,
            .running_reach => clips.running.?.reach,
            .running_brace => clips.running.?.brace,
            .lowering => clips.lower,
            .catching => clips.catch_fall,
            .gripping => clips.grip,
            .hanging => clips.hang,
            .reaching => clips.reach,
            .settling_grip => clips.settle_grip,
            .climbing => clips.climb,
            .standing_up => clips.stand,
            .releasing => clips.release,
            .dropping => clips.drop,
            .turning_release => clips.turn_release,
            .tumbling_release => clips.tumble_release,
            .bracing => clips.brace,
            .braced_lowering => clips.braced_lower,
        };
    }
    fn climb(self: *State, pose: *motion.Pose, depth: i16) void {
        pose.position.y -%= depth;
        self.phase = .climbing;
    }
    fn release(self: *State, pose: *motion.Pose, clips: Clips, depth: i16) void {
        pose.position.y +%= clips.tier_height - depth;
        self.phase = .releasing;
    }
    fn fall(self: *State, pose: *motion.Pose, down: i16) void {
        pose.position.y +%= down;
        self.phase = .dropping;
    }
    fn reverse(pose: *motion.Pose) void {
        pose.facing = if (pose.facing == .left) .right else .left;
    }

    pub fn finishPhase(self: *State, clips: Clips, intent: controls.Intent, weapon_desired: bool, pose: *motion.Pose, environment: anytype) !Boundary {
        const up = intent.action and intent.vertical == .up;
        const down = intent.action and intent.vertical == .down;
        const backward = intent.action and intent.direction != null and intent.direction != pose.facing;
        const neutral = !intent.action and intent.direction == null and intent.vertical == null;
        switch (self.phase) {
            .running_approach => self.phase = if (try environment.at(pose.*, .torso, 3)) .running_brace else .running_reach,
            .running_reach => if (up) self.climb(pose, clips.extended_depth) else {
                self.phase = .settling_grip;
            },
            .running_brace => self.phase = .hanging,
            .lowering, .braced_lowering => if (intent.action) {
                pose.position.y +%= clips.grip_depth;
                self.phase = .gripping;
            } else self.release(pose, clips, 0),
            .catching => if (try environment.at(pose.*, .torso, 0)) {
                self.phase = .gripping;
            } else {
                pose.position.y -%= clips.grip_depth - clips.extended_depth;
                self.phase = .reaching;
            },
            .gripping => self.phase = .hanging,
            .hanging, .reaching => {
                const extended = self.phase == .reaching;
                const depth = if (extended) clips.extended_depth else clips.grip_depth;
                if (up) self.climb(pose, depth) else if (down and !try environment.at(pose.*, .support, -1)) {
                    pose.position.y +%= clips.grip_depth - depth;
                    self.phase = .tumbling_release;
                } else if (backward) {
                    pose.position.y +%= clips.grip_depth - depth;
                    self.phase = .turning_release;
                } else if (down or neutral or (!extended and !intent.action)) self.release(pose, clips, depth) else if (extended) self.phase = .settling_grip;
            },
            .settling_grip => if (up) self.climb(pose, clips.grip_depth) else if (neutral) self.release(pose, clips, clips.grip_depth) else {
                self.phase = .hanging;
            },
            .climbing => if (weapon_desired) return .armed_draw else {
                self.phase = .standing_up;
            },
            .standing_up => return .standing,
            .releasing => {
                if (!try environment.at(pose.*, .support, 0) or (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, -1))) self.fall(pose, clips.falling_entry_down) else if (down and try environment.ledge(pose.*, .support, 0, .behind)) {
                    self.phase = .bracing;
                } else return .upright_landing;
            },
            .dropping => {
                if (intent.action and try environment.ledge(pose.*, .support, 1, .behind)) {
                    pose.position.y +%= clips.drop_catch_down;
                    self.phase = .catching;
                } else if (!try environment.at(pose.*, .support, 0) or (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, -1))) {
                    pose.position.y +%= clips.long_fall_down;
                    return .long_fall;
                } else if ((try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .torso, -1)) or !try environment.at(pose.*, .support, 1)) return .upright_landing else return .low_recovery;
            },
            .turning_release => {
                const blocked = try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, -1);
                const supported = try environment.at(pose.*, .support, 0) and try environment.at(pose.*, .support, 1);
                const catches = if (!blocked and !supported and intent.action) try environment.ledge(pose.*, .support, -1, .ahead) else false;
                reverse(pose);
                if (blocked) self.fall(pose, clips.falling_entry_down) else if (supported) return .upright_landing else if (catches) {
                    pose.position.y +%= clips.drop_catch_down;
                    self.phase = .catching;
                } else self.fall(pose, clips.falling_entry_down);
            },
            .tumbling_release => {
                if (intent.action and try environment.ledge(pose.*, .head, 1, .behind)) {
                    pose.position.y -%= clips.tumble_catch_up;
                    self.phase = .catching;
                } else if (!try environment.at(pose.*, .head, 0)) self.fall(pose, clips.tumble_drop_down) else return .waiting;
            },
            .bracing => self.phase = .braced_lowering,
        }
        return .continued;
    }
};

test "grip depth aligns climbing and release to the same ledge across hang styles" {
    const std = @import("std");
    const held = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &held };
    const clips: Clips = .{ .lower = clip, .catch_fall = clip, .grip = clip, .hang = clip, .reach = clip, .settle_grip = clip, .climb = clip, .stand = clip, .release = clip, .drop = clip, .turn_release = clip, .tumble_release = clip, .brace = clip, .braced_lower = clip, .grip_depth = 60, .extended_depth = 20, .tier_height = 96 };
    const Ground = struct {
        pub fn at(_: @This(), _: motion.Pose, _: anytype, _: i16) !bool {
            return false;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    for ([_]Phase{ .hanging, .reaching }) |phase| for ([_]bool{ false, true }) |pull_up| {
        const depth = if (phase == .hanging) clips.grip_depth else clips.extended_depth;
        var pose: motion.Pose = .{ .position = .{ .x = 40, .y = 117 + depth }, .facing = .left, .visual = .{ .id = @fromBackingInt(1) } };
        var state: State = .{ .phase = phase };
        const intent: controls.Intent = if (pull_up) .{ .action = true, .vertical = .up } else .{};
        try std.testing.expectEqual(.continued, try state.finishPhase(clips, intent, false, &pose, Ground{}));
        try std.testing.expectEqual(@as(i16, if (pull_up) 117 else 213), pose.position.y);
        try std.testing.expectEqual(if (pull_up) Phase.climbing else .releasing, state.phase);
        try std.testing.expectEqual(@as(i16, 40), pose.position.x);
        try std.testing.expectEqual(motion.Facing.left, pose.facing);
    };
}
