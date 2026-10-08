//! Shared awareness queries. Player detection uses posture bands and distance; loose
//! objects use the contact grid and are occluded by terrain. These are distinct senses.
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const contacts = @import("../contacts.zig");
const combat = @import("../combat.zig");
const std = @import("std");

pub const PostureSense = struct {
    category: combat.Category,
    same_facing: bool,
    impact: combat.Impact,
};

/// Detect an exposed posture that cannot receive the selected kind of shot. Gunmen use
/// this to lower their aim; this is a visibility query, not prediction of moving bullets.
pub fn unhittableTarget(
    map: geometry.Map,
    observer: Observer,
    self_id: combat.Id,
    range: i16,
    targets: []const combat.Target,
    senses: []const ?PostureSense,
) !bool {
    const band = @divTrunc(observer.pose.position.y, 72);
    if (band < 0 or band > 2) return false;
    const direction: i16 = if ((observer.pose.facing == .right) == (range > 0)) 1 else -1;
    var column = (observer.pose.position.x +% 8) >> 4;
    var room = observer.room;
    const layout: contacts.Layout = .{};
    for (0..@as(usize, @abs(range)) + 1) |_| {
        const cell = try map.locate(room, column, band * 2 + 1) orelse return false;
        for (targets) |target| {
            if (target.id == self_id or !target.active) continue;
            var selected = false;
            for (senses) |optional| if (optional) |sense| {
                if (target.category == sense.category and
                    ((target.facing == observer.pose.facing) == sense.same_facing) and
                    !target.vulnerable.accepts(sense.impact)) selected = true;
            };
            if (!selected) continue;
            for (0..target.footprint.width) |offset| {
                const contact = try layout.cell(
                    map,
                    target.footprint.room,
                    .{
                        .x = target.footprint.position.x +% @as(i16, @intCast(offset)) *% 16,
                        .y = target.footprint.position.y,
                    },
                ) orelse continue;
                if (contact.room == cell.room and
                    contact.column == cell.column and
                    contact.row == band) return true;
            }
        }
        if (try map.blocked(room, column, band * 2 + 1)) return false;
        room = cell.room;
        column = @as(i16, @intCast(cell.column)) +% direction;
    }
    return false;
}

pub const Observer = struct { room: geometry.RoomId, pose: motion.Pose };
pub const Awareness = struct {
    player_front: ?i16 = null,
    player_behind: ?i16 = null,
    player_front_neighbor: bool = false,
    player_behind_neighbor: bool = false,
    object_front: ?u8 = null,
    object_behind: ?u8 = null,

    pub fn player(self: Awareness, behind: bool, distance: ?i16) bool {
        const limit = distance orelse return false;
        if (limit == 0 and
            (if (behind) self.player_behind_neighbor else self.player_front_neighbor)) return true;
        const actual = (if (behind) self.player_behind else self.player_front) orelse return false;
        return limit == 0 or (actual > 0 and actual < limit);
    }
    pub fn object(self: Awareness, behind: bool, cells: ?u8) bool {
        const limit = cells orelse return false;
        const actual = (if (behind) self.object_behind else self.object_front) orelse return false;
        return actual <= limit;
    }
};

pub fn observe(
    map: geometry.Map,
    observer: Observer,
    player: contacts.Footprint,
    objects: []const contacts.Footprint,
) !Awareness {
    var result: Awareness = .{};
    if (observer.room == player.room and
        @divTrunc(observer.pose.position.y, 72) == @divTrunc(player.position.y -% 8, 72))
    {
        var distance = player.position.x -% observer.pose.position.x;
        if (observer.pose.facing == .left) distance = -%distance;
        // The unlimited rear query includes equal X only for a left-facing observer.
        if (distance > 0) result.player_front = distance else if (distance < 0) result.player_behind = -%distance else if (observer.pose.facing == .left) result.player_behind = 0;
    } else if (@divTrunc(observer.pose.position.y, 72) == @divTrunc(player.position.y -% 8, 72)) {
        const origin = try map.room(observer.room);
        const ahead = if (observer.pose.facing == .left) origin.edges.left else origin.edges.right;
        const behind = if (observer.pose.facing == .left) origin.edges.right else origin.edges.left;
        result.player_front_neighbor = ahead == .room and ahead.room == player.room;
        result.player_behind_neighbor = behind == .room and behind.room == player.room;
    }
    const room = try map.room(player.room);
    if (observer.room != player.room and
        !(room.edges.left == .room and room.edges.left.room == observer.room) and
        !(room.edges.right == .room and room.edges.right.room == observer.room)) return result;
    result.object_front = try scanObjects(map, player.room, observer, objects, false);
    result.object_behind = try scanObjects(map, player.room, observer, objects, true);
    return result;
}

