//! Conrad's locomotion and gait boundaries. Motion clips own displacement; terrain
//! probes choose transitions, and room handoff occurs before the first frame of a new motion.
const std = @import("std");
const motion = @import("../motion.zig");
pub const armed = @import("conrad_armed.zig");
const descent = @import("conrad_descent.zig");
const running_jump = @import("conrad_running_jump.zig");
const jumping = @import("conrad_jump.zig");
const ledge = @import("conrad_ledge.zig");
const falling = @import("conrad_fall.zig");
const recoil = @import("conrad_recoil.zig");
const rolling = @import("conrad_roll.zig");
pub const Intent = @import("controls.zig").Intent;

pub const WalkMotion = struct {
    clip: motion.Clip,
    /// The torso occupies a different side of the contact anchor across gait phases.
    torso_clearance_ahead: i16 = 1,
};

pub const RunClips = struct {
    start: motion.Clip,
    strides: []const motion.Clip,
    entry_stride: usize,
    brake: motion.Clip,
    settle: motion.Clip,
    wall_stop: ?motion.Clip = null,
    stagger_stop: ?motion.Clip = null,
    accelerate: ?motion.Clip = null,
    walk_out: ?motion.Clip = null,
    edge_stop: ?motion.Clip = null,
    reverse: ?struct { brake: motion.Clip, follow_through: motion.Clip } = null,
};

pub const Clips = struct {
    armed: ?armed.Clips = null,
    wake: motion.Clip,
    use_item: ?motion.Clip = null,
    throw_item: ?motion.Clip = null,
    operate: ?struct { reach: motion.Clip, press: motion.Clip, recover: motion.Clip } = null,
    stand: motion.Clip,
    turn_preparation: motion.Clip,
    turn_follow_through: motion.Clip,
    walk: ?struct { start: WalkMotion, strides: []const WalkMotion } = null,
    run: ?RunClips = null,
    descend: ?struct { step_off: motion.Clip, land: motion.Clip } = null,
    jumps: ?jumping.Clips = null,
    running_jump: ?running_jump.Clips = null,
    descent: ?descent.Clips = null,
    low_landing: ?motion.Clip = null,
    crouch: ?struct { lower: motion.Clip, hold: motion.Clip, rise: motion.Clip, turn: motion.Clip } = null,
    roll: ?rolling.Clips = null,
    recoil: ?recoil.Clips = null,
    fall: ?falling.Clips = null,
    ledge: ?ledge.Clips = null,
    walking_fall_down: i16 = 56,
};

pub const TurnPhase = enum { preparation, follow_through };
pub const GaitPhase = union(enum) { starting, stride: usize };
pub const Activity = union(enum) {
    armed: armed.State,
    waking,
    standing,
    using_item,
    throwing_item,
    operating: enum { reaching, pressing, recovering },
    turning: TurnPhase,
    walking: GaitPhase,
    running: GaitPhase,
    stopping_run: enum { braking, settling, edge, wall, staggered },
    changing_pace: enum { accelerating, slowing },
    reversing_run: enum { braking, follow_through },
    stepping_down,
    landing,
    jumping: jumping.State,
    running_jump: running_jump.State,
    descending: descent.State,
    low_landing,
    crouching: enum { lowering, holding, rising, turning },
    rolling: rolling.State,
    recoiling: recoil.State,
    falling: falling.State,
    ledge: ledge.State,
    dead: enum { landing, resting },
};
pub const Result = enum { advanced, locomotion_requested, terrain_transition_requested };

const NoEnvironment = struct {
    pub fn at(_: @This(), _: motion.Pose, _: anytype, _: i16) !bool {
        return error.EnvironmentRequired;
    }
    pub fn motionBoundary(_: @This(), _: *motion.Pose) !void {}
    pub fn rollPassage(_: @This(), _: motion.Pose, _: i16) !bool {
        return false;
    }

    pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
        return error.EnvironmentRequired;
    }
};

