//! Locomotion with Conrad's gun drawn. Aiming, relaxed and crouched postures share
//! authored movement clips; collision decisions use ordinary terrain queries.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const rolling = @import("conrad_roll.zig");
pub const Phase = enum {
    clearing_draw,
    roll_recovery,
    drawing_after_climb,
    firing,
    firing_crouched,
    drawing_crouched,
    draw_crouched_release,
    draw_start,
    drawing,
    draw_release,
    aiming,
    lowering_aim,
    standing,
    walking,
    turning,
    holstering,
    holstering_aim,
    raising_aim,
    crouching,
    crouched,
    turning_crouched,
    rising,
    holstering_crouched,
    lowering_aim_crouched,
    raising_aim_crouched,
    aim_crouch_release,
    aiming_crouched,
    crouching_aim,
    rising_aim,
    turning_aim,
    turning_aim_crouched,
    stepping_down,
    landing,
};
pub const Clips = struct {
    clearing_draw: motion.Clip,
    roll_recovery: motion.Clip,
    drawing_after_climb: motion.Clip,
    firing: motion.Clip,
    firing_crouched: motion.Clip,
    drawing_crouched: motion.Clip,
    draw_crouched_release: motion.Clip,
    draw_start: motion.Clip,
    drawing: motion.Clip,
    draw_release: motion.Clip,
    aiming: motion.Clip,
    lowering_aim: motion.Clip,
    standing: motion.Clip,
    walking: motion.Clip,
    turning: motion.Clip,
    holstering: motion.Clip,
    holstering_aim: motion.Clip,
    raising_aim: motion.Clip,
    crouching: motion.Clip,
    crouched: motion.Clip,
    turning_crouched: motion.Clip,
    rising: motion.Clip,
    holstering_crouched: motion.Clip,
    lowering_aim_crouched: motion.Clip,
    raising_aim_crouched: motion.Clip,
    aim_crouch_release: motion.Clip,
    aiming_crouched: motion.Clip,
    crouching_aim: motion.Clip,
    rising_aim: motion.Clip,
    turning_aim: motion.Clip,
    turning_aim_crouched: motion.Clip,
    stepping_down: motion.Clip,
    landing: motion.Clip,
};

