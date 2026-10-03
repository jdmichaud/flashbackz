//! Conrad's observed wake-up and turning actions. Locomotion requests are explicit so an
//! incomplete movement system cannot quietly claim to have handled a forward command.
const std = @import("std");
const motion = @import("../motion.zig");

pub const Clips = struct {
    wake: motion.Clip,
    stand: motion.Clip,
    turn_preparation: motion.Clip,
    turn_follow_through: motion.Clip,
};

pub const TurnPhase = enum { preparation, follow_through };
pub const Activity = union(enum) { waking, standing, turning: TurnPhase };
pub const Intent = struct { direction: ?motion.Facing = null };
pub const Result = enum { advanced, locomotion_requested };

pub const Controller = struct {
    activity: Activity = .waking,
    playback: motion.Playback = .{},

    fn selectedClip(self: Controller, clips: Clips) motion.Clip {
        return switch (self.activity) {
            .waking => clips.wake,
            .standing => clips.stand,
            .turning => |phase| if (phase == .preparation) clips.turn_preparation else clips.turn_follow_through,
        };
    }

    /// One simulation step. A turn finishes its preparation, changes logical facing at
    /// the pivot, and completes its follow-through even if the key has been released.
    /// Combat and other interruptions will be coordinated by the owning actor systems.
    pub fn advance(self: *Controller, clips: Clips, intent: Intent, pose: *motion.Pose) !Result {
        var clip = self.selectedClip(clips);
        if (clip.steps.len == 0) return error.MissingMotion;
        if (self.playback.exhausted(clip)) {
            switch (self.activity) {
                .waking => self.activity = .standing,
                .standing => {
                    if (intent.direction) |direction| {
                        if (direction == pose.facing) return .locomotion_requested;
                        self.activity = .{ .turning = .preparation };
                    }
                },
                .turning => |phase| switch (phase) {
                    .preparation => {
                        pose.facing = if (pose.facing == .left) .right else .left;
                        self.activity = .{ .turning = .follow_through };
                    },
                    .follow_through => self.activity = .standing,
                },
            }
            self.playback = .{};
            clip = self.selectedClip(clips);
            if (clip.steps.len == 0) return error.MissingMotion;
        }
        _ = self.playback.advance(clip, pose);
        return .advanced;
    }
};

test "turn pivot changes facing between phases and release does not cancel follow-through" {
    const still = [_]motion.Step{.hold};
    const preparation = [_]motion.Step{ .hold, .hold };
    const follow = [_]motion.Step{ .hold, .hold, .hold };
    const clips: Clips = .{ .wake = .{ .steps = &still }, .stand = .{ .steps = &still }, .turn_preparation = .{ .steps = &preparation }, .turn_follow_through = .{ .steps = &follow } };
    var pose: motion.Pose = .{ .position = .{ .x = 32, .y = 70 }, .facing = .left, .visual = .{ .id = @fromBackingInt(7) } };
    var controller: Controller = .{};
    _ = try controller.advance(clips, .{}, &pose);
    _ = try controller.advance(clips, .{}, &pose);
    try std.testing.expectEqualDeep(@as(Activity, .standing), controller.activity);
    _ = try controller.advance(clips, .{ .direction = .right }, &pose);
    _ = try controller.advance(clips, .{}, &pose);
    try std.testing.expectEqual(.left, pose.facing);
    _ = try controller.advance(clips, .{}, &pose);
    try std.testing.expectEqual(.right, pose.facing);
    try std.testing.expectEqualDeep(Activity{ .turning = .follow_through }, controller.activity);
    _ = try controller.advance(clips, .{}, &pose);
    _ = try controller.advance(clips, .{}, &pose);
    _ = try controller.advance(clips, .{}, &pose);
    try std.testing.expectEqualDeep(@as(Activity, .standing), controller.activity);
    const previous = pose;
    try std.testing.expectEqual(.locomotion_requested, try controller.advance(clips, .{ .direction = .right }, &pose));
    try std.testing.expectEqualDeep(previous, pose);
}
