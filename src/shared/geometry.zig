//! Room connectivity, blocking cells and coordinate handoff. Rendering and actor behaviors
//! use opaque room IDs; no file offsets, source room numbers or DOS state are exposed here.
const std = @import("std");
const motion = @import("motion.zig");

pub const RoomId = enum(u16) { _ };
pub const Side = enum { left, right, up, down };
pub const Edge = union(enum) { room: RoomId, blocked, unresolved };

pub const Room = struct {
    id: RoomId,
    columns: u16,
    rows: u16,
    blocking: []const bool,
    width: i16,
    height: i16,
    /// Cells in the boundary row overlap the adjoining room's floor band.
    first_interior_row: i16 = 1,
    left_handoff: i16 = -10,
    edges: struct { left: Edge, right: Edge, up: Edge, down: Edge },

    fn edge(self: Room, side: Side) Edge {
        return switch (side) {
            .left => self.edges.left,
            .right => self.edges.right,
            .up => self.edges.up,
            .down => self.edges.down,
        };
    }

    fn validate(self: Room) !void {
        if (self.width <= 0 or self.height <= 0 or self.columns == 0 or self.rows == 0 or
            self.first_interior_row < 0 or self.first_interior_row >= self.rows or
            self.blocking.len != @as(usize, self.columns) * self.rows) return error.InvalidGeometry;
    }
};

pub const Map = struct {
    rooms: []const Room,

    pub fn room(self: Map, id: RoomId) !*const Room {
        for (self.rooms) |*candidate| if (candidate.id == id) return candidate;
        return error.UnknownRoom;
    }

    pub fn blocked(self: Map, id: RoomId, column: i16, row: i16) !bool {
        const origin = try self.room(id);
        try origin.validate();
        var target = origin;
        var x: i32 = column;
        var y: i32 = row;
        var crossing: ?Side = null;
        // Horizontal transitions take precedence at a corner. Resolve only one seam per
        // query; the destination's boundary row remains meaningful after that crossing.
        if (x < 0) {
            crossing = .left;
            x += origin.columns;
        } else if (x >= origin.columns) {
            crossing = .right;
            x -= origin.columns;
        } else if (y < origin.first_interior_row) {
            crossing = .up;
            y += @as(i32, origin.rows) - origin.first_interior_row;
        } else if (y >= origin.rows) {
            crossing = .down;
            y -= @as(i32, origin.rows) - origin.first_interior_row;
        }
        if (crossing) |side| switch (origin.edge(side)) {
            .room => |neighbor| target = try self.room(neighbor),
            .blocked => return true,
            .unresolved => return error.UnresolvedBoundary,
        };
        try target.validate();
        if (x < 0 or y < 0 or x >= target.columns or y >= target.rows) return error.QueryOutsideConnectedGrid;
        const index = @as(usize, @intCast(y)) * target.columns + @as(usize, @intCast(x));
        if (index >= target.blocking.len) return error.InvalidGeometry;
        return target.blocking[index];
    }

    /// Actor handoff is requested by the motion system at a transition, not after every
    /// pixel displacement. The room definition supplies the asymmetric left threshold.
    pub fn handoff(self: Map, id: *RoomId, position: *motion.Position) !bool {
        const origin = try self.room(id.*);
        try origin.validate();
        var delta: motion.Position = .{ .x = 0, .y = 0 };
        const side: Side = if (position.x <= origin.left_handoff) blk: {
            delta.x = origin.width;
            break :blk .left;
        } else if (position.x >= origin.width) blk: {
            delta.x = -origin.width;
            break :blk .right;
        } else if (position.y < 0) blk: {
            delta.y = origin.height;
            break :blk .up;
        } else if (position.y >= origin.height) blk: {
            delta.y = -origin.height;
            break :blk .down;
        } else return false;
        const next = switch (origin.edge(side)) {
            .room => |neighbor| neighbor,
            else => return error.ExitWithoutDestination,
        };
        _ = try self.room(next);
        id.* = next;
        position.x +%= delta.x;
        position.y +%= delta.y;
        return true;
    }
};

test "room seams retain boundary rows and handoff uses its explicit overlap" {
    const first: RoomId = @fromBackingInt(90);
    const second: RoomId = @fromBackingInt(200);
    const empty = [_]bool{ false, false, false, false, false, false };
    const occupied = [_]bool{ true, false, false, false, false, true };
    const rooms = [_]Room{
        .{ .id = first, .columns = 2, .rows = 3, .blocking = &empty, .width = 32, .height = 72, .edges = .{ .left = .{ .room = second }, .right = .unresolved, .up = .blocked, .down = .blocked } },
        .{ .id = second, .columns = 2, .rows = 3, .blocking = &occupied, .width = 32, .height = 72, .edges = .{ .left = .blocked, .right = .{ .room = first }, .up = .blocked, .down = .blocked } },
    };
    const map: Map = .{ .rooms = &rooms };
    try std.testing.expect(try map.blocked(first, -2, 0));
    try std.testing.expect(!try map.blocked(first, -1, 0));
    try std.testing.expect(try map.blocked(first, 0, 0));
    try std.testing.expectError(error.UnresolvedBoundary, map.blocked(first, 2, 1));
    var id = first;
    var position: motion.Position = .{ .x = -9, .y = 20 };
    try std.testing.expect(!try map.handoff(&id, &position));
    position.x = -10;
    try std.testing.expect(try map.handoff(&id, &position));
    try std.testing.expectEqual(second, id);
    try std.testing.expectEqual(@as(i16, 22), position.x);
}
