//! Injury movement and recovery. Hit posture selects an entry; terrain and player intent
//! then determine the knockdown, ledge catch, fall or get-up. Health stays with the session.
const motion = @import("../motion.zig");
const combat = @import("../combat.zig");
const controls = @import("controls.zig");
const shift = @import("conrad_roll.zig").shiftForward;

pub const Phase = enum {
    front_impact,
    rear_impact,
    backward_flight,
    backward_airborne,
    backward_ceiling,
    backward_confined,
    backward_staggered,
    backward_landing,
    backward_rest,
    confined_rest,
    backward_rise,
    backward_armed_rise,
    forward_flight,
    forward_far_wall,
    forward_mid_wall,
    forward_near_wall,
    forward_confined,
    forward_settle,
    forward_rest,
    forward_rise,
    forward_armed_rise,
    forward_edge,
    forward_edge_mid,
    forward_edge_near,
    forward_drop,
    forward_airborne,
    forward_low,
    forward_low_wall,
    forward_low_confined,
    forward_low_landing,
    forward_low_confined_landing,
    backward_drop,
    fatal_drop_start,
    fatal_drop,
    final_landing,
};
pub const phase_count = @typeInfo(Phase).@"enum".field_names.len;
pub const Entry = struct {
    phase: Phase,
    forward: i16 = 0,
    down: i16 = 0,
    turn: bool = false,
    damage: bool = false,
};
pub const Obstruction = union(enum) {
    wall_ahead: i16,
    supported,
    wall_edge: struct { ahead: i16, blocked_forward: bool },
};
pub const Response = struct {
    normal: ?Entry = null,
    obstructed: ?Entry = null,
    obstruction: ?Obstruction = null,
    pub fn select(self: Response, pose: motion.Pose, environment: anytype) !?Entry {
        if (self.obstruction) |probe| {
            const matches = switch (probe) {
                .wall_ahead => |ahead| try environment.at(pose, .torso, ahead),
                .supported => try environment.at(pose, .support, 0),
                .wall_edge => |edge| blk: {
                    const behind = try environment.at(pose, .torso, edge.ahead + 1);
                    const current = try environment.at(pose, .torso, edge.ahead);
                    break :blk if (edge.blocked_forward) behind and
                        !current else !behind and
                        current;
                },
            };
            if (matches) return self.obstructed;
        }
        return self.normal;
    }
};
pub const Policy = struct {
    priority: [4]combat.Impact = .{ .rear_high, .rear_low, .front_high, .front_low },
    responses: [4]Response = @splat(.{}),
    pub fn vulnerability(self: Policy) combat.Vulnerability {
        var result: combat.Vulnerability = .{};
        for (
            @import("std").enums.values(combat.Impact),
            self.responses,
        ) |impact, response| if (response.normal != null or response.obstructed != null) {
            result.set(impact);
        };
        return result;
    }
};
pub const Definition = struct { clips: [phase_count]motion.Clip, policies: []const Policy, death_wait_steps: u16 };
pub const Boundary = enum {
    continued,
    standing,
    armed,
    catch_ledge,
    long_fall,
    low_recovery,
    death_wait,
};
pub const Outcome = struct { boundary: Boundary = .continued, damage: bool = false };

