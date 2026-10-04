//! Shared awareness queries. Player detection uses posture bands and distance; loose
//! objects use the contact grid and are occluded by terrain. These are distinct senses.
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const contacts = @import("../contacts.zig");

pub const Observer = struct { room: geometry.RoomId, pose: motion.Pose };
pub const Awareness = struct {
    player_front: ?i16 = null,
    player_behind: ?i16 = null,
    object_front: ?u8 = null,
    object_behind: ?u8 = null,

    pub fn player(self: Awareness, behind: bool, distance: ?i16) bool {
        const limit = distance orelse return false;
        const actual = (if (behind) self.player_behind else self.player_front) orelse return false;
        return limit == 0 or actual < limit;
    }
    pub fn object(self: Awareness, behind: bool, cells: ?u8) bool {
        const limit = cells orelse return false;
        const actual = (if (behind) self.object_behind else self.object_front) orelse return false;
        return actual <= limit;
    }
};

pub fn observe(map: geometry.Map, observer: Observer, player: contacts.Footprint, objects: []const contacts.Footprint) !Awareness {
    var result: Awareness = .{};
    if (observer.room == player.room and @divTrunc(observer.pose.position.y, 72) == @divTrunc(player.position.y -% 8, 72)) {
        var distance = player.position.x -% observer.pose.position.x;
        if (observer.pose.facing == .left) distance = -%distance;
        if (distance > 0) result.player_front = distance else if (distance < 0) result.player_behind = -%distance;
    }
    const room = try map.room(player.room);
    if (observer.room != player.room and !(room.edges.left == .room and room.edges.left.room == observer.room) and !(room.edges.right == .room and room.edges.right.room == observer.room)) return result;
    result.object_front = try scanObjects(map, observer, objects, false);
    result.object_behind = try scanObjects(map, observer, objects, true);
    return result;
}

fn scanObjects(map: geometry.Map, observer: Observer, objects: []const contacts.Footprint, behind: bool) !?u8 {
    if (objects.len == 0) return null;
    const left = (observer.pose.facing == .left) != behind;
    const column = (observer.pose.position.x +% 8) >> 4;
    const band = @divTrunc(observer.pose.position.y, 72);
    if (band < 0 or band > 2) return null;
    const layout: contacts.Layout = .{};
    // The original's contact scan is offset one extra cell when looking right. The
    // wall sample remains at the nearer cell. Keep this quirk in one spatial query.
    for (1..10) |step| {
        const stride: i16 = @intCast(step);
        const terrain_column = column + (if (left) -stride else stride - 1);
        const contact_column = column + (if (left) -stride else stride + 1);
        const location = try map.locate(observer.room, contact_column, band * 2 + 1) orelse return null;
        for (objects) |object| for (0..object.width) |offset| {
            const cell = try layout.cell(map, object.room, .{ .x = object.position.x +% @as(i16, @intCast(offset)) *% 16, .y = object.position.y }) orelse continue;
            if (cell.room == location.room and cell.column == location.column and cell.row == band) return @intCast(step);
        };
        if (try map.blocked(observer.room, terrain_column, band * 2 + 1)) return null;
    }
    return null;
}
