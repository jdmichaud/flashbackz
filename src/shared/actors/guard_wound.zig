//! Clearance-dependent guard knockback. Recovery, health loss and defeat are distinct
//! outcomes so encounter signals cannot run before the authored death animation finishes.
const motion = @import("../motion.zig");
const Environment = @import("conrad_environment.zig").Environment;
const shift = @import("conrad_roll.zig").shiftForward;
pub const Direction = enum { forward, backward };
pub const Phase = enum { impact, recovery, fatal_launch, fatal_landing };
pub const Landing = struct { clip: motion.Clip, forward: i16 = 0, down: i16 = 0 };
pub const FatalPath = struct {
    launch: motion.Clip,
    ground: ?Landing = null,
    drop: ?Landing = null,
};
pub const Profile = struct {
    impacts: [2]motion.Clip,
    forward_recovery: [3]motion.Clip,
    backward_recovery: [4]motion.Clip,
    forward_fatal: [4]FatalPath,
    backward_fatal: [3]FatalPath,
    recovery_score: u16,
    forward_scores: [6]u16,
    backward_scores: [3]u16,
};
pub const Outcome = struct {
    next: enum { continued, turn_in_flight, fire_in_flight, defeated } = .continued,
    damage: bool = false,
    score: u16 = 0,
};
pub const State = struct {
    direction: Direction,
    phase: Phase = .impact,
    clearance: u2 = 0,
    dropped: bool = false,

    fn path(self: State, profile: Profile) FatalPath {
        return if (self.direction == .forward) profile.forward_fatal[self.clearance] else profile.backward_fatal[self.clearance];
    }
    pub fn clip(self: State, profile: Profile) motion.Clip {
        return switch (self.phase) {
            .impact => profile.impacts[@backingInt(self.direction)],
            .recovery => if (self.direction == .forward) profile.forward_recovery[self.clearance] else profile.backward_recovery[self.clearance],
            .fatal_launch => self.path(profile).launch,
            .fatal_landing => (if (self.dropped) self.path(profile).drop else self.path(profile).ground).?.clip,
        };
    }
    pub fn finish(
        self: *State,
        profile: Profile,
        health: i16,
        pose: *motion.Pose,
        environment: Environment,
    ) !Outcome {
        switch (self.phase) {
            .impact => {
                if (health > 0) {
                    self.phase = .recovery;
                    self.clearance = if (self.direction == .forward) (if (try environment.at(
                        pose.*,
                        .torso,
                        1,
                    )) @as(u2, 0) else if (try environment.at(
                        pose.*,
                        .torso,
                        2,
                    )) @as(u2, 1) else 2) else (if (try environment.at(
                        pose.*,
                        .torso,
                        0,
                    )) @as(u2, 0) else if (try environment.at(
                        pose.*,
                        .torso,
                        -1,
                    )) @as(u2, 1) else if (try environment.at(
                        pose.*,
                        .torso,
                        -2,
                    )) @as(u2, 2) else 3);
                    return .{};
                }
                self.phase = .fatal_launch;
                if (self.direction == .backward) {
                    self.clearance = if (try environment.at(
                        pose.*,
                        .torso,
                        0,
                    )) 0 else if (try environment.at(
                        pose.*,
                        .torso,
                        -1,
                    )) 1 else 2;
                    return .{ .score = profile.backward_scores[self.clearance] };
                }
                var award: usize = 5;
                if (try environment.at(pose.*, .torso, 1)) {
                    self.clearance = 0;
                    award = 0;
                } else if (try environment.at(pose.*, .torso, 2)) {
                    self.clearance = 1;
                    award = 1;
                } else {
                    self.clearance = 2;
                    if (try environment.at(
                        pose.*,
                        .torso,
                        3,
                    )) award = 2 else if (!try environment.at(
                        pose.*,
                        .support,
                        3,
                    )) award = 3 else if (try environment.ledge(
                        pose.*,
                        .support,
                        3,
                        .behind,
                    )) award = 4 else self.clearance = 3;
                }
                return .{ .score = profile.forward_scores[award] };
            },
            .recovery => return .{
                .damage = true,
                .score = profile.recovery_score,
                .next = if (self.direction == .forward) .turn_in_flight else .fire_in_flight,
            },
            .fatal_launch => {
                const route = self.path(profile);
                if (route.ground == null) return .{ .next = .defeated };
                self.dropped = !try environment.at(pose.*, .support, 0);
                if (self.direction == .forward and
                    self.clearance == 2) self.dropped = self.dropped or
                    try environment.ledge(
                        pose.*,
                        .support,
                        0,
                        .ahead,
                    ) or try environment.ledge(
                    pose.*,
                    .support,
                    0,
                    .behind,
                );
                const landing = (if (self.dropped) route.drop else route.ground).?;
                shift(pose, landing.forward);
                pose.position.y +%= landing.down;
                self.phase = .fatal_landing;
                return .{};
            },
            .fatal_landing => return .{ .next = .defeated },
        }
    }
};