pub const State = struct {
    phase: Phase,
    pub fn clip(self: State, definition: Definition) motion.Clip {
        return definition.clips[@backingInt(self.phase)];
    }

    pub fn finish(
        self: *State,
        health: i16,
        weapon_desired: bool,
        intent: controls.Intent,
        pose: *motion.Pose,
        environment: anytype,
    ) !Outcome {
        const alive = health > 0;
        switch (self.phase) {
            .front_impact => {
                self.phase = if (try environment.at(
                    pose.*,
                    .torso,
                    -1,
                )) .backward_confined else .backward_flight;
                shift(pose, -16);
                pose.position.y -%= 16;
                return .{ .damage = true };
            },
            .rear_impact => {
                const wall_one = try environment.at(pose.*, .torso, 1);
                if (wall_one and try environment.at(pose.*, .torso, 0)) {
                    self.phase = .forward_confined;
                } else {
                    if (wall_one) self.phase = .forward_confined else if (!try environment.at(
                        pose.*,
                        .support,
                        3,
                    )) self.phase = .forward_edge else if (try environment.at(
                        pose.*,
                        .torso,
                        3,
                    ) and !try environment.at(
                        pose.*,
                        .support,
                        2,
                    )) self.phase = .forward_edge_mid else if (try environment.at(
                        pose.*,
                        .torso,
                        2,
                    ) and !try environment.at(
                        pose.*,
                        .support,
                        1,
                    )) self.phase = .forward_edge_near else if (try environment.at(
                        pose.*,
                        .torso,
                        2,
                    )) self.phase = .forward_near_wall else if (try environment.at(
                        pose.*,
                        .torso,
                        3,
                    )) self.phase = .forward_mid_wall else if (try environment.at(
                        pose.*,
                        .torso,
                        4,
                    )) self.phase = .forward_far_wall else if (try environment.ledge(
                        pose.*,
                        .support,
                        3,
                        .ahead,
                    )) self.phase = .forward_edge else self.phase = .forward_flight;
                    shift(pose, 16);
                }
                return .{ .damage = true };
            },
            .backward_flight => {
                const ledge = try environment.ledge(pose.*, .support, 1, .behind);
                if (!alive and (ledge or !try environment.at(pose.*, .support, 1))) {
                    pose.position.y +%= 16;
                    self.phase = .fatal_drop_start;
                } else if (try environment.at(
                    pose.*,
                    .torso,
                    0,
                )) self.phase = .backward_staggered else if (intent.action and ledge) {
                    pose.position.y +%= 16;
                    return .{ .boundary = .catch_ledge };
                } else if (ledge or !try environment.at(pose.*, .support, 1)) {
                    pose.position.y +%= 24;
                    self.phase = .backward_drop;
                } else self.phase = .backward_landing;
            },
            .backward_airborne, .backward_ceiling => {
                if (!alive and !try environment.at(pose.*, .support, 0)) {
                    pose.position.y +%= 24;
                    self.phase = .backward_drop;
                } else if (intent.action and try environment.ledge(pose.*, .support, 0, .behind)) {
                    shift(pose, 16);
                    pose.position.y +%= 16;
                    return .{ .boundary = .catch_ledge };
                } else if (try environment.at(
                    pose.*,
                    .support,
                    0,
                )) self.phase = .backward_landing else {
                    pose.position.y +%= 24;
                    self.phase = .backward_drop;
                }
            },
            .backward_confined, .backward_staggered, .final_landing => self.phase = .confined_rest,
            .backward_landing => self.phase = .backward_rest,
            .backward_rest, .confined_rest => {
                if (!alive) return .{ .boundary = .death_wait };
                self.phase = if (!try environment.at(
                    pose.*,
                    .torso,
                    1,
                ) and weapon_desired) .backward_armed_rise else .backward_rise;
            },
            .backward_rise, .forward_rise => return .{ .boundary = .standing },
            .backward_armed_rise, .forward_armed_rise => return .{ .boundary = .armed },
            .forward_flight, .forward_far_wall, .forward_near_wall, .forward_confined, .forward_settle, .forward_low_landing, .forward_low_confined_landing => self.phase = .forward_rest,
            .forward_mid_wall => {
                if (!try environment.at(pose.*, .support, 0)) {
                    shift(pose, -16);
                    pose.position.y +%= 56;
                    return .{ .boundary = .long_fall };
                }
                self.phase = .forward_settle;
            },
            .forward_rest => {
                if (!alive) return .{ .boundary = .death_wait };
                self.phase = if (weapon_desired) .forward_armed_rise else .forward_rise;
            },
            .forward_edge, .forward_edge_mid, .forward_edge_near => {
                if (alive and intent.action and try environment.ledge(
                    pose.*,
                    .support,
                    1,
                    .behind,
                )) {
                    pose.position.y +%= 32;
                    return .{ .boundary = .catch_ledge };
                }
                pose.position.y +%= 8;
                self.phase = .forward_drop;
            },
            .forward_drop => {
                const ledge = try environment.ledge(pose.*, .support, 0, .behind);
                const unsupported = !try environment.at(pose.*, .support, 0);
                if (alive and intent.action and ledge) {
                    shift(pose, -8);
                    pose.position.y +%= 40;
                    return .{ .boundary = .catch_ledge };
                }
                if (unsupported or ledge) {
                    shift(pose, 8);
                    pose.position.y +%= 80;
                    return .{ .boundary = .long_fall };
                }
                pose.facing = if (pose.facing == .left) .right else .left;
                shift(pose, -8);
                pose.position.y +%= 24;
                self.phase = .final_landing;
                return .{};
            },
            .forward_airborne => {
                const confined = try environment.at(pose.*, .torso, 0) and !try environment.at(
                    pose.*,
                    .torso,
                    -1,
                );
                if (confined) self.phase = .forward_low_confined else {
                    const blocked = try environment.at(
                        pose.*,
                        .torso,
                        3,
                    ) or try environment.at(pose.*, .torso, 2);
                    shift(pose, 16);
                    self.phase = if (blocked) .forward_low_wall else .forward_low;
                }
                pose.position.y +%= 8;
            },
            .forward_low => {
                if (try environment.at(
                    pose.*,
                    .support,
                    0,
                )) self.phase = .forward_low_landing else {
                    pose.position.y +%= 72;
                    return .{ .boundary = .long_fall };
                }
            },
            .forward_low_wall, .forward_low_confined => {
                if (try environment.at(pose.*, .support, -1)) {
                    if (self.phase == .forward_low_wall) {
                        shift(pose, -16);
                        pose.position.y -%= 16;
                        self.phase = .forward_low_landing;
                    } else self.phase = .forward_low_confined_landing;
                } else {
                    shift(pose, -16);
                    pose.position.y +%= 56;
                    return .{ .boundary = .long_fall };
                }
            },
            .backward_drop => {
                if (try environment.at(pose.*, .support, 0)) {
                    pose.position.y +%= 16;
                    if (alive) return .{ .boundary = .low_recovery };
                    self.phase = .final_landing;
                    return .{};
                }
                if (alive and intent.action and try environment.ledge(
                    pose.*,
                    .support,
                    1,
                    .behind,
                )) {
                    pose.position.y +%= 32;
                    return .{ .boundary = .catch_ledge };
                }
                pose.position.y +%= 72;
                return .{ .boundary = .long_fall };
            },
            .fatal_drop_start, .fatal_drop => {
                if (try environment.at(pose.*, .support, 0)) {
                    shift(pose, -16);
                    self.phase = .final_landing;
                    return .{};
                }
                pose.position.y +%= 24;
                self.phase = .fatal_drop;
            },
        }
        return .{};
    }
};