pub const Controller = struct {
    activity: Activity = .waking,
    weapon_desired: bool = false,
    sound_requested: ?motion.SoundId = null,
    shot_requested: ?@import("../pistol_shot.zig").Height = null,
    playback: motion.Playback = .{},
    /// Ordered consequences of the latest step; the session applies them before equipment.
    fatal_landing: bool = false,
    death_wait_requested: ?u16 = null,
    pickup_requested: bool = false,
    use_requested: bool = false,
    use_available: bool = false,
    throw_available: bool = false,
    pickup_available: bool = false,
    control_available: bool = false,
    operate_requested: bool = false,

    fn wallAt(environment: anytype, pose: motion.Pose, ahead: i16) !bool {
        return try environment.at(pose, .torso, ahead) and !try environment.at(pose, .torso, ahead - 1);
    }

    fn selectedClip(self: Controller, clips: Clips) !motion.Clip {
        return switch (self.activity) {
            .armed => |state| state.clip(clips.armed orelse return error.MissingMotion),
            .waking => clips.wake,
            .standing => clips.stand,
            .using_item => clips.use_item orelse return error.MissingMotion,
            .throwing_item => clips.throw_item orelse return error.MissingMotion,
            .operating => |phase| blk: {
                const action = clips.operate orelse return error.MissingMotion;
                break :blk switch (phase) {
                    .reaching => action.reach,
                    .pressing => action.press,
                    .recovering => action.recover,
                };
            },
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
                break :blk switch (phase) {
                    .braking => gait.brake,
                    .settling => gait.settle,
                    .edge => gait.edge_stop orelse return error.MissingMotion,
                    .wall => gait.wall_stop orelse return error.MissingMotion,
                    .staggered => gait.stagger_stop orelse return error.MissingMotion,
                };
            },
            .reversing_run => |phase| blk: {
                const reversal = (clips.run orelse return error.MissingMotion).reverse orelse return error.MissingMotion;
                break :blk if (phase == .braking) reversal.brake else reversal.follow_through;
            },
            .changing_pace => |phase| blk: {
                const gait = clips.run orelse return error.MissingMotion;
                break :blk (if (phase == .accelerating) gait.accelerate else gait.walk_out) orelse return error.MissingMotion;
            },
            .stepping_down => (clips.descend orelse return error.MissingMotion).step_off,
            .landing => (clips.descend orelse return error.MissingMotion).land,
            .low_landing => clips.low_landing orelse return error.MissingMotion,
            .descending => |drop| drop.clip(clips.descent orelse return error.MissingMotion),
            .running_jump => |jump| jump.clip(clips.running_jump orelse return error.MissingMotion),
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
            .recoiling => |state| state.clip(clips.recoil orelse return error.MissingMotion),
            .falling => |state| state.clip(clips.fall orelse return error.MissingMotion),
            .ledge => |state| state.clip(clips.ledge orelse return error.MissingMotion),
            .dead => |phase| if (phase == .landing) (clips.fall orelse return error.MissingMotion).landing else (clips.fall orelse return error.MissingMotion).resting,
        };
    }

    pub fn disturbsSurface(self: Controller, clips: Clips) !bool {
        return (try self.selectedClip(clips)).disturbs_surface;
    }

    pub fn pressesFloorSwitches(self: Controller, clips: Clips) !bool {
        return (try self.selectedClip(clips)).presses_floor_switches;
    }

    /// One simulation step. Intent is reconsidered at motion boundaries; committed
    /// strides, turns and braking actions finish after their input has been released.
    /// Neutral action input is not consumed here: interactions and combat are resolved by
    /// the owning actor systems, which can start or interrupt a movement when appropriate.
    pub fn advance(self: *Controller, clips: Clips, intent: Intent, pose: *motion.Pose) !Result {
        return self.advanceIn(clips, intent, pose, NoEnvironment{});
    }

    pub fn advanceIn(self: *Controller, clips: Clips, intent: Intent, pose: *motion.Pose, environment: anytype) !Result {
        self.shot_requested = null;
        self.sound_requested = null;
        self.pickup_requested = false;
        self.operate_requested = false;
        self.use_requested = false;
        self.fatal_landing = false;
        self.death_wait_requested = null;
        var clip = try self.selectedClip(clips);
        if (clip.steps.len == 0) return error.MissingMotion;
        if (self.playback.exhausted(clip)) {
            switch (self.activity) {
                .armed => |*state| switch (try state.finishPhase(intent, self.weapon_desired, pose, environment)) {
                    .continued => {},
                    .unarmed_standing => self.activity = .standing,
                    .unarmed_crouched => self.activity = .{ .crouching = .holding },
                    .unarmed_rising => self.activity = .{ .crouching = .rising },
                    .roll => self.activity = .{ .rolling = .{} },
                    .roll_drop => self.activity = .{ .rolling = .{ .phase = .drop } },
                    .long_fall => self.activity = .{ .falling = .{ .phase = .continuing } },
                    .fire_standing => self.shot_requested = .standing,
                    .fire_crouched => self.shot_requested = .crouched,
                },
                .operating => |phase| switch (phase) {
                    .reaching => self.activity = .{ .operating = .pressing },
                    .pressing => {
                        self.operate_requested = self.control_available and intent.action and intent.neutralDirections() and !intent.weapon and !intent.use_item;
                        self.activity = .{ .operating = .recovering };
                    },
                    .recovering => self.activity = .standing,
                },
                .waking => self.activity = .standing,
                .using_item => {
                    self.use_requested = self.use_available and intent.use_item and !intent.action and !intent.weapon and intent.neutralDirections();
                    self.activity = if (self.use_requested and self.throw_available) .throwing_item else .standing;
                },
                .throwing_item => self.activity = .standing,
                .standing => {
                    if (clips.descent != null and !try environment.at(pose.*, .support, 0)) {
                        self.activity = .{ .descending = .{ .phase = .unbalanced } };
                    } else if (self.weapon_desired) {
                        self.activity = .{ .armed = .{} };
                    } else if (self.use_available and intent.use_item and !intent.action and !intent.weapon and intent.neutralDirections()) {
                        self.activity = .using_item;
                    } else if (self.pickup_available and intent.action and intent.neutralDirections()) {
                        self.activity = .{ .crouching = .lowering };
                    } else if (self.control_available and intent.action and intent.neutralDirections() and !intent.weapon and !intent.use_item) {
                        self.activity = .{ .operating = .reaching };
                    } else if (intent.vertical) |vertical| {
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
                            if (try environment.ledge(pose.*, .support, 0, .ahead)) self.activity = .{ .turning = .preparation } else if (try environment.ledge(pose.*, .support, 0, .behind)) self.activity = .{ .ledge = .{ .phase = .lowering } };
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
                                if (clips.descend == null) return .terrain_transition_requested;
                                self.activity = .stepping_down;
                            } else if (!try environment.at(pose.*, .torso, 0) or !try environment.at(pose.*, .torso, 1)) {
                                self.activity = if (intent.action and !try wallAt(environment, pose.*, 1)) .{ .running = .starting } else .{ .walking = .starting };
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
                        if (intent.action) {
                            if (!try environment.at(pose.*, .torso, 1)) self.activity = .{ .changing_pace = .accelerating } else self.activity = .standing;
                        } else {
                            if (gait.strides.len == 0) return error.InvalidGait;
                            self.activity = .{ .walking = .{ .stride = switch (phase) {
                                .starting => 0,
                                .stride => |i| (i + 1) % gait.strides.len,
                            } } };
                        }
                    } else self.activity = .standing;
                },
                .running => |phase| {
                    const gait = clips.run orelse return error.MissingMotion;

                    const backward = intent.direction != null and intent.direction != pose.facing;
                    if (phase == .stride and phase.stride == 0 and intent.action and backward and try environment.at(pose.*, .torso, 2)) {
                        self.activity = .{ .stopping_run = .braking };
                    } else if (!try environment.at(pose.*, .support, 1) or (phase != .starting and intent.action and intent.vertical == .down and !try environment.at(pose.*, .support, 2))) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .descending = .{ .phase = .running } };
                    } else if (phase == .starting and try wallAt(environment, pose.*, 1)) {
                        self.activity = .{ .stopping_run = .wall };
                    } else if (phase == .starting and (try wallAt(environment, pose.*, 2) or try wallAt(environment, pose.*, 3))) {
                        self.activity = .{ .stopping_run = .braking };
                    } else if (phase != .starting and intent.action and intent.vertical == .up and !try environment.ledge(pose.*, .support, 2, .ahead)) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .running_jump = .{} };
                    } else if (phase != .starting and intent.action and intent.neutralDirections() and try environment.ledge(pose.*, .head, 4, .behind)) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .ledge = .{ .phase = .running_approach } };
                    } else {
                        const continue_running = if (phase == .starting) intent.action or intent.direction != null or intent.vertical != null or intent.directions_conflict else intent.action and (intent.neutralDirections() or intent.direction == pose.facing or intent.vertical == .up);
                        if (!continue_running) {
                            if (!try environment.at(pose.*, .support, 2)) {
                                self.activity = .{ .stopping_run = .edge };
                            } else if (intent.action and backward) {
                                const leaves_edge = !try environment.at(pose.*, .support, 3);
                                rolling.shiftForward(pose, 16);
                                self.activity = if (leaves_edge) .{ .descending = .{ .phase = .reversing } } else .{ .reversing_run = .braking };
                            } else if (phase == .stride and phase.stride % 2 == 1 and intent.direction == pose.facing) {
                                rolling.shiftForward(pose, 16);
                                self.activity = .{ .changing_pace = .slowing };
                            } else if (phase == .stride and phase.stride == 3 and backward) {
                                self.activity = .{ .reversing_run = .braking };
                            } else if (intent.action and intent.vertical == .down) {
                                self.activity = .{ .rolling = .{ .phase = .running_entry } };
                            } else if (phase != .starting and try wallAt(environment, pose.*, 3)) {
                                rolling.shiftForward(pose, 16);
                                self.activity = .{ .stopping_run = .staggered };
                            } else self.activity = .{ .stopping_run = .braking };
                        } else if (phase != .starting and try wallAt(environment, pose.*, 3)) {
                            rolling.shiftForward(pose, 16);
                            self.activity = .{ .stopping_run = .staggered };
                        } else {
                            if (gait.strides.len == 0 or gait.entry_stride >= gait.strides.len) return error.InvalidGait;
                            self.activity = .{ .running = .{ .stride = switch (phase) {
                                .starting => gait.entry_stride,
                                .stride => |i| (i + 1) % gait.strides.len,
                            } } };
                        }
                    }
                },
                .stopping_run => |phase| self.activity = if (phase == .braking) .{ .stopping_run = .settling } else .standing,
                .reversing_run => |phase| {
                    if (phase == .braking) {
                        const unsupported = !try environment.at(pose.*, .support, 0);
                        pose.facing = if (pose.facing == .right) .left else .right;
                        self.activity = if (unsupported) .{ .descending = .{ .phase = .running } } else .{ .reversing_run = .follow_through };
                    } else if (try wallAt(environment, pose.*, 2)) {
                        self.activity = .{ .stopping_run = .wall };
                    } else if (try wallAt(environment, pose.*, 3)) {
                        self.activity = .{ .stopping_run = .braking };
                    } else if (intent.direction == pose.facing and !intent.action) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .changing_pace = .slowing };
                    } else if (intent.action and intent.vertical == .up) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .running_jump = .{} };
                    } else if (intent.action and intent.vertical == .down) {
                        self.activity = .{ .rolling = .{ .phase = .running_entry } };
                    } else if (!try environment.at(pose.*, .support, 2)) self.activity = .{ .stopping_run = .edge } else if (intent.action and intent.direction != null and intent.direction != pose.facing) {
                        rolling.shiftForward(pose, 16);
                        self.activity = .{ .reversing_run = .braking };
                    } else if (intent.action and (intent.neutralDirections() or intent.direction == pose.facing)) self.activity = .{ .running = .{ .stride = 0 } } else self.activity = .{ .stopping_run = .braking };
                },
                .changing_pace => |phase| {
                    if (phase == .slowing) {
                        if (!try environment.at(pose.*, .support, 1) or intent.direction != pose.facing) self.activity = .standing else if (intent.action) self.activity = .{ .changing_pace = .accelerating } else self.activity = .{ .walking = .{ .stride = 1 } };
                    } else {
                        if (!try environment.at(pose.*, .support, 1)) {
                            rolling.shiftForward(pose, 16);
                            self.activity = .{ .descending = .{ .phase = .running } };
                        } else {
                            if (try wallAt(environment, pose.*, 1)) self.activity = .{ .stopping_run = .wall } else if (try wallAt(environment, pose.*, 2) or try wallAt(environment, pose.*, 3)) self.activity = .{ .stopping_run = .braking } else if (intent.direction == pose.facing and !intent.action) {
                                rolling.shiftForward(pose, 16);
                                self.activity = .{ .changing_pace = .slowing };
                            } else if (intent.direction == pose.facing and intent.action) self.activity = .{ .running = .{ .stride = 0 } } else if (intent.neutralDirections() and !intent.action and !try environment.at(pose.*, .support, 2)) self.activity = .{ .stopping_run = .edge } else self.activity = .{ .stopping_run = .braking };
                        }
                    }
                },
                .stepping_down => {
                    if (!try environment.at(pose.*, .support, 0)) {
                        pose.position.y +%= clips.walking_fall_down;
                        self.activity = .{ .falling = .{} };
                    } else self.activity = .landing;
                },
                .landing, .low_landing => self.activity = .standing,
                .descending => |*drop| switch (try drop.finishPhase(intent, self.weapon_desired, pose, environment)) {
                    .continued => {},
                    .landing => self.activity = .landing,
                    .low_landing => self.activity = .low_landing,
                    .armed_landing => self.activity = .{ .armed = .{ .phase = .landing } },
                    .long_fall => self.activity = .{ .falling = .{} },
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                },
                .running_jump => |*jump| switch (try jump.finishPhase(clips.running_jump orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .standing => self.activity = .standing,
                    .resume_running => self.activity = .{ .running = .{ .stride = (clips.run orelse return error.MissingMotion).entry_stride } },
                    .reverse_run => self.activity = .{ .reversing_run = .braking },
                    .brake => self.activity = .{ .stopping_run = .braking },
                    .wall_stop => self.activity = .{ .stopping_run = .wall },
                    .settle_running => self.activity = .{ .stopping_run = .settling },
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                    .wall_collision => self.activity = .{ .recoiling = .{} },
                    .gliding_drop => self.activity = .{ .descending = .{ .phase = .gliding } },
                    .vertical_drop => self.activity = .{ .descending = .{ .phase = .vertical } },
                    .unbalanced_drop => self.activity = .{ .descending = .{ .phase = .unbalanced } },
                },
                .jumping => |*jump| switch (try jump.finishPhase(clips.jumps orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .finished => self.activity = .standing,
                    .climb_ledge => self.activity = .{ .ledge = .{ .phase = .climbing } },
                    .grip_ledge => self.activity = .{ .ledge = .{ .phase = .gripping } },
                    .wall_collision => self.activity = .{ .recoiling = .{} },
                    .fall_requested => self.activity = .{ .descending = .{ .phase = .short_jump } },
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                },
                .crouching => |phase| switch (phase) {
                    .lowering => self.activity = .{ .crouching = .holding },
                    .rising => self.activity = .standing,
                    .turning => {
                        pose.facing = if (pose.facing == .left) .right else .left;
                        self.activity = .{ .crouching = .holding };
                    },
                    .holding => {
                        if (self.weapon_desired) {
                            self.activity = .{ .armed = .{ .phase = .drawing_crouched } };
                        } else if (self.pickup_available and intent.action and !intent.directions_conflict and intent.direction == null and (intent.vertical == null or intent.vertical == .down)) {
                            self.pickup_requested = true;
                        } else if (intent.vertical == .down or (intent.vertical == null and intent.action and (intent.neutralDirections() or intent.direction == pose.facing))) {
                            // Remain low while crouch/action is held.
                        } else if (intent.direction) |direction| {
                            if (direction == pose.facing) {
                                const roll = clips.roll orelse return .locomotion_requested;
                                if (!try environment.at(pose.*, .support, 1)) {
                                    self.activity = .{ .rolling = .{ .phase = .drop } };
                                } else if (try environment.rollPassage(pose.*, 1) or !try environment.at(pose.*, .torso, 1)) {
                                    rolling.shiftForward(pose, roll.alignment_forward);
                                    self.activity = .{ .rolling = .{} };
                                } else self.activity = .{ .crouching = .rising };
                            } else if (!try environment.at(pose.*, .torso, -1)) self.activity = .{ .crouching = .turning } else self.activity = .{ .crouching = .rising };
                        } else self.activity = .{ .crouching = .rising };
                    },
                },
                .falling => |*state| switch (try state.finishPhase(clips.fall orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .fatal_landing => {
                        self.fatal_landing = true;
                        self.activity = .{ .dead = .landing };
                    },
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                },
                .dead => |phase| if (phase == .landing) {
                    self.activity = .{ .dead = .resting };
                } else {
                    self.death_wait_requested = (clips.fall orelse return error.MissingMotion).death_wait_steps;
                },
                .ledge => |*state| switch (try state.finishPhase(clips.ledge orelse return error.MissingMotion, intent, self.weapon_desired, pose, environment)) {
                    .continued => {},
                    .standing => self.activity = .standing,
                    .upright_landing => self.activity = .landing,
                    .low_recovery => self.activity = .{ .rolling = .{ .phase = .recover } },
                    .long_fall => self.activity = .{ .falling = .{} },
                    .waiting => return .advanced,
                    .armed_draw => self.activity = .{ .armed = .{ .phase = .drawing_after_climb } },
                },
                .recoiling => |*state| switch (try state.finishPhase(clips.recoil orelse return error.MissingMotion, intent, pose, environment)) {
                    .continued => {},
                    .standing => self.activity = .standing,
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                    .low_recovery => self.activity = .{ .rolling = .{ .phase = .recover } },
                    .long_fall => self.activity = .{ .falling = .{} },
                    .terrain_requested => return .terrain_transition_requested,
                },
                .rolling => |*roll| switch (try roll.finishPhase(clips.roll orelse return error.MissingMotion, intent, self.weapon_desired, pose, environment)) {
                    .continued => {},
                    .standing => self.activity = .standing,
                    .turning => self.activity = .{ .turning = .preparation },
                    .wall_collision => self.activity = .{ .recoiling = .{} },
                    .long_fall => self.activity = .{ .falling = .{} },
                    .catch_ledge => self.activity = .{ .ledge = .{ .phase = .catching } },
                    .running => self.activity = .{ .running = .{ .stride = 0 } },
                    .running_jump => self.activity = .{ .running_jump = .{} },
                    .jump_flight => self.activity = .{ .jumping = .{ .kind = .forward, .phase = .flight } },
                    .running_drop => self.activity = .{ .descending = .{ .phase = .running } },
                    .brake => self.activity = .{ .stopping_run = .braking },
                    .wall_stop => self.activity = .{ .stopping_run = .wall },
                    .stagger_stop => self.activity = .{ .stopping_run = .staggered },
                    .armed_recovery => self.activity = .{ .armed = .{ .phase = .roll_recovery } },
                },
            }
            self.playback = .{};
            try environment.motionBoundary(pose);
            clip = try self.selectedClip(clips);
            if (clip.steps.len == 0) return error.MissingMotion;
        }
        self.sound_requested = self.playback.soundOnEntry(clip);
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
        pub fn rollPassage(_: @This(), _: motion.Pose, _: i16) !bool {
            return false;
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

test "a low passage permits crouch-to-roll while an equally occupied solid wall does not" {
    const geometry = @import("../geometry.zig");
    const terrain = @import("../terrain.zig");
    const Environment = @import("conrad_environment.zig").Environment;
    const id: geometry.RoomId = @fromBackingInt(30);
    const blocking: [18]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = id, .columns = 6, .rows = 3, .width = 96, .height = 72, .blocking = &blocking, .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked } }};
    const hold = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &hold };
    const clips: Clips = .{ .wake = clip, .stand = clip, .turn_preparation = clip, .turn_follow_through = clip, .crouch = .{ .lower = clip, .hold = clip, .rise = clip, .turn = clip }, .roll = .{ .enter = clip, .tumble = clip, .exit = clip, .balance = clip, .rise = clip, .drop = clip, .recover = clip, .upright_landing = clip } };
    for ([_]terrain.Material{ .solid, .restricted }) |material| {
        var cells: [18]terrain.Material = @splat(.empty);
        @memset(cells[12..], .solid);
        cells[6 + 3] = material;
        var world = try terrain.State.init(std.testing.allocator, .{ .rooms = &rooms }, &cells, .{});
        defer world.deinit();
        var environment: Environment = .{ .map = world.map(), .materials = world.view(), .room = id };
        var pose: motion.Pose = .{ .position = .{ .x = 24, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
        var controller: Controller = .{ .activity = .{ .crouching = .holding }, .playback = .{ .next_step = 1 } };
        try std.testing.expectEqual(.advanced, try controller.advanceIn(clips, .{ .direction = .right }, &pose, &environment));
        if (material == .restricted) {
            try std.testing.expectEqualDeep(Activity{ .rolling = .{} }, controller.activity);
            try std.testing.expectEqual(@as(i16, 40), pose.position.x);
        } else {
            try std.testing.expectEqualDeep(Activity{ .crouching = .rising }, controller.activity);
            try std.testing.expectEqual(@as(i16, 24), pose.position.x);
        }
    }
}

test "an exhausted ledge motion waits without replaying artwork or handing rooms off" {
    const held = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &held };
    const clips: Clips = .{ .wake = clip, .stand = clip, .turn_preparation = clip, .turn_follow_through = clip, .ledge = .{ .lower = clip, .catch_fall = clip, .grip = clip, .hang = clip, .reach = clip, .settle_grip = clip, .climb = clip, .stand = clip, .release = clip, .drop = clip, .turn_release = clip, .tumble_release = clip, .brace = clip, .braced_lower = clip } };
    const Ground = struct {
        boundaries: usize = 0,
        pub fn at(_: *@This(), _: motion.Pose, height: anytype, _: i16) !bool {
            return height == .head;
        }
        pub fn ledge(_: *@This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
        pub fn rollPassage(_: *@This(), _: motion.Pose, _: i16) !bool {
            return false;
        }
        pub fn motionBoundary(self: *@This(), _: *motion.Pose) !void {
            self.boundaries += 1;
        }
    };
    var ground: Ground = .{};
    var pose: motion.Pose = .{ .position = .{ .x = 20, .y = 60 }, .facing = .left, .visual = .{ .id = @fromBackingInt(8) } };
    const before = pose;
    var controller: Controller = .{ .activity = .{ .ledge = .{ .phase = .tumbling_release } }, .playback = .{ .next_step = 1 } };
    for (0..3) |_| try std.testing.expectEqual(.advanced, try controller.advanceIn(clips, .{}, &pose, &ground));
    try std.testing.expectEqualDeep(before, pose);
    try std.testing.expectEqual(@as(usize, 1), controller.playback.next_step);
    try std.testing.expectEqual(@as(usize, 0), ground.boundaries);
}

test "using an available item has its own motion boundary and does not request pickup" {
    const steps = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &steps };
    const clips: Clips = .{ .wake = clip, .stand = clip, .turn_preparation = clip, .turn_follow_through = clip, .use_item = clip };
    var actor: Controller = .{ .activity = .standing, .playback = .{ .next_step = 1 }, .use_available = true, .pickup_available = true };
    var pose: motion.Pose = .{ .position = .{ .x = 32, .y = 70 }, .visual = .{ .id = @fromBackingInt(0) } };
    _ = try actor.advance(clips, .{ .use_item = true }, &pose);
    try std.testing.expectEqualDeep(Activity.using_item, actor.activity);
    try std.testing.expect(!actor.use_requested and !actor.pickup_requested);
    _ = try actor.advance(clips, .{ .use_item = true }, &pose);
    try std.testing.expectEqualDeep(Activity.standing, actor.activity);
    try std.testing.expect(actor.use_requested and !actor.pickup_requested);
    _ = try actor.advance(clips, .{}, &pose);
    try std.testing.expect(!actor.use_requested);
}

