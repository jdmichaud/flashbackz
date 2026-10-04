//! Body-height probes and motion-boundary handoff for Conrad. Geometry owns connectivity;
//! this adapter translates the character's discrete posture bands into clearance queries.
const geometry = @import("../geometry.zig");
const terrain = @import("../terrain.zig");
const motion = @import("../motion.zig");
pub const Height = enum { above_head, head, torso, support };

pub const Environment = struct {
    map: geometry.Map,
    room: geometry.RoomId,
    materials: ?terrain.View = null,

    fn gridPoint(pose: motion.Pose, height: Height, ahead: i16) struct { column: i16, row: i16 } {
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
        return .{ .column = column +% dx, .row = band +% dy };
    }

    pub fn at(self: *const Environment, pose: motion.Pose, height: Height, ahead: i16) !bool {
        const point = gridPoint(pose, height, ahead);
        return self.map.blocked(self.room, point.column, point.row);
    }

    pub fn rollPassage(self: *const Environment, pose: motion.Pose, ahead: i16) !bool {
        const materials = self.materials orelse return false;
        const point = gridPoint(pose, .torso, ahead);
        return try materials.sample(self.room, point.column, point.row) == .restricted;
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

test "changing a gate material changes rolling clearance without losing standing collision" {
    const std = @import("std");
    const id: geometry.RoomId = @fromBackingInt(41);
    const empty: [18]bool = @splat(false);
    const cells: [18]terrain.Material = @splat(.empty);
    const rooms = [_]geometry.Room{.{ .id = id, .columns = 6, .rows = 3, .blocking = &empty, .width = 96, .height = 72, .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked } }};
    var state = try terrain.State.init(std.testing.allocator, .{ .rooms = &rooms }, &cells, .{});
    defer state.deinit();
    const environment: Environment = .{ .map = state.map(), .materials = state.view(), .room = id };
    const pose: motion.Pose = .{ .position = .{ .x = 24, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
    const gate: terrain.Span = .{ .origin = .{ .room = id, .column = 2, .row = 1 }, .length = 1 };
    _ = try state.replace(gate, .solid);
    try std.testing.expect(try environment.at(pose, .torso, 0));
    try std.testing.expect(!try environment.rollPassage(pose, 0));
    _ = try state.replace(gate, .restricted);
    try std.testing.expect(try environment.at(pose, .torso, 0));
    try std.testing.expect(try environment.rollPassage(pose, 0));
    _ = try state.restore(gate.origin);
    try std.testing.expect(!try environment.at(pose, .torso, 0));
    try std.testing.expect(!try environment.rollPassage(pose, 0));
}
