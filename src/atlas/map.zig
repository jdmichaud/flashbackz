//! A level's rooms on a flat map. The rooms' links (the collision grid's neighbor tables) place
//! them on a grid of room cells from the start room. The game's rooms do not always lie flat: a
//! link may lead to a room whose cell another link has taken (the tower's floors wrap around),
//! and some areas are reached only by a transport. Those links and transports are the map's
//! joins; the poster tags both ends of each.
const std = @import("std");
const flashbackz = @import("flashbackz");
const grid = flashbackz.behavior.grid;
const data_set = flashbackz.behavior.data_set;
const vocabulary = flashbackz.behavior.vocabulary;

pub const room_count = 64;
pub const RoomSet = std.StaticBitSet(room_count);
pub const Side = grid.Side;

/// The order links are followed in: across before up and down.
const walk_order = [_]Side{ .right, .left, .down, .up };

pub fn step(side: Side) struct { x: i16, y: i16 } {
    return switch (side) {
        .up => .{ .x = 0, .y = -1 },
        .down => .{ .x = 0, .y = 1 },
        .right => .{ .x = 1, .y = 0 },
        .left => .{ .x = -1, .y = 0 },
    };
}

pub fn opposite(side: Side) Side {
    return switch (side) {
        .up => .down,
        .down => .up,
        .right => .left,
        .left => .right,
    };
}

/// The rooms a level's files have, and each one's neighbor on each side (by `Side`).
pub const Links = struct {
    present: RoomSet,
    neighbors: [room_count][4]?u8,

    pub fn fromGrid(collision: *const grid.Grid, present: RoomSet) Links {
        var links: Links = .{ .present = present, .neighbors = @splat(@splat(null)) };
        var rooms = present.iterator(.{});
        while (rooms.next()) |room| {
            for (std.enums.values(Side)) |side| {
                links.neighbors[room][@backingInt(side)] = collision.neighbor(@intCast(room), side);
            }
        }
        return links;
    }

    /// The room on `side` if the level has it, and it is not `room` itself.
    pub fn neighbor(self: *const Links, room: u8, side: Side) ?u8 {
        const next = self.neighbors[room][@backingInt(side)] orelse return null;
        if (next == room or next >= room_count or !self.present.isSet(next)) return null;
        return next;
    }
};

/// The rooms a level draws. A level owns its room file's rooms unless another level shares the
/// file (`theirs`, the rooms that level's characters start in). Then it owns the rooms its own
/// characters start in (`mine`), the rooms no character of either starts in that touch those,
/// and not the shared rooms cut off from the rest of its own.
pub fn owned(links: *const Links, mine: RoomSet, theirs: ?RoomSet) RoomSet {
    const other = theirs orelse return links.present;
    var result = mine.intersectWith(links.present);
    const shared = result.intersectWith(other);
    var unclaimed = links.present.differenceWith(result).differenceWith(other);
    var free = unclaimed.iterator(.{});
    while (free.next()) |room| {
        if (touches(links, @intCast(room), result)) result.set(room);
    }
    var both = shared.iterator(.{});
    while (both.next()) |room| {
        if (!touches(links, @intCast(room), result)) result.unset(room);
    }
    return result;
}

fn touches(links: *const Links, room: u8, rooms: RoomSet) bool {
    for (std.enums.values(Side)) |side| {
        if (links.neighbor(room, side)) |next| if (rooms.isSet(next)) return true;
    }
    return false;
}

/// A room's piece and its cell in the piece, counted from the piece's top-left room.
pub const Cell = struct { piece: u8, x: i16, y: i16 };

/// The rooms laid out as pieces: each piece is flat, its rooms where their links put them.
pub const Map = struct {
    cells: [room_count]?Cell = @splat(null),
    piece_count: u8 = 0,
    /// Each piece's width and height in rooms.
    sizes: [room_count]struct { w: i16, h: i16 } = undefined,

    /// Whether `to` lies on `side` of `room`, as their link says.
    pub fn adjacent(self: *const Map, room: u8, side: Side, to: u8) bool {
        const a = self.cells[room] orelse return false;
        const b = self.cells[to] orelse return false;
        const d = step(side);
        return a.piece == b.piece and b.x == a.x + d.x and b.y == a.y + d.y;
    }
};