test "run startup respects close walls in both directions before entering a stride" {
    const held = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &held };
    const strides = [_]motion.Clip{clip};
    const walks = [_]WalkMotion{.{ .clip = clip }};
    const clips: Clips = .{ .wake = clip, .stand = clip, .turn_preparation = clip, .turn_follow_through = clip, .walk = .{ .start = .{ .clip = clip }, .strides = &walks }, .run = .{ .start = clip, .strides = &strides, .entry_stride = 0, .brake = clip, .settle = clip, .wall_stop = clip, .stagger_stop = clip } };
    const Wall = struct {
        distance: i16,
        pub fn at(self: @This(), _: motion.Pose, height: anytype, ahead: i16) !bool {
            return height == .support or (height == .torso and ahead >= self.distance);
        }
        pub fn motionBoundary(_: @This(), _: *motion.Pose) !void {}
        pub fn rollPassage(_: @This(), _: motion.Pose, _: i16) !bool {
            return false;
        }
        pub fn ledge(_: @This(), _: motion.Pose, _: anytype, _: i16, _: anytype) !bool {
            return false;
        }
    };
    for ([_]motion.Facing{ .left, .right }) |facing| {
        var pose: motion.Pose = .{ .position = .{ .x = 96, .y = 142 }, .facing = facing, .visual = .{ .id = @fromBackingInt(0) } };
        const intent: Intent = .{ .direction = facing, .action = true };
        var standing: Controller = .{ .activity = .standing, .playback = .{ .next_step = 1 } };
        _ = try standing.advanceIn(clips, intent, &pose, Wall{ .distance = 1 });
        try std.testing.expectEqualDeep(Activity{ .walking = .starting }, standing.activity);
        for ([_]i16{ 1, 2, 3 }) |distance| {
            var starting: Controller = .{ .activity = .{ .running = .starting }, .playback = .{ .next_step = 1 } };
            _ = try starting.advanceIn(clips, intent, &pose, Wall{ .distance = distance });
            try std.testing.expectEqualDeep(Activity{ .stopping_run = if (distance == 1) .wall else .braking }, starting.activity);
            try std.testing.expectEqual(@as(i16, 96), pose.position.x);
        }
    }
}

