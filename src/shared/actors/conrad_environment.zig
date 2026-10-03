//! Body-height probes and motion-boundary handoff for Conrad. Geometry owns connectivity;
//! this adapter translates the character's discrete posture bands into clearance queries.
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
pub const Height = enum { above_head, head, torso, support };

pub const Environment = struct {
    map: geometry.Map,
    room: geometry.RoomId,

    pub fn at(self: *const Environment, pose: motion.Pose, height: Height, ahead: i16) !bool {
        const anchor_x = pose.position.x +% 8;
        const column = anchor_x >> 4;
        const band = @divTrunc(pose.position.y, 36) & ~@as(i16, 1);
        const dy: i16 = switch (height) {
            .above_head => -1,
            .head => 0,
            .torso => 1,
            .support => 2,
        };
        const dx = if (pose.facing == .left) -%ahead else ahead;
        return self.map.blocked(self.room, column +% dx, band +% dy);
    }

    pub fn ledge(self: *const Environment, pose: motion.Pose, height: enum { head, support }, ahead: i16, open_side: enum { ahead, behind }) !bool {
        const level: Height = if (height == .head) .head else .support;
        const above: Height = if (height == .head) .above_head else .torso;
        const neighbor = ahead +% (if (open_side == .ahead) @as(i16, 1) else -1);
        return try self.at(pose, level, ahead) and !try self.at(pose, level, neighbor) and !try self.at(pose, above, ahead);
    }

    pub fn motionBoundary(self: *Environment, pose: *motion.Pose) !void {
        _ = try self.map.handoff(&self.room, &pose.position);
    }
};
