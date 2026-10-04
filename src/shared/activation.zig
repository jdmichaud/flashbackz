//! Shared room-neighborhood policy for world actors and mechanisms.
const geometry = @import("geometry.zig");
pub const Neighborhood = struct { same: bool, near: bool, wake: bool };
pub fn around(map: geometry.Map, player: geometry.RoomId, entity: geometry.RoomId, y: i16) !Neighborhood {
    const room = try map.room(player);
    const same = player == entity;
    var near = same;
    for ([_]geometry.Edge{ room.edges.left, room.edges.right, room.edges.up, room.edges.down }) |edge| if (edge == .room and edge.room == entity) {
        near = true;
    };
    const above = room.edges.up == .room and room.edges.up.room == entity and y >= 48;
    const below = room.edges.down == .room and room.edges.down.room == entity and y >= 176;
    return .{ .same = same, .near = near, .wake = same or above or below };
}