test "operating a control commits the reach but requires action at the press boundary" {
    const still = [_]motion.Step{.hold};
    const clip: motion.Clip = .{ .steps = &still };
    const clips: Clips = .{ .wake = clip, .stand = clip, .turn_preparation = clip, .turn_follow_through = clip, .operate = .{ .reach = clip, .press = clip, .recover = clip } };
    for ([_]bool{ false, true }) |keep_action| {
        var actor: Controller = .{ .activity = .standing, .playback = .{ .next_step = 1 }, .control_available = true };
        var pose: motion.Pose = .{ .position = .{ .x = 64, .y = 70 }, .facing = .left, .visual = .{ .id = @fromBackingInt(1) } };
        _ = try actor.advance(clips, .{ .action = true }, &pose);
        try std.testing.expectEqualDeep(Activity{ .operating = .reaching }, actor.activity);
        _ = try actor.advance(clips, .{}, &pose);
        try std.testing.expectEqualDeep(Activity{ .operating = .pressing }, actor.activity);
        try std.testing.expect(!actor.operate_requested);
        _ = try actor.advance(clips, .{ .action = keep_action }, &pose);
        try std.testing.expectEqual(keep_action, actor.operate_requested);
        _ = try actor.advance(clips, .{ .action = true }, &pose);
        try std.testing.expectEqualDeep(Activity.standing, actor.activity);
        try std.testing.expect(!actor.operate_requested);
    }
}
