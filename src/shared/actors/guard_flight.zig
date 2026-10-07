//! Powered movement over platforms: takeoff, vertical search, drift and landing.
//! The guard's decisions start a flight; this component owns its motion boundaries.
const motion = @import("../motion.zig");
const Environment = @import("conrad_environment.zig").Environment;
const shift = @import("conrad_roll.zig").shiftForward;
pub const Kind = enum { across, ascend, descend };
pub const Phase = enum { starting, thrust, aligning, landing, braking, drifting, rising, turning_exit, dropping, seeking_height, turning, turn_confirmed, rising_to_ledge, drifting_to_ledge };
pub const Profile = struct {
    starts: [3]motion.Clip,
    thrusts: [3]motion.Clip,
    alignments: [3]motion.Clip,
    landing: motion.Clip,
    braking: motion.Clip,
    drifting: motion.Clip,
    rising: motion.Clip,
    turning_exit: motion.Clip,
    dropping: motion.Clip,
    seeking_height: motion.Clip,
    turning: motion.Clip,
    turn_confirmed: motion.Clip,
    rising_to_ledge: motion.Clip,
    drifting_to_ledge: motion.Clip,
    search_distances: [3]i16,
    landing_advance: i16,
};
pub const Outcome = enum { continued, grounded, fire };
pub const State = struct {
    kind: Kind = .across,
    phase: Phase = .starting,

    pub fn clip(self: State, profile: Profile) motion.Clip {
        return switch (self.phase) {
            .starting => profile.starts[@backingInt(self.kind)],
            .thrust => profile.thrusts[@backingInt(self.kind)],
            .aligning => profile.alignments[@backingInt(self.kind)],
            .landing => profile.landing,
            .braking => profile.braking,
            .drifting => profile.drifting,
            .rising => profile.rising,
            .turning_exit => profile.turning_exit,
            .dropping => profile.dropping,
            .seeking_height => profile.seeking_height,
            .turning => profile.turning,
            .turn_confirmed => profile.turn_confirmed,
            .rising_to_ledge => profile.rising_to_ledge,
            .drifting_to_ledge => profile.drifting_to_ledge,
        };
    }
    fn turn(pose: *motion.Pose) void {
        pose.facing = if (pose.facing == .left) .right else .left;
    }
    fn land(self: *State, profile: Profile, pose: *motion.Pose) void {
        shift(pose, profile.landing_advance);
        self.phase = .landing;
    }
    fn ledgeBelow(environment: Environment, pose: motion.Pose) !bool {
        return try environment.ledge(pose, .support, 0, .behind) or try environment.ledge(pose, .support, 1, .behind);
    }
    pub fn finish(self: *State, profile: Profile, pose: *motion.Pose, environment: Environment, player_behind: bool, player_close_behind: bool) !Outcome {
        switch (self.phase) {
            .starting => self.phase = .thrust,
            .thrust => switch (self.kind) {
                .across, .descend => self.phase = .aligning,
                .ascend => self.phase = if (try environment.ledge(pose.*, .head, 1, .behind)) .rising_to_ledge else .aligning,
            },
            .aligning => switch (self.kind) {
                .across => if (!try environment.at(pose.*, .support, 1)) {
                    self.phase = .drifting;
                } else self.land(profile, pose),
                .ascend => self.phase = .rising,
                .descend => self.phase = .dropping,
            },
            .landing => self.phase = if (!try environment.at(pose.*, .support, 0) and try environment.at(pose.*, .lower_support, 0)) .dropping else .braking,
            .braking => return .grounded,
            .drifting => {
                const unsupported = !try environment.at(pose.*, .support, 0);
                if ((unsupported and try environment.at(pose.*, .lower_support, 0)) or (!unsupported and try ledgeBelow(environment, pose.*))) self.land(profile, pose);
            },
            .rising => self.phase = .turning_exit,
            .turning_exit => {
                turn(pose);
                self.phase = .braking;
            },
            .dropping => self.phase = if (!try environment.at(pose.*, .support, 0) or (try environment.at(pose.*, .torso, 0) and !try environment.at(pose.*, .support, -1))) .seeking_height else .braking,
            .seeking_height => {
                self.phase = .turning;
                if (!player_behind) for (profile.search_distances) |distance| {
                    if (try environment.at(pose.*, .torso, distance)) break;
                    if (try environment.at(pose.*, .support, distance)) {
                        self.phase = .drifting_to_ledge;
                        break;
                    }
                };
            },
            .turning => {
                if (player_close_behind) {
                    turn(pose);
                    return .fire;
                }
                if (try environment.at(pose.*, .support, -1) and try environment.at(pose.*, .support, 0)) {
                    turn(pose);
                    self.land(profile, pose);
                } else {
                    self.phase = .turn_confirmed;
                    for (profile.search_distances) |distance| {
                        if (try environment.at(pose.*, .torso, -distance)) break;
                        if (try environment.at(pose.*, .support, -distance)) {
                            self.phase = .drifting_to_ledge;
                            break;
                        }
                    }
                    turn(pose);
                }
            },
            .turn_confirmed => {
                turn(pose);
                self.phase = .rising;
            },
            .rising_to_ledge => {
                turn(pose);
                self.phase = .turning_exit;
            },
            .drifting_to_ledge => {
                if (try ledgeBelow(environment, pose.*)) self.land(profile, pose) else self.phase = .drifting;
            },
        }
        return .continued;
    }
};
