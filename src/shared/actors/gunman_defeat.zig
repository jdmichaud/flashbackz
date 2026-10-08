//! Directional knockdown with authored clearance variants. Terrain chooses a short
//! collision trajectory or an unobstructed fall; the settled body remains world artwork.
const motion = @import("../motion.zig");
const Environment = conrad_environment.Environment;
const shift = conrad_roll.shiftForward;
const conrad_environment = @import("conrad_environment.zig");
const conrad_roll = @import("conrad_roll.zig");
pub const Move = struct {
    clip: motion.Clip,
    forward: i16 = 0,
    down: i16 = 0,
    fn apply(self: Move, pose: *motion.Pose) void {
        shift(pose, self.forward);
        pose.position.y +%= self.down;
    }
};
pub const Path = struct { launch: Move, landing: Move, drop: Move };
pub const Track = struct {
    notify_on_landing: bool = false,
    notify_on_fall_landing: bool = false,
    notify_while_resting: bool = false,
    remove_offscreen: bool = false,
    impact: motion.Clip,
    paths: [5]Path,
    ledge_launch: ?Move = null,
    ledge_landing: ?Move = null,
    fall: Move,
    ledge_fall: ?Move = null,
    fall_landing: Move,
    rest: motion.Clip,
    mark_dead: bool,
};
pub const Definition = struct { backward: Track, forward: Track };
pub const Direction = enum { backward, forward };
pub const Phase = enum { impact, airborne, landing, falling, fall_landing, resting };
pub const State = struct {
    direction: Direction,
    phase: Phase = .impact,
    clearance: u3 = 4,

    pub fn track(self: State, definition: Definition) Track {
        return if (self.direction == .backward) definition.backward else definition.forward;
    }
    pub fn clip(self: State, definition: Definition) motion.Clip {
        const t = self.track(definition);
        return switch (self.phase) {
            .impact => t.impact,
            .airborne => t.paths[self.clearance].launch.clip,
            .landing => t.paths[self.clearance].landing.clip,
            .falling => t.fall.clip,
            .fall_landing => t.fall_landing.clip,
            .resting => t.rest,
        };
    }
    pub fn advance(
        self: *State,
        definition: Definition,
        pose: *motion.Pose,
        environment: Environment,
    ) !void {
        const t = self.track(definition);
        const backward = self.direction == .backward;
        switch (self.phase) {
            .impact => {
                self.clearance = 4;
                for (0..4) |cells| {
                    const ahead: i16 = @intCast(cells);
                    if (try environment.at(pose.*, .torso, if (backward) -ahead else ahead)) {
                        self.clearance = @intCast(cells);
                        break;
                    }
                }
                var launch = t.paths[self.clearance].launch;
                if (!backward and self.clearance == 4 and try environment.ledge(
                    pose.*,
                    .support,
                    -3,
                    .ahead,
                )) launch = t.ledge_launch orelse launch;
                launch.apply(pose);
                self.phase = .airborne;
            },
            .airborne => {
                const path = t.paths[self.clearance];
                if (backward and self.clearance == 4 and try environment.ledge(
                    pose.*,
                    .support,
                    0,
                    .ahead,
                )) {
                    (t.ledge_landing orelse path.landing).apply(pose);
                    self.phase = .landing;
                    return;
                }
                const unsupported = if (backward) !try environment.at(
                    pose.*,
                    .support,
                    1,
                ) else !try environment.at(pose.*, .support, 0);
                const free_drop = self.clearance == 4 and (if (backward) (!try environment.at(
                    pose.*,
                    .support,
                    0,
                ) or try environment.ledge(
                    pose.*,
                    .support,
                    0,
                    .behind,
                )) else try environment.ledge(pose.*, .support, 0, .ahead));
                if (unsupported or free_drop) {
                    path.drop.apply(pose);
                    self.phase = .falling;
                } else {
                    const landing = if (backward and self.clearance == 4 and try environment.ledge(
                        pose.*,
                        .support,
                        -1,
                        .behind,
                    )) t.ledge_landing orelse path.landing else path.landing;
                    landing.apply(pose);
                    self.phase = .landing;
                }
            },
            .falling => {
                if (!backward and try environment.ledge(pose.*, .support, 0, .ahead)) {
                    (t.ledge_fall orelse t.fall).apply(pose);
                } else if (!try environment.at(
                    pose.*,
                    .support,
                    0,
                ) or (backward and !try environment.at(pose.*, .support, 1))) {
                    t.fall.apply(pose);
                } else {
                    t.fall_landing.apply(pose);
                    self.phase = .fall_landing;
                }
            },
            .landing, .fall_landing => self.phase = .resting,
            .resting => {},
        }
    }
};
