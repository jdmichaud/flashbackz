//! Discrete motion clips. A simulation step advances artwork and displacement together;
//! behaviors choose clips and transitions, while the renderer resolves opaque visual IDs.
const std = @import("std");
const combat = @import("combat.zig");

pub const SoundId = enum(u16) { _ };
pub const VisualId = enum(u32) { _ };
pub const Facing = enum { right, left };
pub const Position = struct { x: i16, y: i16 };
pub const Visual = struct { id: VisualId, mirrored: bool = false };
pub const Pose = struct { position: Position, facing: Facing = .right, visual: Visual };

pub const Step = union(enum) {
    hold,
    frame: struct { visual: Visual, forward: i16 = 0, down: i16 = 0 },
};

pub const Clip = struct { hit_profile: ?combat.ProfileId = null, steps: []const Step, presses_floor_switches: bool = false, ordinary_contact: bool = false, sound: ?SoundId = null, disturbs_surface: bool = false };

pub const Playback = struct {
    next_step: usize = 0,

    pub fn soundOnEntry(self: Playback, clip: Clip) ?SoundId {
        return if (self.next_step == 0) clip.sound else null;
    }

    pub fn exhausted(self: Playback, clip: Clip) bool {
        return self.next_step >= clip.steps.len;
    }

    fn displace(pose: *Pose, forward: i16, down: i16) void {
        const displacement: i32 = if (pose.facing == .left) -@as(i32, forward) else forward;
        pose.position.x = @truncate(@as(i32, pose.position.x) + displacement);
        pose.position.y +%= down;
    }

    /// An accepted interruption completes the current motion's displacement before the
    /// reaction evaluates terrain. Unpresented frames change neither artwork nor sound.
    pub fn completeDisplacement(self: *Playback, clip: Clip, pose: *Pose) void {
        while (!self.exhausted(clip)) : (self.next_step += 1) switch (clip.steps[self.next_step]) {
            .hold => {},
            .frame => |frame| displace(pose, frame.forward, frame.down),
        };
    }

    /// The caller handles an exhausted clip before choosing the next step. End-of-clip
    /// never reads neighboring content or silently starts an unrelated movement.
    pub fn advance(self: *Playback, clip: Clip, pose: *Pose) enum { advanced, exhausted } {
        if (self.exhausted(clip)) return .exhausted;
        switch (clip.steps[self.next_step]) {
            .hold => {},
            .frame => |frame| {
                displace(pose, frame.forward, frame.down);
                pose.visual = .{
                    .id = frame.visual.id,
                    .mirrored = frame.visual.mirrored != (pose.facing == .left),
                };
            },
        }
        self.next_step += 1;
        return .advanced;
    }
};

test "interruption completes only remaining displacement without presenting skipped frames" {
    const frames = [_]Step{
        .{ .frame = .{ .visual = .{ .id = @fromBackingInt(8) }, .forward = 7, .down = -16 } },
        .hold,
        .{ .frame = .{ .visual = .{ .id = @fromBackingInt(9) }, .forward = 5, .down = 16 } },
    };
    const clip: Clip = .{ .steps = &frames, .sound = @fromBackingInt(3) };
    var pose: Pose = .{
        .position = .{ .x = 100, .y = 70 },
        .facing = .left,
        .visual = .{ .id = @fromBackingInt(0) },
    };
    var playback: Playback = .{};
    _ = playback.advance(clip, &pose);
    const visible = pose.visual;
    playback.completeDisplacement(clip, &pose);
    try std.testing.expectEqualDeep(Position{ .x = 88, .y = 70 }, pose.position);
    try std.testing.expectEqualDeep(visible, pose.visual);
    try std.testing.expect(playback.exhausted(clip));
    try std.testing.expect(playback.soundOnEntry(clip) == null);
    const completed = pose;
    playback.completeDisplacement(clip, &pose);
    try std.testing.expectEqualDeep(completed, pose);
}

test "motion holds preserve the pose and clip completion is explicit" {
    const old_visual: VisualId = @fromBackingInt(7);
    const new_visual: VisualId = @fromBackingInt(9);
    const steps = [_]Step{
        .hold,
        .{ .frame = .{ .visual = .{ .id = new_visual }, .forward = 3, .down = -2 } },
    };
    const clip: Clip = .{ .steps = &steps };
    var pose: Pose = .{ .position = .{ .x = 100, .y = 60 }, .visual = .{ .id = old_visual } };
    var playback: Playback = .{};
    const initial = pose;
    try std.testing.expectEqual(.advanced, playback.advance(clip, &pose));
    try std.testing.expectEqualDeep(initial, pose);
    try std.testing.expectEqual(.advanced, playback.advance(clip, &pose));
    try std.testing.expectEqual(Position{ .x = 103, .y = 58 }, pose.position);
    try std.testing.expectEqual(new_visual, pose.visual.id);
    try std.testing.expect(playback.exhausted(clip));
    const completed = pose;
    try std.testing.expectEqual(.exhausted, playback.advance(clip, &pose));
    try std.testing.expectEqualDeep(completed, pose);
}

test "facing reflects displacement and artwork with explicit signed wrapping" {
    const steps = [_]Step{.{ .frame = .{
        .visual = .{ .id = @fromBackingInt(1), .mirrored = true },
        .forward = -128,
        .down = 1,
    } }};
    var pose: Pose = .{
        .position = .{ .x = 32760, .y = 32767 },
        .facing = .left,
        .visual = .{ .id = @fromBackingInt(0) },
    };
    var playback: Playback = .{};
    _ = playback.advance(.{ .steps = &steps }, &pose);
    try std.testing.expectEqual(Position{ .x = -32648, .y = -32768 }, pose.position);
    try std.testing.expect(!pose.visual.mirrored);
}