/// Search the contact view shared by the current room and its horizontal neighbors.
/// Contact lookup and terrain lookup have different offsets in the original game.
/// Keep their cursors explicit, including contact-row spill at a room seam.
pub fn scanObjects(
    map: geometry.Map,
    view_room: geometry.RoomId,
    observer: Observer,
    objects: []const contacts.Footprint,
    behind: bool,
) !?u8 {
    if (objects.len == 0) return null;
    const view = try map.room(view_room);
    const rooms = [_]?geometry.RoomId{
        if (view.edges.left == .room) view.edges.left.room else null,
        view_room,
        if (view.edges.right == .room) view.edges.right.room else null,
    };
    var slot: i16 = if (observer.room == view_room) 1 else if (rooms[0] != null and
        rooms[0].? == observer.room) 0 else if (rooms[2] != null and
        rooms[2].? == observer.room) 2 else return null;
    const origin = try map.room(observer.room);
    const columns = @divTrunc(origin.width, 16);
    const bands = @divTrunc(origin.height, 72);
    const cells_per_room = columns * bands;
    const left = (observer.pose.facing == .left) != behind;
    var column = (observer.pose.position.x +% 8) >> 4;
    const band = @divTrunc(observer.pose.position.y, 72);
    if (band < 0 or band >= bands or cells_per_room <= 0) return null;
    var terrain_room = observer.room;
    var contact_index = slot * cells_per_room + band * columns + column + @as(i16, if (left) 0 else 1);
    const layout: contacts.Layout = .{};
    for (1..17) |step| {
        column += if (left) @as(i16, -1) else 1;
        if (column < 0) {
            slot -= 1;
            if (slot < 0) return null;
            column += columns;
            const edge = (try map.room(terrain_room)).edges.left;
            terrain_room = if (edge == .room) edge.room else return null;
            contact_index -= 2 * columns - 1;
        } else if (column >= columns) {
            slot += 1;
            if (slot >= rooms.len) return null;
            column -= columns;
            const edge = (try map.room(terrain_room)).edges.right;
            terrain_room = if (edge == .room) edge.room else return null;
            contact_index += 2 * columns;
        }
        contact_index += if (left) @as(i16, -1) else 1;
        if (contact_index >= 0 and contact_index < cells_per_room * @as(i16, rooms.len)) {
            const contact_slot: usize = @intCast(@divTrunc(contact_index, cells_per_room));
            const local = @mod(contact_index, cells_per_room);
            if (rooms[contact_slot]) |room| for (objects) |object| for (0..object.width) |offset| {
                const cell = try layout.cell(
                    map,
                    object.room,
                    .{
                        .x = object.position.x +% @as(i16, @intCast(offset)) *% 16,
                        .y = object.position.y,
                    },
                ) orelse continue;
                if (cell.room == room and
                    cell.column == @mod(local, columns) and
                    cell.row == @divTrunc(local, columns)) return @intCast(step);
            };
        }
        if (try map.blocked(terrain_room, column, band * 2 + 1)) return null;
    }
    return null;
}

test "loose-item search retains the full range and tests the visited terrain cell" {
    const room: geometry.RoomId = @fromBackingInt(17);
    var blocking: [16 * 7]bool = @splat(false);
    const rooms = [_]geometry.Room{.{
        .id = room,
        .width = 256,
        .height = 216,
        .columns = 16,
        .rows = 7,
        .blocking = &blocking,
        .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked },
    }};
    const map: geometry.Map = .{ .rooms = &rooms };
    const observer: Observer = .{
        .room = room,
        .pose = .{
            .position = .{ .x = 224, .y = 214 },
            .facing = .left,
            .visual = .{ .id = @fromBackingInt(0) },
        },
    };
    var objects = [_]contacts.Footprint{.{ .room = room, .position = .{ .x = 64, .y = 214 } }};
    try std.testing.expectEqual(
        @as(?u8, 10),
        try scanObjects(map, room, observer, &objects, false),
    );
    blocking[5 * 16 + 8] = true;
    try std.testing.expect((try scanObjects(map, room, observer, &objects, false)) == null);
    blocking[5 * 16 + 8] = false;
    var right = observer;
    right.pose.position.x = 32;
    right.pose.facing = .right;
    objects[0].position.x = 80;
    blocking[5 * 16 + 2] = true; // The origin cell is behind the ray, so it does not obstruct it.
    try std.testing.expectEqual(@as(?u8, 2), try scanObjects(map, room, right, &objects, false));
    blocking[5 * 16 + 3] = true;
    try std.testing.expect((try scanObjects(map, room, right, &objects, false)) == null);
}
