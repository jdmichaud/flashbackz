//! Committed long falls. Animation supplies motion within a phase; terrain determines
//! continued descent or a fatal landing. Health and scene transitions belong to the session.
const motion = @import("../motion.zig");
const controls = @import("controls.zig");
pub const Phase = enum { initial, continuing };
pub const Clips = struct {
    initial: motion.Clip,
    continuing: motion.Clip,
    landing: motion.Clip,
    resting: motion.Clip,
    descent_down: i16 = 40,
    landing_down: i16 = 16,
    death_wait_steps: u16 = 30,
};
pub const Boundary = enum { continued, fatal_landing, catch_ledge };
pub const State = struct {
    phase: Phase = .initial,
    already_dead: bool = false,
    pub fn clip(self: State, clips: Clips) motion.Clip {
        return if (self.phase == .initial) clips.initial else clips.continuing;
    }
    pub fn finishPhase(
        self: *State,
        clips: Clips,
        intent: controls.Intent,
        pose: *motion.Pose,
        environment: anytype,
    ) !Boundary {
        if (self.already_dead) {
            if (!try environment.ledge(pose.*, .support, 0, .behind) and
                try environment.at(pose.*, .support, 0))
            {
                pose.facing = if (pose.facing == .right) .left else .right;
                pose.position.y +%= clips.landing_down;
                return .fatal_landing;
            }
            pose.position.y +%= clips.descent_down;
            self.phase = .continuing;
            return .continued;
        }
        if (intent.action) {
            if (try environment.ledge(pose.*, .support, 1, .behind)) {
                pose.position.y +%= 32;
                return .catch_ledge;
            }
            if (try environment.ledge(pose.*, .support, 0, .behind)) {
                pose.position.x +%= if (pose.facing == .left) @as(i16, 16) else -16;
                pose.position.y +%= 32;
                return .catch_ledge;
            }
        }
        // A full landing needs support across the backward footprint. Partial support
        // keeps the descent committed, regardless of the material at torso height.
        if (!try environment.at(pose.*, .support, 0) or !try environment.at(pose.*, .support, -1)) {
            pose.position.y +%= clips.descent_down;
            self.phase = .continuing;
            return .continued;
        }
        pose.facing = if (pose.facing == .right) .left else .right;
        pose.position.y +%= clips.landing_down;
        return .fatal_landing;
    }
};
