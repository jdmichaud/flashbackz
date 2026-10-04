//! Conrad's postures while carried by a lift. Ride support comes from passenger ownership,
//! so terrain disappearing beneath the moving platform cannot trigger an ordinary fall.
const std = @import("std");
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
const rolling = @import("conrad_roll.zig");
pub const Phase = enum {
    waiting,
    standing,
    turn_prepare,
    turn_finish,
    crouch_lower,
    crouched,
    crouch_rise,
    crouch_turn,
    drawing,
    aiming,
    holster_aim,
    lowering_gun,
    holster_finish,
    fire_high,
    turn_aim,
    crouch_aim,
    aiming_crouched,
    rise_aim,
    lower_aim_crouched,
    crouched_gun,
    holster_crouched,
    fire_low,
    turn_low,
    raise_aim_crouched,
    rise_relaxed,
    turn_crouched_gun,
    draw_crouched,
};
pub const Clips = struct { entries: [@typeInfo(Phase).@"enum".field_names.len]motion.Clip };
pub const Ground = enum { standing, crouched, armed_standing, armed_aiming, armed_crouched, armed_aiming_crouched };
pub const Outcome = union(enum) { continued, boarded, leave: Ground, fire: @import("../pistol_shot.zig").Height };
pub const State = struct {
    phase: Phase = .waiting,
    pub fn clip(self: State, clips: Clips) motion.Clip {
        return clips.entries[@backingInt(self.phase)];
    }
    pub fn acceptsArrival(self: State) bool {
        return switch (self.phase) {
            .standing, .crouched, .aiming, .aiming_crouched, .crouched_gun, .lowering_gun => true,
            else => false,
        };
    }
    fn reverse(pose: *motion.Pose) void {
        pose.facing = if (pose.facing == .left) .right else .left;
    }
    pub fn finish(self: *State, intent: controls.Intent, desired: bool, acknowledged: bool, arrived: bool, pose: *motion.Pose) Outcome {
        if (arrived and self.acceptsArrival()) return .{ .leave = switch (self.phase) {
            .standing => .standing,
            .crouched => .crouched,
            .aiming => .armed_aiming,
            .aiming_crouched => .armed_aiming_crouched,
            .crouched_gun => .armed_crouched,
            .lowering_gun => .armed_standing,
            else => unreachable,
        } };
        const plain = !intent.action and !intent.weapon and !intent.use_item and !intent.directions_conflict;
        const backward = plain and intent.vertical == null and intent.direction != null and intent.direction != pose.facing;
        const down = plain and intent.direction == null and intent.vertical == .down;
        const up = plain and intent.direction == null and intent.vertical == .up;
        const fire = intent.action and !intent.weapon and !intent.use_item;
        switch (self.phase) {
            .waiting => {
                if (!acknowledged) return .{ .leave = .standing };
                self.phase = .standing;
                return .boarded;
            },
            .standing => {
                if (backward) self.phase = .turn_prepare else if (down) self.phase = .crouch_lower else if (desired) self.phase = .drawing;
            },
            .turn_prepare => {
                reverse(pose);
                self.phase = .turn_finish;
            },
            .turn_finish, .crouch_rise, .holster_finish => self.phase = .standing,
            .crouch_lower, .holster_crouched => self.phase = .crouched,
            .crouch_turn => {
                reverse(pose);
                self.phase = .crouched;
            },
            .crouched => {
                if (backward) self.phase = .crouch_turn else if (desired) self.phase = .draw_crouched else if (!down) self.phase = .crouch_rise;
            },
            .drawing, .fire_high => self.phase = .aiming,
            .holster_aim, .rise_relaxed => self.phase = .lowering_gun,
            // The authored unconditional continuation has priority over later turn rules.
            .lowering_gun => self.phase = .holster_finish,
            .turn_aim => {
                reverse(pose);
                self.phase = .aiming;
            },
            .turn_low => {
                reverse(pose);
                self.phase = .aiming_crouched;
            },
            .turn_crouched_gun => {
                reverse(pose);
                self.phase = .crouched_gun;
            },
            .aiming => {
                if (!desired) self.phase = .holster_aim else if (fire) {
                    self.phase = .fire_high;
                    return .{ .fire = .standing };
                } else if (down) {
                    rolling.shiftForward(pose, -8);
                    self.phase = .crouch_aim;
                } else if (backward) self.phase = .turn_aim;
            },
            .crouch_aim => {
                rolling.shiftForward(pose, 8);
                self.phase = .aiming_crouched;
            },
            .rise_aim => {
                rolling.shiftForward(pose, 8);
                self.phase = .aiming;
            },
            .aiming_crouched => {
                if (up) {
                    rolling.shiftForward(pose, -8);
                    self.phase = .rise_aim;
                } else if (!desired) self.phase = .lower_aim_crouched else if (fire) {
                    self.phase = .fire_low;
                    return .{ .fire = .crouched };
                } else if (backward) self.phase = .turn_low;
            },
            .lower_aim_crouched, .draw_crouched => self.phase = .crouched_gun,
            .fire_low, .raise_aim_crouched => self.phase = .aiming_crouched,
            .crouched_gun => {
                if (fire) self.phase = .raise_aim_crouched else if (!desired) self.phase = .holster_crouched else if (backward) self.phase = .turn_crouched_gun else if (up) self.phase = .rise_relaxed;
            },
        }
        return .continued;
    }
};
