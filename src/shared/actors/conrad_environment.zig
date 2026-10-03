//! Body-height probes and motion-boundary handoff for Conrad. Geometry owns connectivity;
//! this adapter translates the character's discrete posture bands into clearance queries.
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");

pub const Environment = struct {
    map: geometry.Map,
    room: geometry.RoomId,

    pub fn at(self: *const Environment, pose: motion.Pose, height: enum { head, torso, support }, ahead: i16) !bool {
        const anchor_x = pose.position.x +% 8;
        const column = anchor_x >> 4;
        const band = @divTrunc(pose.position.y, 36) & ~@as(i16, 1);
        const dy: i16 = switch (height) {
            .head => 0,
            .torso => 1,
            .support => 2,
        };
        const dx = if (pose.facing == .left) -%ahead else ahead;
        return self.map.blocked(self.room, column +% dx, band +% dy);
    }

    pub fn motionBoundary(self: *Environment, pose: *motion.Pose) !void {
        _ = try self.map.handoff(&self.room, &pose.position);
    }
};