/// Lays `rooms` out from `start`: breadth first, a room goes where the first link to reach it
/// puts it, unless that cell is taken. The rooms left over start new pieces, in room order.
pub fn lay(links: *const Links, rooms: RoomSet, start: u8) Map {
    var map: Map = .{};
    var seeds: [room_count + 1]u8 = undefined;
    seeds[0] = start;
    var seed_count: usize = 1;
    var all = rooms.iterator(.{});
    while (all.next()) |room| {
        seeds[seed_count] = @intCast(room);
        seed_count += 1;
    }
    for (seeds[0..seed_count]) |seed| {
        if (!rooms.isSet(seed) or map.cells[seed] != null) continue;
        const piece = map.piece_count;
        map.piece_count += 1;
        var queue: [room_count]u8 = undefined;
        var members: [room_count]u8 = undefined;
        var head: usize = 0;
        var count: usize = 1;
        queue[0] = seed;
        members[0] = seed;
        map.cells[seed] = .{ .piece = piece, .x = 0, .y = 0 };
        while (head < count) : (head += 1) {
            const room = queue[head];
            const here = map.cells[room].?;
            for (walk_order) |side| {
                const next = links.neighbor(room, side) orelse continue;
                if (!rooms.isSet(next) or map.cells[next] != null) continue;
                const d = step(side);
                const cell: Cell = .{ .piece = piece, .x = here.x + d.x, .y = here.y + d.y };
                const taken = for (members[0..count]) |member| {
                    const other = map.cells[member].?;
                    if (other.x == cell.x and other.y == cell.y) break true;
                } else false;
                if (taken) continue;
                map.cells[next] = cell;
                queue[count] = next;
                members[count] = next;
                count += 1;
            }
        }
        // Count cells from the piece's top-left.
        var min_x: i16 = 0;
        var min_y: i16 = 0;
        var max_x: i16 = 0;
        var max_y: i16 = 0;
        for (members[0..count]) |member| {
            const cell = map.cells[member].?;
            min_x = @min(min_x, cell.x);
            min_y = @min(min_y, cell.y);
            max_x = @max(max_x, cell.x);
            max_y = @max(max_y, cell.y);
        }
        for (members[0..count]) |member| {
            map.cells[member].?.x -= min_x;
            map.cells[member].?.y -= min_y;
        }
        map.sizes[piece] = .{ .w = max_x - min_x + 1, .h = max_y - min_y + 1 };
    }
    return map;
}

/// A place in a room, in the room's pixels.
pub const Spot = struct { room: u8, x: i16, y: i16 };

/// A join the flat map cannot show: a link between two rooms that are not side by side on it,
/// or a transport from one room to another.
pub const Join = union(enum) {
    link: struct { room: u8, side: Side, to: u8 },
    transport: struct { from: Spot, to: Spot },
};

/// The links between drawn rooms that the map does not show side by side, once each: a link
/// and its way back are one join.
pub fn cutLinks(
    allocator: std.mem.Allocator,
    links: *const Links,
    map: *const Map,
    joins: *std.ArrayList(Join),
) !void {
    for (0..room_count) |index| {
        const room: u8 = @intCast(index);
        if (map.cells[room] == null) continue;
        for (std.enums.values(Side)) |side| {
            const to = links.neighbor(room, side) orelse continue;
            if (map.cells[to] == null or map.adjacent(room, side, to)) continue;
            if (links.neighbor(to, opposite(side)) == room and to < room) continue;
            try joins.append(allocator, .{ .link = .{ .room = room, .side = side, .to = to } });
        }
    }
}

/// The transports that move the player between two drawn rooms: from where the transporting
/// character is (the room it starts in, or the room it reveals itself in) to the character the
/// player is moved to. A transport within one room is no join.
pub fn transports(
    allocator: std.mem.Allocator,
    level: *const data_set.Level,
    map: *const Map,
    joins: *std.ArrayList(Join),
) !void {
    for (level.characters) |character| {
        const behavior = level.behaviors[character.behavior];
        for (behavior.states) |state| for (state.rules) |rule| {
            for (rule.when) |operation| try addTransport(allocator, level, map, character, behavior, operation, joins);
            if (rule.then) |operation| try addTransport(allocator, level, map, character, behavior, operation, joins);
        };
    }
}

fn addTransport(
    allocator: std.mem.Allocator,
    level: *const data_set.Level,
    map: *const Map,
    character: data_set.Character,
    behavior: vocabulary.Behavior,
    operation: vocabulary.Operation,
    joins: *std.ArrayList(Join),
) !void {
    const transport = switch (operation) {
        .transport => |t| t,
        else => return,
    };
    const moved = character.links[@backingInt(transport.move)] orelse return;
    const target = character.links[@backingInt(transport.to)] orelse return;
    if (moved == target) return;
    if (level.characters[@backingInt(moved)].kind != .player) return;
    const destination = level.characters[@backingInt(target)];
    const to_room = destination.room orelse return;
    const from_room = character.room orelse revealRoom(behavior, character) orelse return;
    if (from_room == to_room) return;
    if (from_room >= room_count or to_room >= room_count) return;
    if (map.cells[from_room] == null or map.cells[to_room] == null) return;
    for (joins.items) |join| switch (join) {
        .transport => |t| if (t.from.room == from_room and t.to.room == to_room) return,
        .link => {},
    };
    try joins.append(allocator, .{ .transport = .{
        .from = .{ .room = from_room, .x = character.x, .y = character.y },
        .to = .{ .room = to_room, .x = destination.x, .y = destination.y },
    } });
}

