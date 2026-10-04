//! Committed jump phases. Motion clips provide the visible arc; terrain probes determine
//! whether the next phase is a landing, ledge interaction or an uncovered transition.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const std = @import("std");

pub const VerticalClips = struct { rise: motion.Clip, recover: motion.Clip };
pub const ForwardClips = struct { takeoff: motion.Clip, flight: motion.Clip, landing: motion.Clip, recover: motion.Clip, landing_forward_shift: i16 = 16 };
pub const Clips = struct { upward: VerticalClips, low_clearance: VerticalClips, forward: ForwardClips, ledge_height: i16 = 72, grip_lift: i16 = 24 };
pub const Kind = enum { upward, low_clearance, forward };
pub const Phase = enum { takeoff, flight, landing, recovery };
pub const Boundary = enum { continued, finished, wall_collision, climb_ledge, grip_ledge, terrain_requested };

pub const State = struct {
    kind: Kind,
    phase: Phase = .takeoff,

    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.kind) {
            .upward, .low_clearance => blk: {
                const selected = if (self.kind == .upward) clips.upward else clips.low_clearance;
                break :blk if (self.phase == .takeoff) selected.rise else selected.recover;
            },
            .forward => switch (self.phase) {
                .takeoff => clips.forward.takeoff,
                .flight => clips.forward.flight,
                .landing => clips.forward.landing,
                .recovery => clips.forward.recover,
            },
        };
    }

    pub fn finishPhase(self: *State, clips: Clips, intent: controls.Intent, pose: *motion.Pose, environment: anytype) !Boundary {
        if (self.kind != .forward) {
            if (self.phase == .recovery) return .finished;
            if (try environment.ledge(pose.*, .head, 0, .behind)) {
                if (intent.vertical == .up) {
                    pose.position.y -%= clips.ledge_height;
                    return .climb_ledge;
                }
                if (intent.action) {
                    pose.position.y -%= clips.grip_lift;
                    return .grip_ledge;
                }
            }
            self.phase = .recovery;
            return .continued;
        }
        switch (self.phase) {
            .takeoff, .flight => {
                if (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .torso, -1)) return .wall_collision;
                if (try environment.at(pose.*, .torso, 1) and !try environment.at(pose.*, .torso, 0)) {
                    const shift = clips.forward.landing_forward_shift;
                    pose.position.x +%= if (pose.facing == .right) shift else -%shift;
                    return .wall_collision;
                }
                if (self.phase == .takeoff) {
                    self.phase = .flight;
                } else {
                    if (!try environment.at(pose.*, .support, 2)) return .terrain_requested;
                    self.phase = .landing;
                    const shift = clips.forward.landing_forward_shift;
                    pose.position.x +%= if (pose.facing == .right) shift else -%shift;
                }
            },
            .landing => self.phase = .recovery,
            .recovery => return .finished,
        }
        return .continued;
    }
};

test "forward jump phases apply the landing alignment once in physical facing" {
    const still = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &still };
    const clips: Clips = .{ .upward = .{ .rise = clip, .recover = clip }, .low_clearance = .{ .rise = clip, .recover = clip }, .forward = .{ .takeoff = clip, .flight = clip, .landing = clip, .recover = clip } };
    const Ground = struct {
        pub fn at(_: @This(), _: motion.Pose, height: anytype, _: i16) !bool {
            return height == .support;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    var pose: motion.Pose = .{ .position = .{ .x = 32, .y = 70 }, .facing = .left, .visual = .{ .id = @fromBackingInt(1) } };
    var jump: State = .{ .kind = .forward };
    try std.testing.expectEqual(.continued, try jump.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 32), pose.position.x);
    try std.testing.expectEqual(.continued, try jump.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
    try std.testing.expectEqual(.continued, try jump.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(.finished, try jump.finishPhase(clips, .{}, &pose, Ground{}));
    try std.testing.expectEqual(@as(i16, 16), pose.position.x);
}
