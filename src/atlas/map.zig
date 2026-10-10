//! A level's rooms on a flat map. The rooms' links (the collision grid's neighbor tables) place
//! them on a grid of room cells from the start room. The game's rooms do not always lie flat: a
//! link may lead to a room whose cell another link has taken (the tower's floors wrap around), and
//! some areas are reached only by a transport. Those links and transports are the map's joins; the
//! poster tags both ends of each join between two pieces. A ring of links may also be a transit
//! line rather than ground (the city's subway stations): its stations lie apart, and the poster
//! draws the level along it.
const std = @import("std");
const flashbackz = @import("flashbackz");
const grid = flashbackz.behavior.grid;
const data_set = flashbackz.behavior.data_set;
const vocabulary = flashbackz.behavior.vocabulary;

pub const room_count = 64;
pub const RoomSet = std.StaticBitSet(room_count);
pub const Side = grid.Side;

pub const room_width = 256;
pub const room_height = 224;
/// Rooms stacked by their links overlap by eight rows: the room below repeats the bottom of
/// the room above (the collision grid's floors are 216 pixels apart).
pub const room_pitch = 216;

/// Each drawn room's pixels, RGB, by room number.
pub const Pixels = [room_count]?[]const u8;

/// Links the layout does not follow, by room and `Side`.
pub const Skipped = [room_count][4]bool;

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
/// puts it, unless that cell is taken or the link is skipped. The rooms left over start new
/// pieces, in room order.
pub fn lay(links: *const Links, rooms: RoomSet, start: u8, skipped: *const Skipped) Map {
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
                if (skipped[room][@backingInt(side)]) continue;
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

/// How much the picture breaks where `room` meets `to` on its `side`: the mean difference, per
/// color channel, of the pixel columns either side of their edge, or of the eight rows a room
/// repeats from the room above it.
pub fn seam(pixels: *const Pixels, room: u8, side: Side, to: u8) ?f32 {
    const here = pixels[room] orelse return null;
    const there = pixels[to] orelse return null;
    const first, const second = switch (side) {
        .right, .down => .{ here, there },
        .left, .up => .{ there, here },
    };
    var total: u32 = 0;
    var count: u32 = 0;
    switch (side) {
        .right, .left => for (0..room_height) |y| {
            const a = first[(y * room_width + room_width - 1) * 3 ..][0..3];
            const b = second[(y * room_width) * 3 ..][0..3];
            for (a, b) |p, q| total += @abs(@as(i16, p) - q);
            count += 3;
        },
        .down, .up => for (0..room_height - room_pitch) |y| {
            const a = first[(room_pitch + y) * room_width * 3 ..][0 .. room_width * 3];
            const b = second[y * room_width * 3 ..][0 .. room_width * 3];
            for (a, b) |p, q| total += @abs(@as(i16, p) - q);
            count += room_width * 3;
        },
    }
    return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(count));
}

/// A level's transit line: a ring of stations, each riding right into the next and the last back
/// into the first.
pub const Line = struct {
    stations: [room_count]u8 = undefined,
    /// The room each station leads up to, if it leads up.
    above: [room_count]?u8 = undefined,
    len: usize = 0,

    pub fn has(self: *const Line, room: u8) bool {
        return std.mem.indexOfScalar(u8, self.stations[0..self.len], room) != null;
    }

    /// Every link into or out of a station: the layout puts each station apart, a piece of its
    /// own.
    pub fn skipped(self: *const Line, links: *const Links) Skipped {
        var result: Skipped = @splat(@splat(false));
        var rooms = links.present.iterator(.{});
        while (rooms.next()) |index| {
            const room: u8 = @intCast(index);
            for (std.enums.values(Side)) |side| {
                const next = links.neighbor(room, side) orelse continue;
                if (self.has(room) or self.has(next)) result[room][@backingInt(side)] = true;
            }
        }
        return result;
    }
};

/// The level's transit line, if it has one: the first ring of rooms, each linked right to the
/// next, for which both hold: none of its links continues the picture (each breaks it more than
/// the level's usual link across), and without its links its rooms lead into two or more parts
/// of the level that have rooms of their own. A tower floor that wraps around continues its
/// pictures, so it stays ground.
pub fn transitLine(links: *const Links, rooms: RoomSet, pixels: *const Pixels) ?Line {
    const usual = medianSeam(links, rooms, pixels, .right) orelse return null;
    // Rooms in order, so a ring is found from its lowest room.
    var starts = rooms.iterator(.{});
    while (starts.next()) |index| {
        var ring: [room_count]u8 = undefined;
        const length = findRing(links, rooms, @intCast(index), .right, &ring) orelse continue;
        const members = ring[0..length];
        const breaks = for (members, 0..) |room, i| {
            const break_size = seam(pixels, room, .right, members[(i + 1) % length]) orelse break false;
            if (break_size <= usual) break false;
        } else true;
        if (!breaks or !separates(links, rooms, members, .right)) continue;
        var line: Line = .{ .len = length };
        for (members, 0..) |station, i| {
            line.stations[i] = station;
            line.above[i] = null;
            if (links.neighbor(station, .up)) |room| {
                if (rooms.isSet(room) and std.mem.indexOfScalar(u8, members, room) == null) line.above[i] = room;
            }
        }
        return line;
    }
    return null;
}

/// The rooms reached from `start` by following `side` until it comes back to `start`.
fn findRing(links: *const Links, rooms: RoomSet, start: u8, side: Side, ring: *[room_count]u8) ?usize {
    ring[0] = start;
    var length: usize = 1;
    var room = start;
    while (links.neighbor(room, side)) |next| {
        if (next == start) return if (length >= 2) length else null;
        if (!rooms.isSet(next) or std.mem.indexOfScalar(u8, ring[0..length], next) != null) return null;
        ring[length] = next;
        length += 1;
        room = next;
    }
    return null;
}

