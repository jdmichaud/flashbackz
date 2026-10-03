//! Conrad's locomotion and gait boundaries. Motion clips own displacement; terrain
//! probes choose transitions, and room handoff occurs before the first frame of a new motion.
const std = @import("std");
const motion = @import("../motion.zig");
const jumping = @import("conrad_jump.zig");
const rolling = @import("conrad_roll.zig");
pub const Intent = @import("controls.zig").Intent;

pub const WalkMotion = struct {
    clip: motion.Clip,
    /// The torso occupies a different side of the contact anchor across gait phases.
    torso_clearance_ahead: i16 = 1,
};

pub const Clips = struct {
    wake: motion.Clip,
    stand: motion.Clip,
    turn_preparation: motion.Clip,
    turn_follow_through: motion.Clip,
    walk: ?struct { start: WalkMotion, strides: []const WalkMotion } = null,
    run: ?struct { start: motion.Clip, strides: []const motion.Clip, entry_stride: usize, brake: motion.Clip, settle: motion.Clip } = null,
    descend: ?struct { step_off: motion.Clip, land: motion.Clip } = null,
    jumps: ?jumping.Clips = null,
    crouch: ?struct { lower: motion.Clip, hold: motion.Clip, rise: motion.Clip, turn: motion.Clip } = null,
    roll: ?rolling.Clips = null,
};

pub const TurnPhase = enum { preparation, follow_through };
pub const GaitPhase = union(enum) { starting, stride: usize };
pub const Activity = union(enum) {
    waking,
    standing,
    turning: TurnPhase,
    walking: GaitPhase,
    running: GaitPhase,
    stopping_run: enum { braking, settling },
    stepping_down,
    landing,
    jumping: jumping.State,
    crouching: enum { lowering, holding, rising, turning },
    rolling: rolling.State,
};
pub const Result = enum { advanced, locomotion_requested, terrain_transition_requested };

const NoEnvironment = struct {
    pub fn at(_: @This(), _: motion.Pose, _: anytype, _: i16) !bool {
        return error.EnvironmentRequired;
    }
    pub fn motionBoundary(_: @This(), _: *motion.Pose) !void {}
    pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
        return error.EnvironmentRequired;
    }
};

