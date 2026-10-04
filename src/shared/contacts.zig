//! Room-local contact bands for actors and props. A footprint is a horizontal sequence
//! of contact cells; world ownership and filtering are handled by interaction systems.
const geometry = @import("geometry.zig");
const motion = @import("motion.zig");
pub const Cell = struct { room: geometry.RoomId, column: u16, row: u16 };
pub const Footprint = struct { room: geometry.RoomId, position: motion.Position, width: u8 = 1 };
pub const Kind = enum { player, enemy, item, mechanism };
pub const Participant = struct { footprint: Footprint, kind: Kind, active: bool };
pub const Layout = struct {
    column_pixels: i16 = 16,
    tier_pixels: i16 = 72,
    x_inset: i16 = 8,
    y_inset: i16 = 8,
    pub fn cell(self: Layout, map: geometry.Map, room_id: geometry.RoomId, position: motion.Position) !?Cell {
        if (self.column_pixels <= 0 or self.tier_pixels <= 0) return error.InvalidContactLayout;
        const origin = try map.room(room_id);
        var x = position.x;
        var y = position.y;
        var room = origin;
        const edge: ?geometry.Edge = if (x < 0) blk: {
            x +%= origin.width;
            break :blk origin.edges.left;
        } else if (x >= origin.width) blk: {
            x -%= origin.width;
            break :blk origin.edges.right;
        } else if (y < 0) blk: {
            y +%= origin.height;
            break :blk origin.edges.up;
        } else if (y >= origin.height) blk: {
            y -%= origin.height;
            break :blk origin.edges.down;
        } else null;
        if (edge) |next| switch (next) {
            .room => |id| room = try map.room(id),
            else => return null,
        };
        const column = @divFloor(x +% self.x_inset, self.column_pixels);
        const row = @divTrunc(y -% self.y_inset, self.tier_pixels);
        if (column >= @divTrunc(room.width, self.column_pixels) or row < 0 or row >= @divTrunc(room.height, self.tier_pixels)) return null;
        // The DOS routine has an unsigned lower-bound test, so coordinates beyond one
        // leftward seam can alias unrelated contact spaces. Do not silently discard them.
        if (column < 0) return error.UnverifiedNegativeContactColumn;
        return .{ .room = room.id, .column = @intCast(column), .row = @intCast(row) };
    }
    pub fn overlaps(self: Layout, map: geometry.Map, a: Footprint, b: Footprint) !bool {
        var i: u16 = 0;
        while (i < a.width) : (i += 1) {
            const first = try self.cell(map, a.room, .{ .x = a.position.x +% @as(i16, @intCast(i)) *% self.column_pixels, .y = a.position.y }) orelse break;
            var j: u16 = 0;
            while (j < b.width) : (j += 1) {
                const second = try self.cell(map, b.room, .{ .x = b.position.x +% @as(i16, @intCast(j)) *% self.column_pixels, .y = b.position.y }) orelse break;
                if (first.room == second.room and first.column == second.column and first.row == second.row) return true;
            }
        }
        return false;
    }
};

test "contact bands resolve one seam before quantization and stop a clipped footprint" {
    const std = @import("std");
    const empty: [12]bool = @splat(false);
    const first: geometry.RoomId = @fromBackingInt(31);
    const next: geometry.RoomId = @fromBackingInt(70);
    const rooms = [_]geometry.Room{
        .{ .id = first, .columns = 4, .rows = 3, .width = 64, .height = 144, .blocking = &empty, .edges = .{ .left = .blocked, .right = .{ .room = next }, .up = .blocked, .down = .blocked } },
        .{ .id = next, .columns = 4, .rows = 3, .width = 64, .height = 144, .blocking = &empty, .edges = .{ .left = .{ .room = first }, .right = .blocked, .up = .blocked, .down = .blocked } },
    };
    const map: geometry.Map = .{ .rooms = &rooms };
    const layout: Layout = .{};
    try std.testing.expectEqualDeep(@as(?Cell, .{ .room = next, .column = 0, .row = 0 }), try layout.cell(map, first, .{ .x = 64, .y = 0 }));
    try std.testing.expect((try layout.cell(map, first, .{ .x = 60, .y = 70 })) == null);
    try std.testing.expect(try layout.overlaps(map, .{ .room = first, .position = .{ .x = 48, .y = 70 }, .width = 2 }, .{ .room = next, .position = .{ .x = 0, .y = 70 } }));
    try std.testing.expect(!try layout.overlaps(map, .{ .room = first, .position = .{ .x = 60, .y = 70 }, .width = 2 }, .{ .room = next, .position = .{ .x = 12, .y = 70 } }));
    try std.testing.expect(!try layout.overlaps(map, .{ .room = first, .position = .{ .x = 32, .y = 79 } }, .{ .room = first, .position = .{ .x = 32, .y = 80 } }));
}