/// Sample after actor movement. A press commits a toggle on the next sample, then
/// waits for release. Releasing early still completes the accepted command.
pub const Toggle = struct {
    desired: bool = false,
    phase: enum { ready, pending, held } = .ready,
    pub fn advance(self: *Toggle, held: bool, available: bool) void {
        switch (self.phase) {
            .ready => if (held and available) {
                self.phase = .pending;
            },
            .pending => {
                self.desired = !self.desired;
                self.phase = .held;
            },
            .held => if (!held) {
                self.phase = .ready;
            },
        }
    }
};
pub const Boundary = enum {
    continued,
    unarmed_standing,
    unarmed_crouched,
    unarmed_rising,
    roll,
    roll_drop,
    long_fall,
    fire_standing,
    fire_crouched,
};
pub const State = struct {
    phase: Phase = .draw_start,
    pub fn clip(self: State, clips: Clips) motion.Clip {
        return switch (self.phase) {
            inline else => |tag| @field(clips, @tagName(tag)),
        };
    }
    fn reverse(pose: *motion.Pose) void {
        pose.facing = if (pose.facing == .left) .right else .left;
    }
    pub fn finishPhase(
        self: *State,
        intent: controls.Intent,
        desired: bool,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        const direction_allowed = !intent.weapon and !intent.use_item;
        const forward = direction_allowed and intent.direction == pose.facing;
        const backward = direction_allowed and
            intent.direction != null and
            intent.direction != pose.facing;
        const up = direction_allowed and intent.vertical == .up;
        const down = direction_allowed and intent.vertical == .down;
        const turn_obstructed = if (backward) try environment.at(
            pose.*,
            .torso,
            0,
        ) and !try environment.at(pose.*, .torso, 1) else false;
        switch (self.phase) {
            .firing => self.phase = .aiming,
            .firing_crouched => self.phase = .aiming_crouched,
            .drawing_crouched => self.phase = .draw_crouched_release,
            .draw_crouched_release => if (!intent.weapon) {
                self.phase = .crouched;
            },
            .clearing_draw => return .unarmed_standing,
            .draw_start => {
                if (try environment.at(
                    pose.*,
                    .torso,
                    1,
                ) and try environment.at(pose.*, .torso, 0)) {
                    self.phase = .clearing_draw;
                    return .continued;
                }
                if (!desired) return .unarmed_standing;
                self.phase = .drawing;
            },
            .drawing, .drawing_after_climb => self.phase = .draw_release,
            .draw_release => if (!(intent.weapon and
                !intent.action and
                !intent.use_item and
                intent.neutralDirections()))
            {
                self.phase = .aiming;
            },
            .holstering, .holstering_aim => return .unarmed_standing,
            .holstering_crouched => return if (intent.weapon) .unarmed_rising else .unarmed_crouched,
            .lowering_aim, .rising => self.phase = .standing,
            .raising_aim => self.phase = .aiming,
            .crouching, .lowering_aim_crouched => self.phase = .crouched,
            .raising_aim_crouched, .landing, .roll_recovery => self.phase = .aim_crouch_release,
            .aim_crouch_release => if (!intent.weapon) {
                self.phase = .aiming_crouched;
            },
            .turning, .turning_crouched, .turning_aim, .turning_aim_crouched => {
                reverse(pose);
                self.phase = switch (self.phase) {
                    .turning => .standing,
                    .turning_crouched => .crouched,
                    .turning_aim => .aiming,
                    else => .aiming_crouched,
                };
            },
            .crouching_aim, .rising_aim => {
                rolling.shiftForward(pose, 8);
                self.phase = if (self.phase == .crouching_aim) .aiming_crouched else .aiming;
            },
            .standing => {
                if (!try environment.at(pose.*, .support, 0)) {
                    self.phase = .stepping_down;
                } else if (intent.use_item or
                    (backward and !intent.action and turn_obstructed))
                {} else if (forward and
                    !intent.action)
                {
                    if (!try environment.at(pose.*, .support, 1)) {
                        self.phase = .stepping_down;
                    } else if (!try environment.at(pose.*, .torso, 1)) {
                        self.phase = .walking;
                    }
                } else if (backward and !intent.action and !turn_obstructed) {
                    self.phase = .turning;
                } else if (down) {
                    self.phase = .crouching;
                } else if (!desired) {
                    self.phase = .holstering;
                } else if (intent.action) {
                    self.phase = .raising_aim;
                } else if (backward and !turn_obstructed) {
                    self.phase = .turning;
                }
            },
            .walking => {
                if (!try environment.at(
                    pose.*,
                    .support,
                    1,
                ) or !forward or intent.action or try environment.at(pose.*, .torso, 1)) {
                    self.phase = .standing;
                }
            },
            .aiming => {
                if (intent.use_item or (backward and turn_obstructed)) {} else if (backward) {
                    self.phase = .turning_aim;
                } else if (down) {
                    rolling.shiftForward(pose, -8);
                    self.phase = .crouching_aim;
                } else if (!desired) {
                    self.phase = .holstering_aim;
                } else if (forward and !intent.action) {
                    self.phase = .lowering_aim;
                } else if (intent.action) {
                    self.phase = .firing;
                    return .fire_standing;
                }
            },
            .crouched => {
                if (backward and turn_obstructed) {} else if (backward) {
                    self.phase = .turning_crouched;
                } else if (!desired) {
                    self.phase = .holstering_crouched;
                } else if (up and !intent.action) {
                    self.phase = .rising;
                } else if (forward and !intent.action) {
                    if (!try environment.at(pose.*, .support, 1)) return .roll_drop;
                    if (try environment.rollPassage(pose.*, 1) or !try environment.at(
                        pose.*,
                        .torso,
                        1,
                    )) {
                        rolling.shiftForward(pose, 16);
                        return .roll;
                    }
                    self.phase = .rising;
                } else if (up) {
                    self.phase = .rising;
                } else if (intent.action) {
                    self.phase = .raising_aim_crouched;
                }
            },
            .aiming_crouched => {
                if (backward and turn_obstructed) {} else if (up) {
                    rolling.shiftForward(pose, -8);
                    self.phase = .rising_aim;
                } else if (!desired) {
                    self.phase = .lowering_aim_crouched;
                } else if (backward) {
                    self.phase = .turning_aim_crouched;
                } else if (forward and !intent.action) {
                    self.phase = .lowering_aim_crouched;
                } else if (intent.action) {
                    self.phase = .firing_crouched;
                    return .fire_crouched;
                }
            },
            .stepping_down => {
                if (try environment.at(pose.*, .support, 0)) {
                    self.phase = .landing;
                } else {
                    pose.position.y +%= 24;
                    return .long_fall;
                }
            },
        }
        return .continued;
    }
};

test "weapon toggle commits a short press once and does not repeat while held" {
    const std = @import("std");
    var toggle: Toggle = .{};
    toggle.advance(true, false);
    try std.testing.expectEqual(.ready, toggle.phase);
    toggle.advance(true, true);
    try std.testing.expect(!toggle.desired);
    toggle.advance(false, true);
    try std.testing.expect(toggle.desired);
    toggle.advance(false, true);
    toggle.advance(true, true);
    toggle.advance(true, true);
    for (0..40) |_| toggle.advance(true, true);
    try std.testing.expect(!toggle.desired);
}

test "an occupied wall edge blocks an aimed turn before the fire request" {
    const std = @import("std");
    const Wall = struct {
        pub fn at(_: @This(), _: motion.Pose, height: anytype, ahead: i16) !bool {
            return height == .support or (height == .torso and ahead == 0);
        }
        pub fn rollPassage(_: @This(), _: motion.Pose, _: i16) !bool {
            return false;
        }
    };
    for ([_]motion.Facing{ .left, .right }) |facing| {
        var pose: motion.Pose = .{
            .position = .{ .x = 96, .y = 70 },
            .facing = facing,
            .visual = .{ .id = @fromBackingInt(0) },
        };
        for ([_]Phase{ .aiming, .aiming_crouched, .crouched }) |phase| {
            var state: State = .{ .phase = phase };
            const result = try state.finishPhase(
                .{ .direction = if (facing == .left) .right else .left, .action = true },
                true,
                &pose,
                Wall{},
            );
            try std.testing.expectEqual(.continued, result);
            try std.testing.expectEqual(phase, state.phase);
            try std.testing.expectEqual(facing, pose.facing);
        }
    }
}