pub const Controller = struct {
    activity: Activity = .waking,
    playback: motion.Playback = .{},

    fn selectedClip(self: Controller, clips: Clips) !motion.Clip {
        return switch (self.activity) {
            .waking => clips.wake,
            .standing => clips.stand,
            .turning => |phase| if (phase == .preparation) clips.turn_preparation else clips.turn_follow_through,
            .walking => |phase| blk: {
                const gait = clips.walk orelse return error.MissingMotion;
                break :blk switch (phase) {
                    .starting => gait.start.clip,
                    .stride => |i| if (i < gait.strides.len) gait.strides[i].clip else return error.InvalidGait,
                };
            },
            .running => |phase| blk: {
                const gait = clips.run orelse return error.MissingMotion;
                break :blk switch (phase) {
                    .starting => gait.start,
                    .stride => |i| if (i < gait.strides.len) gait.strides[i] else return error.InvalidGait,
                };
            },
            .stopping_run => |phase| blk: {
                const gait = clips.run orelse return error.MissingMotion;
                break :blk if (phase == .braking) gait.brake else gait.settle;
            },
            .stepping_down => (clips.descend orelse return error.MissingMotion).step_off,
            .landing => (clips.descend orelse return error.MissingMotion).land,
            .jumping => |jump| jump.clip(clips.jumps orelse return error.MissingMotion),
            .crouching => |phase| blk: {
                const crouch = clips.crouch orelse return error.MissingMotion;
                break :blk switch (phase) {
                    .lowering => crouch.lower,
                    .holding => crouch.hold,
                    .rising => crouch.rise,
                    .turning => crouch.turn,
                };
            },
            .rolling => |roll| roll.clip(clips.roll orelse return error.MissingMotion),
        };
    }

    /// One simulation step. Intent is reconsidered at motion boundaries; committed
    /// strides, turns and braking actions finish after their input has been released.
    /// Neutral action input is not consumed here: interactions and combat are resolved by
    /// the owning actor systems, which can start or interrupt a movement when appropriate.
    pub fn advance(self: *Controller, clips: Clips, intent: Intent, pose: *motion.Pose) !Result {
        return self.advanceIn(clips, intent, pose, NoEnvironment{});
    }

    pub fn advanceIn(self: *Controller, clips: Clips, intent: Intent, pose: *motion.Pose, environment: anytype) !Result {
        var clip = try self.selectedClip(clips);
        if (clip.steps.len == 0) return error.MissingMotion;
        if (self.playback.exhausted(clip)) {
            switch (self.activity) {
                .waking => self.activity = .standing,
                .standing => {
                    if (intent.vertical) |vertical| {
                        if (vertical == .up) {
                            if (!intent.action and try environment.ledge(pose.*, .head, 0, .ahead)) {
                                self.activity = .{ .turning = .preparation };
                            } else {
                                if (clips.jumps == null) return .locomotion_requested;
                                if (intent.action) {
                                    if (!try environment.at(pose.*, .torso, 1)) self.activity = .{ .jumping = .{ .kind = .forward } };
                                } else self.activity = .{ .jumping = .{ .kind = if (try environment.at(pose.*, .torso, 0)) .low_clearance else .upward } };
                            }
                        } else if (intent.action) {
                            if (try environment.ledge(pose.*, .support, 0, .ahead)) self.activity = .{ .turning = .preparation } else if (try environment.ledge(pose.*, .support, 0, .behind)) return .terrain_transition_requested;
                        } else if (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .torso, -1)) {
                            self.activity = .{ .turning = .preparation };
                        } else {
                            if (clips.crouch == null) return .locomotion_requested;
                            self.activity = .{ .crouching = .lowering };
                        }
                    } else if (intent.direction) |direction| {
                        if (direction != pose.facing) {
                            self.activity = .{ .turning = .preparation };
                        } else {
                            if (clips.walk == null or (intent.action and clips.run == null)) return .locomotion_requested;
                            if (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .torso, -1)) {
                                // Already touching the blocked side of a wall edge.
                            } else if (!try environment.at(pose.*, .support, 1)) {
                                if (intent.action or clips.descend == null) return .terrain_transition_requested;
                                self.activity = .stepping_down;
                            } else if (!try environment.at(pose.*, .torso, 0) or !try environment.at(pose.*, .torso, 1)) {
                                self.activity = if (intent.action) .{ .running = .starting } else .{ .walking = .starting };
                            }
                        }
                    }
                },
                .turning => |phase| switch (phase) {
                    .preparation => {
                        pose.facing = if (pose.facing == .left) .right else .left;
                        self.activity = .{ .turning = .follow_through };
                    },
                    .follow_through => self.activity = .standing,
                },
                .walking => |phase| {
                    const gait = clips.walk orelse return error.MissingMotion;
                    const clearance = switch (phase) {
                        .starting => gait.start.torso_clearance_ahead,
                        .stride => |i| gait.strides[i].torso_clearance_ahead,
                    };
                    if (!try environment.at(pose.*, .support, 1) or try environment.at(pose.*, .torso, clearance)) {
                        self.activity = .standing;
                    } else if (intent.direction == pose.facing) {
                        if (intent.action) return .locomotion_requested;
                        if (gait.strides.len == 0) return error.InvalidGait;
                        self.activity = .{ .walking = .{ .stride = switch (phase) {
                            .starting => 0,
                            .stride => |i| (i + 1) % gait.strides.len,
                        } } };
                    } else self.activity = .standing;
                },
                .running => |phase| {
                    const gait = clips.run orelse return error.MissingMotion;
                    if (intent.vertical != null) return .locomotion_requested;
                    if (!try environment.at(pose.*, .support, 1)) return .terrain_transition_requested;
                    if (try environment.at(pose.*, .torso, 3) and !try environment.at(pose.*, .torso, 2)) return .terrain_transition_requested;
                    if (phase == .starting and ((try environment.at(pose.*, .torso, 2) and !try environment.at(pose.*, .torso, 1)) or
                        (try environment.at(pose.*, .torso, 1) and !try environment.at(pose.*, .torso, 0)))) return .terrain_transition_requested;
                    const continue_running = if (phase == .starting) intent.action or intent.direction != null else intent.action and (intent.direction == null or intent.direction == pose.facing);
                    if (!continue_running) {
                        if (intent.direction != null) return .locomotion_requested;
                        if (!try environment.at(pose.*, .support, 2)) return .terrain_transition_requested;
                        self.activity = .{ .stopping_run = .braking };
                    } else {
                        if (gait.strides.len == 0 or gait.entry_stride >= gait.strides.len) return error.InvalidGait;
                        self.activity = .{ .running = .{ .stride = switch (phase) {
                            .starting => gait.entry_stride,
                            .stride => |i| (i + 1) % gait.strides.len,
                        } } };
                    }
                },
                .stopping_run => |phase| self.activity = if (phase == .braking) .{ .stopping_run = .settling } else .standing,
                .stepping_down => {
                    if (!try environment.at(pose.*, .support, 0)) return .terrain_transition_requested;
                    self.activity = .landing;
                },
                .landing => self.activity = .standing,
                .jumping => |*jump| switch (try jump.finishPhase(clips.jumps orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .finished => self.activity = .standing,
                    .terrain_requested => return .terrain_transition_requested,
                },
                .crouching => |phase| switch (phase) {
                    .lowering => self.activity = .{ .crouching = .holding },
                    .rising => self.activity = .standing,
                    .turning => {
                        pose.facing = if (pose.facing == .left) .right else .left;
                        self.activity = .{ .crouching = .holding };
                    },
                    .holding => {
                        if (intent.vertical == .down or (intent.vertical == null and intent.action and (intent.direction == null or intent.direction == pose.facing))) {
                            // Remain low while crouch/action is held.
                        } else if (intent.direction) |direction| {
                            if (direction == pose.facing) {
                                const roll = clips.roll orelse return .locomotion_requested;
                                if (!try environment.at(pose.*, .support, 1)) {
                                    self.activity = .{ .rolling = .{ .phase = .drop } };
                                } else if (!try environment.at(pose.*, .torso, 1)) {
                                    rolling.shiftForward(pose, roll.alignment_forward);
                                    self.activity = .{ .rolling = .{} };
                                } else self.activity = .{ .crouching = .rising };
                            } else if (!try environment.at(pose.*, .torso, -1)) self.activity = .{ .crouching = .turning } else self.activity = .{ .crouching = .rising };
                        } else self.activity = .{ .crouching = .rising };
                    },
                },
                .rolling => |*roll| switch (try roll.finishPhase(clips.roll orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .standing => self.activity = .standing,
                    .turning => self.activity = .{ .turning = .preparation },
                    .terrain_requested => return .terrain_transition_requested,
                    .action_requested => return .locomotion_requested,
                },
            }
            self.playback = .{};
            try environment.motionBoundary(pose);
            clip = try self.selectedClip(clips);
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

test "walking commits a stride and requests room handoff only at its boundary" {
    const still = [_]motion.Step{.hold};
    const moving = [_]motion.Step{
        .{ .frame = .{ .visual = .{ .id = @fromBackingInt(1) }, .forward = 4 } },
        .{ .frame = .{ .visual = .{ .id = @fromBackingInt(2) }, .forward = 4 } },
    };
    const strides = [_]WalkMotion{.{ .clip = .{ .steps = &moving } }};
    const clips: Clips = .{ .wake = .{ .steps = &still }, .stand = .{ .steps = &still }, .turn_preparation = .{ .steps = &still }, .turn_follow_through = .{ .steps = &still }, .walk = .{ .start = .{ .clip = .{ .steps = &moving } }, .strides = &strides } };
    const Ground = struct {
        boundaries: usize = 0,
        pub fn at(_: *@This(), _: motion.Pose, height: anytype, _: i16) !bool {
            return height == .support;
        }
        pub fn motionBoundary(self: *@This(), _: *motion.Pose) !void {
            self.boundaries += 1;
        }
        pub fn ledge(_: *@This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    var ground: Ground = .{};
    var pose: motion.Pose = .{ .position = .{ .x = 0, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
    var controller: Controller = .{ .activity = .standing, .playback = .{ .next_step = 1 } };
    _ = try controller.advanceIn(clips, .{ .direction = .right }, &pose, &ground);
    try std.testing.expectEqual(@as(i16, 4), pose.position.x);
    _ = try controller.advanceIn(clips, .{}, &pose, &ground);
    try std.testing.expectEqual(@as(i16, 8), pose.position.x);
    try std.testing.expectEqual(@as(usize, 1), ground.boundaries);
    _ = try controller.advanceIn(clips, .{}, &pose, &ground);
    try std.testing.expectEqualDeep(@as(Activity, .standing), controller.activity);
    try std.testing.expectEqual(@as(usize, 2), ground.boundaries);
}