/// The median seam of the links between `rooms` on the axis of `side`.
fn medianSeam(links: *const Links, rooms: RoomSet, pixels: *const Pixels, side: Side) ?f32 {
    var values: [room_count]f32 = undefined;
    var count: usize = 0;
    var all = rooms.iterator(.{});
    while (all.next()) |index| {
        const room: u8 = @intCast(index);
        const to = links.neighbor(room, side) orelse continue;
        if (!rooms.isSet(to)) continue;
        values[count] = seam(pixels, room, side, to) orelse continue;
        count += 1;
    }
    if (count == 0) return null;
    std.sort.pdq(f32, values[0..count], {}, std.sort.asc(f32));
    return values[count / 2];
}

/// Whether, without the ring's links, its rooms lie in two or more parts of `rooms` that hold
/// rooms beyond the ring.
fn separates(links: *const Links, rooms: RoomSet, ring: []const u8, side: Side) bool {
    // Parts by flood fill over every link but the ring's, both ways.
    var part: [room_count]?u8 = @splat(null);
    var part_count: u8 = 0;
    var all = rooms.iterator(.{});
    while (all.next()) |index| {
        if (part[index] != null) continue;
        var stack: [room_count]u8 = undefined;
        var depth: usize = 1;
        stack[0] = @intCast(index);
        part[index] = part_count;
        while (depth > 0) {
            depth -= 1;
            const room = stack[depth];
            var others = rooms.iterator(.{});
            while (others.next()) |other_index| {
                const other: u8 = @intCast(other_index);
                if (part[other] != null or !linked(links, ring, side, room, other)) continue;
                part[other] = part_count;
                stack[depth] = other;
                depth += 1;
            }
        }
        part_count += 1;
    }
    var parts_with_rooms: std.StaticBitSet(room_count) = .empty;
    for (ring) |room| {
        const p = part[room].?;
        for (part, 0..) |other, room_index| {
            if (other == p and std.mem.indexOfScalar(u8, ring, @intCast(room_index)) == null) {
                parts_with_rooms.set(p);
                break;
            }
        }
    }
    return parts_with_rooms.count() >= 2;
}

/// Whether a link joins `a` and `b`, either way, other than the ring's own.
fn linked(links: *const Links, ring: []const u8, side: Side, a: u8, b: u8) bool {
    for (std.enums.values(Side)) |s| {
        if (links.neighbor(a, s) == b and !ringLink(ring, side, a, s, b)) return true;
        if (links.neighbor(b, s) == a and !ringLink(ring, side, b, s, a)) return true;
    }
    return false;
}

fn ringLink(ring: []const u8, side: Side, from: u8, s: Side, to: u8) bool {
    if (s != side and s != opposite(side)) return false;
    const i = std.mem.indexOfScalar(u8, ring, from) orelse return false;
    const j = std.mem.indexOfScalar(u8, ring, to) orelse return false;
    const next = (i + 1) % ring.len;
    const previous = (i + ring.len - 1) % ring.len;
    return if (s == side) j == next else j == previous;
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

const no_skips: Skipped = @splat(@splat(false));

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
    const map = lay(&links, links.present, 2, &no_skips);
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
    const map = lay(&links, links.present, 0, &no_skips);
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
    const map = lay(&links, links.present, 3, &no_skips);
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

test "a ring of stations between districts is a transit line; a ring whose picture continues is ground" {
    const allocator = std.testing.allocator;
    // Two districts of three rooms in a row (2 3 4 and 5 6 7), each above a station (0 below
    // 2, 1 below 5); each station leads into the other on both sides.
    var links: Links = .{ .present = .empty, .neighbors = @splat(@splat(null)) };
    for (0..8) |room| links.present.set(room);
    const pairs = [_]struct { u8, Side, u8 }{
        .{ 0, .right, 1 }, .{ 1, .right, 0 }, .{ 2, .down, 0 },  .{ 5, .down, 1 },
        .{ 2, .right, 3 }, .{ 3, .right, 4 }, .{ 5, .right, 6 }, .{ 6, .right, 7 },
    };
    for (pairs) |pair| {
        const a, const side, const b = pair;
        links.neighbors[a][@backingInt(side)] = b;
        links.neighbors[b][@backingInt(opposite(side))] = a;
    }
    const buffers = try allocator.alloc([room_width * room_height * 3]u8, 8);
    defer allocator.free(buffers);
    var pixels: Pixels = @splat(null);
    for (buffers, 0..) |*buffer, room| {
        @memset(buffer, if (room >= 2) 50 else 0);
        pixels[room] = buffer;
    }

    // The stations' pictures do not continue into each other: the ring is a transit line, each
    // station under the district it leads up to, and the stations lie apart from the districts.
    @memset(&buffers[1], 200);
    const line = transitLine(&links, links.present, &pixels).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, line.stations[0..line.len]);
    try std.testing.expectEqualSlices(?u8, &.{ 2, 5 }, line.above[0..line.len]);
    const skipped = line.skipped(&links);
    try std.testing.expect(skipped[2][@backingInt(Side.down)] and !skipped[2][@backingInt(Side.right)]);
    const map = lay(&links, links.present, 2, &skipped);
    try std.testing.expectEqual(@as(u8, 4), map.piece_count);
    try std.testing.expect(map.cells[0].?.piece != map.cells[2].?.piece);
    try std.testing.expect(map.cells[0].?.piece != map.cells[1].?.piece);

    // The same ring with continuous pictures is ground, like a tower floor.
    @memset(&buffers[1], 0);
    try std.testing.expect(transitLine(&links, links.present, &pixels) == null);
}