/// The room a character outside the world reveals itself in: `reveal` names it by number.
fn revealRoom(behavior: vocabulary.Behavior, character: data_set.Character) ?u8 {
    for (behavior.states) |state| for (state.rules) |rule| {
        if (rule.then) |operation| switch (operation) {
            .reveal => |number| {
                const room = character.numbers[@backingInt(number)];
                if (room >= 0 and room < room_count) return @intCast(room);
            },
            else => {},
        };
    };
    return null;
}

fn testLinks(comptime rows: []const []const u8) Links {
    // A letter per room on a grid of cells; neighbors are the letters beside each other.
    var links: Links = .{ .present = .empty, .neighbors = @splat(@splat(null)) };
    for (rows, 0..) |row, y| for (row, 0..) |c, x| {
        if (c == '.') continue;
        const room = c - 'a';
        links.present.set(room);
        if (y > 0 and x < rows[y - 1].len and rows[y - 1][x] != '.') links.neighbors[room][0] = rows[y - 1][x] - 'a';
        if (y + 1 < rows.len and x < rows[y + 1].len and rows[y + 1][x] != '.') links.neighbors[room][1] = rows[y + 1][x] - 'a';
        if (x + 1 < row.len and row[x + 1] != '.') links.neighbors[room][2] = row[x + 1] - 'a';
        if (x > 0 and row[x - 1] != '.') links.neighbors[room][3] = row[x - 1] - 'a';
    };
    return links;
}

test "a grid of linked rooms lies flat as one piece, from its start room" {
    const links = testLinks(&.{ "ab.", ".cd" });
    const map = lay(&links, links.present, 2);
    try std.testing.expectEqual(@as(u8, 1), map.piece_count);
    try std.testing.expectEqual(Cell{ .piece = 0, .x = 0, .y = 0 }, map.cells[0].?);
    try std.testing.expectEqual(Cell{ .piece = 0, .x = 2, .y = 1 }, map.cells[3].?);
    try std.testing.expectEqual(@as(i16, 3), map.sizes[0].w);
    var joins: std.ArrayList(Join) = .empty;
    defer joins.deinit(std.testing.allocator);
    try cutLinks(std.testing.allocator, &links, &map, &joins);
    try std.testing.expectEqual(@as(usize, 0), joins.items.len);
}

test "a ring of rooms is cut once, and its wrap-around link is a join" {
    // a b c d, and d's right is a: a floor that wraps around.
    var links = testLinks(&.{"abcd"});
    links.neighbors[3][@backingInt(Side.right)] = 0;
    links.neighbors[0][@backingInt(Side.left)] = 3;
    const map = lay(&links, links.present, 0);
    try std.testing.expectEqual(@as(u8, 1), map.piece_count);
    var joins: std.ArrayList(Join) = .empty;
    defer joins.deinit(std.testing.allocator);
    try cutLinks(std.testing.allocator, &links, &map, &joins);
    // a's left puts d before a, so the cut falls between c and d.
    try std.testing.expectEqual(@as(usize, 1), joins.items.len);
    try std.testing.expectEqual(@as(u8, 2), joins.items[0].link.room);
    try std.testing.expectEqual(Side.right, joins.items[0].link.side);
    try std.testing.expectEqual(@as(u8, 3), joins.items[0].link.to);
}

test "a link into a taken cell starts a new piece, joined to the first" {
    // b's down is e, but from d, c is placed below b first: e becomes a piece of its own.
    var links = testLinks(&.{ "ab", "dc" });
    links.neighbors[1][@backingInt(Side.down)] = 4;
    links.neighbors[2][@backingInt(Side.up)] = null;
    links.present.set(4);
    links.neighbors[4][@backingInt(Side.up)] = 1;
    const map = lay(&links, links.present, 3);
    try std.testing.expectEqual(@as(u8, 2), map.piece_count);
    try std.testing.expectEqual(@as(u8, 1), map.cells[4].?.piece);
    var joins: std.ArrayList(Join) = .empty;
    defer joins.deinit(std.testing.allocator);
    try cutLinks(std.testing.allocator, &links, &map, &joins);
    try std.testing.expectEqual(@as(usize, 1), joins.items.len);
    try std.testing.expectEqual(@as(u8, 1), joins.items[0].link.room);
    try std.testing.expectEqual(Side.down, joins.items[0].link.side);
}

test "levels sharing a room file own their characters' rooms and the free rooms beside them" {
    // a b c d e: this level's characters start in a and b, the other's in d and e; c is free
    // and touches b. A shared room cut off from this level's rooms goes to the other.
    const links = testLinks(&.{"abcde"});
    var mine: RoomSet = .empty;
    mine.set(0);
    mine.set(1);
    mine.set(4);
    var theirs: RoomSet = .empty;
    theirs.set(3);
    theirs.set(4);
    const rooms = owned(&links, mine, theirs);
    try std.testing.expect(rooms.isSet(0) and rooms.isSet(1) and rooms.isSet(2));
    try std.testing.expect(!rooms.isSet(3) and !rooms.isSet(4));
    try std.testing.expectEqual(links.present, owned(&links, mine, null));
}
