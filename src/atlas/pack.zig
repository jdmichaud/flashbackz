//! Packs a level's pieces into one block. The largest piece goes first; each next one goes where
//! the block stays lowest within the width, nested into the empty corners of the others but
//! never nearer to their rooms than the gap, so pieces never seem to touch. Among places as low,
//! a piece goes nearest the pieces it is tied to (the map's joins), then where the block stays
//! narrowest. A level with a transit line is placed along it instead (`line`).
const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};
pub const Point = struct {
    x: i32,
    y: i32,
};
pub const Size = struct {
    w: i32,
    h: i32,
};

/// A piece: its rooms' rectangles from its own origin, and its size.
pub const Piece = struct {
    rooms: []const Rect,
    size: Size,
};

/// Two points of two pieces that belong near each other, each from its piece's origin.
pub const Tie = struct {
    a: usize,
    a_at: Point,
    b: usize,
    b_at: Point,
};

/// Candidate positions are this far apart, across and down.
const step_x = 128;
const step_y = 64;

/// Sets `origins[i]`, piece i's top-left in the block, and returns the block's size. Pieces
/// go no further right than `limit`, unless a piece is wider than that on its own.
pub fn pack(pieces: []const Piece, ties: []const Tie, limit: i32, gap: i32, origins: []Point) Size {
    std.debug.assert(origins.len == pieces.len);
    if (pieces.len == 0) return .{ .w = 0, .h = 0 };
    var order_buffer: [64]usize = undefined;
    const order = order_buffer[0..pieces.len];
    for (order, 0..) |*o, i| {
        o.* = i;
    }
    std.sort.insertion(
        usize,
        order,
        pieces,
        struct {
            fn larger(p: []const Piece, a: usize, b: usize) bool {
                return p[a].rooms.len > p[b].rooms.len;
            }
        }.larger,
    );

    var placed: [64]bool = @splat(false);
    var bounds: Rect = .{
        .x = 0,
        .y = 0,
        .w = pieces[order[0]].size.w,
        .h = pieces[order[0]].size.h,
    };
    origins[order[0]] = .{ .x = 0, .y = 0 };
    placed[order[0]] = true;
    for (order[1..], 1..) |index, placed_count| {
        const size = pieces[index].size;
        var best: ?struct { key: [5]i64, at: Point } = null;
        var y = bounds.y - size.h - gap;
        while (y <= bounds.y + bounds.h + gap) : (y += step_y) {
            var x: i32 = 0;
            while (x == 0 or x + size.w <= limit) : (x += step_x) {
                const at: Point = .{ .x = x, .y = y };
                if (collides(pieces, origins, order[0..placed_count], pieces[index], at, gap)) {
                    continue;
                }
                const grown = merge(bounds, .{ .x = x, .y = y, .w = size.w, .h = size.h });
                const distance = tieDistance(ties, origins, &placed, index, at);
                const key = [5]i64{ grown.h, distance, grown.w, @abs(y), x };
                if (best == null or std.mem.order(i64, &key, &best.?.key) == .lt) {
                    best = .{ .key = key, .at = at };
                }
            }
        }
        // Below everything, a piece is always free.
        const at = if (best) |b| b.at else Point{ .x = 0, .y = bounds.y + bounds.h + gap };
        origins[index] = at;
        placed[index] = true;
        bounds = merge(bounds, .{ .x = at.x, .y = at.y, .w = size.w, .h = size.h });
    }
    for (origins) |*o| {
        o.x -= bounds.x;
        o.y -= bounds.y;
    }
    return .{ .w = bounds.w, .h = bounds.h };
}

/// A stop on a transit line: its station's piece, and the district above: the district's piece,
/// the room the station sits under and the spot right under that room, both from the
/// district's origin. A station that leads up nowhere has no district.
pub const Stop = struct {
    station: usize,
    district: ?struct { piece: usize, room: Rect, below: Point },
};

/// Places a transit line's pieces. The stations stand on one row, in the stops' order, each
/// under its district's room. A station stands right under its room, touching it, when no other
/// room of its district is near that spot, and the row is then that station's; otherwise its
/// district stands higher, its rooms over the station all clear of it. Each district in turn
/// goes where the block's width and height add up least, then nearest its station, never nearer
/// than `gap` to another district's rooms, to a station or to the way down from another
/// district's room to its station: districts close in, a district rising only where that saves
/// more width than height. The other pieces go below, each under the piece it is tied to where
/// it can. Sets `origins` and returns the block's size.
pub fn line(
    pieces: []const Piece,
    stops: []const Stop,
    ties: []const Tie,
    gap: i32,
    origins: []Point,
) Size {
    std.debug.assert(origins.len == pieces.len);
    // The stations' row is y 0 until the block is moved to its top-left.
    var obstacles: [3 * 64]Obstacle = undefined;
    var obstacle_count: usize = 0;
    var placed: [64]bool = @splat(false);
    var bounds: ?Rect = null;
    var next_station: ?i32 = null;
    for (stops) |stop| {
        const station = pieces[stop.station].size;
        const district = stop.district orelse {
            origins[stop.station] = .{ .x = next_station orelse 0, .y = 0 };
            placed[stop.station] = true;
            const rect: Rect = .{
                .x = origins[stop.station].x,
                .y = 0,
                .w = station.w,
                .h = station.h,
            };
            obstacles[obstacle_count] = .{ .rect = rect, .way = false };
            obstacle_count += 1;
            bounds = if (bounds) |b| merge(b, rect) else rect;
            next_station = rect.x + rect.w + gap;
            continue;
        };
        const piece = pieces[district.piece];
        if (!placed[district.piece]) {
            const below: Rect = .{
                .x = district.below.x,
                .y = district.below.y,
                .w = station.w,
                .h = station.h,
            };
            const touching = for (piece.rooms) |room| {
                if (std.meta.eql(room, district.room)) continue;
                if (near(room, below, gap)) break false;
            } else true;
            // The lowest the district goes: right over its station, or with every room over
            // the station clear of it.
            var lowest = -below.y;
            if (!touching) {
                for (piece.rooms) |room| {
                    if (room.x < below.x + below.w + gap and below.x < room.x + room.w + gap) {
                        lowest = @min(lowest, -(room.y + room.h + gap));
                    }
                }
            }
            const placement: Placement = .{
                .piece = piece,
                .room = district.room,
                .below = below,
                .touching = touching,
                .gap = gap,
            };
            var at: Point = .{ .x = 0, .y = lowest };
            if (bounds) |b| {
                const from = (next_station orelse b.x) - below.x;
                const free = @max(from, b.x + b.w + gap);
                var best: ?struct { key: [3]i64, at: Point } = null;
                var x = from;
                while (x <= free) : (x = if (x < free) @min(x + step_x, free) else free + 1) {
                    var y = lowest;
                    while (y >= b.y - piece.size.h - gap) : (y -= step_y) {
                        const candidate: Point = .{ .x = x, .y = y };
                        if (placement.hits(obstacles[0..obstacle_count], candidate)) {
                            if (touching) break else continue;
                        }
                        const grown = merge(
                            merge(b, placement.extent(candidate)),
                            placement.station(candidate),
                        );
                        const key = [3]i64{ grown.w + grown.h, lowest - y, x };
                        if (best == null or std.mem.order(i64, &key, &best.?.key) == .lt) {
                            best = .{ .key = key, .at = candidate };
                        }
                        if (touching) break;
                    }
                }
                // Right of everything, a district is always free.
                at = if (best) |found| found.at else .{ .x = free, .y = lowest };
            }
            origins[district.piece] = at;
            placed[district.piece] = true;
            for (piece.rooms) |room| {
                obstacles[obstacle_count] = .{ .rect = moved(room, at), .way = false };
                obstacle_count += 1;
            }
            if (!touching) {
                obstacles[obstacle_count] = .{ .rect = placement.way(at), .way = true };
                obstacle_count += 1;
            }
            const extent = placement.extent(at);
            bounds = if (bounds) |b| merge(b, extent) else extent;
        }
        const x = origins[district.piece].x + district.below.x;
        const rect: Rect = .{ .x = x, .y = 0, .w = station.w, .h = station.h };
        origins[stop.station] = .{ .x = x, .y = 0 };
        placed[stop.station] = true;
        obstacles[obstacle_count] = .{ .rect = rect, .way = false };
        obstacle_count += 1;
        bounds = merge(bounds.?, rect);
        next_station = x + station.w + gap;
    }

    // The other pieces, below.
    var block = bounds orelse Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const top = block.y + block.h + 2 * gap;
    var left = block.x;
    for (pieces, 0..) |piece, index| {
        if (placed[index]) continue;
        var x = left;
        for (ties) |tie| {
            const here, const there, const other = if (tie.a == index)
                .{ tie.a_at, tie.b_at, tie.b }
            else if (tie.b == index)
                .{ tie.b_at, tie.a_at, tie.a }
            else
                continue;
            if (!placed[other]) continue;
            x = @max(
                left,
                @min(origins[other].x + there.x - here.x, block.x + block.w - piece.size.w),
            );
            break;
        }
        origins[index] = .{ .x = x, .y = top };
        placed[index] = true;
        left = x + piece.size.w + gap;
        block = merge(block, .{ .x = x, .y = top, .w = piece.size.w, .h = piece.size.h });
    }
    for (origins) |*o| {
        o.x -= block.x;
        o.y -= block.y;
    }
    return .{ .w = block.w, .h = block.h };
}

/// A placed room or station, or the way down to a station, in the block.
const Obstacle = struct {
    rect: Rect,
    way: bool,
};

/// A district being placed over its station.
const Placement = struct {
    piece: Piece,
    room: Rect,
    /// The spot right under `room`, the station's size.
    below: Rect,
    touching: bool,
    gap: i32,

    fn station(self: Placement, at: Point) Rect {
        return .{ .x = at.x + self.below.x, .y = 0, .w = self.below.w, .h = self.below.h };
    }

    /// From the bottom of the room to the station.
    fn way(self: Placement, at: Point) Rect {
        const top = at.y + self.room.y + self.room.h;
        return .{ .x = at.x + self.below.x, .y = top, .w = self.below.w, .h = -top };
    }

    fn extent(self: Placement, at: Point) Rect {
        return .{ .x = at.x, .y = at.y, .w = self.piece.size.w, .h = self.piece.size.h };
    }

    /// Whether the district at `at`, its station or its way down comes near another's.
    fn hits(self: Placement, obstacles: []const Obstacle, at: Point) bool {
        const station_rect = self.station(at);
        const way_rect = self.way(at);
        for (obstacles) |obstacle| {
            for (self.piece.rooms) |room| {
                if (near(moved(room, at), obstacle.rect, self.gap)) return true;
            }
            if (near(station_rect, obstacle.rect, self.gap)) return true;
            if (!self.touching and
                !obstacle.way and
                way_rect.h > 0 and
                near(way_rect, obstacle.rect, self.gap)) {
                return true;
            }
        }
        return false;
    }
};

fn near(a: Rect, b: Rect, gap: i32) bool {
    return a.x < b.x + b.w + gap and b.x < a.x + a.w + gap and
        a.y < b.y + b.h + gap and b.y < a.y + a.h + gap;
}

fn moved(rect: Rect, at: Point) Rect {
    return .{ .x = rect.x + at.x, .y = rect.y + at.y, .w = rect.w, .h = rect.h };
}

fn collides(
    pieces: []const Piece,
    origins: []const Point,
    placed: []const usize,
    piece: Piece,
    at: Point,
    gap: i32,
) bool {
    for (placed) |other| {
        const o = origins[other];
        for (pieces[other].rooms) |b| {
            for (piece.rooms) |a| {
                const ax = a.x + at.x;
                const ay = a.y + at.y;
                const bx = b.x + o.x;
                const by = b.y + o.y;
                if (ax < bx + b.w + gap and bx < ax + a.w + gap and
                    ay < by + b.h + gap and by < ay + a.h + gap) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// How far piece `index`, at `at`, lies from the placed pieces it is tied to.
fn tieDistance(
    ties: []const Tie,
    origins: []const Point,
    placed: []const bool,
    index: usize,
    at: Point,
) i64 {
    var total: i64 = 0;
    for (ties) |tie| {
        const here, const there, const other = if (tie.a == index)
            .{ tie.a_at, tie.b_at, tie.b }
        else if (tie.b == index)
            .{ tie.b_at, tie.a_at, tie.a }
        else
            continue;
        if (!placed[other]) continue;
        total += @abs(at.x + here.x - origins[other].x - there.x) +
            @abs(at.y + here.y - origins[other].y - there.y);
    }
    return total;
}

fn merge(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{
        .x = x,
        .y = y,
        .w = @max(a.x + a.w, b.x + b.w) - x,
        .h = @max(a.y + a.h, b.y + b.h) - y,
    };
}

test "a small piece nests in a large piece's empty corner, a gap away from its rooms" {
    // An L of three rooms leaves its top-right corner empty; one room fits there only if the
    // gap allows, so with no gap it nests and the block keeps the L's size.
    const l_rooms = [_]Rect{
        .{ .x = 0, .y = 0, .w = 256, .h = 224 },
        .{ .x = 0, .y = 216, .w = 256, .h = 224 },
        .{ .x = 256, .y = 216, .w = 256, .h = 224 },
    };
    const one = [_]Rect{.{ .x = 0, .y = 0, .w = 128, .h = 64 }};
    const pieces = [_]Piece{
        .{ .rooms = &one, .size = .{ .w = 128, .h = 64 } },
        .{ .rooms = &l_rooms, .size = .{ .w = 512, .h = 440 } },
    };
    var origins: [2]Point = undefined;
    const size = pack(&pieces, &.{}, 512, 0, &origins);
    try std.testing.expectEqual(Size{ .w = 512, .h = 440 }, size);
    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, origins[1]);
    try std.testing.expect(origins[0].x >= 256 and origins[0].y + 64 <= 216);

    // A gap wider than the corner sends the small piece outside the L, the gap away.
    const spaced = pack(&pieces, &.{}, 512, 160, &origins);
    try std.testing.expect(spaced.h > 440 or spaced.w > 512);
    for (pieces[1].rooms) |b| {
        const a = pieces[0].rooms[0];
        const ax = a.x + origins[0].x;
        const ay = a.y + origins[0].y;
        const bx = b.x + origins[1].x;
        const by = b.y + origins[1].y;
        const apart = ax >= bx + b.w + 160 or
            bx >= ax + a.w + 160 or
            ay >= by + b.h + 160 or
            by >= ay + a.h + 160;
        try std.testing.expect(apart);
    }
}

test "among places as small, a piece goes nearest the piece it is tied to" {
    // A wide piece with room for a small one at either end of a row below; the tie names the
    // right end.
    const wide = [_]Rect{.{ .x = 0, .y = 0, .w = 1024, .h = 224 }};
    const small = [_]Rect{.{ .x = 0, .y = 0, .w = 256, .h = 224 }};
    const pieces = [_]Piece{
        .{ .rooms = &wide, .size = .{ .w = 1024, .h = 224 } },
        .{ .rooms = &small, .size = .{ .w = 256, .h = 224 } },
    };
    var origins: [2]Point = undefined;
    _ = pack(&pieces, &.{}, 1024, 64, &origins);
    try std.testing.expectEqual(@as(i32, 0), origins[1].x);
    const ties = [_]Tie{.{
        .a = 0,
        .a_at = .{ .x = 1024, .y = 112 },
        .b = 1,
        .b_at = .{ .x = 128, .y = 0 },
    }};
    _ = pack(&pieces, &ties, 1024, 64, &origins);
    try std.testing.expectEqual(@as(i32, 768), origins[1].x);
}

test "along a line, a station clear under its room touches it, and the others share its row" {
    // District 0, one room: its station (2) stands right under it. District 1, two rooms one
    // over the other: its station (3) sits under the upper room, so the lower room stands
    // clear above the row. Piece 4, off the line, is tied to district 1.
    const gap = 128;
    const one = [_]Rect{.{ .x = 0, .y = 0, .w = 256, .h = 224 }};
    const two = [_]Rect{ one[0], .{ .x = 0, .y = 216, .w = 256, .h = 224 } };
    const pieces = [_]Piece{
        .{ .rooms = &one, .size = .{ .w = 256, .h = 224 } },
        .{ .rooms = &two, .size = .{ .w = 256, .h = 440 } },
        .{ .rooms = &one, .size = .{ .w = 256, .h = 224 } },
        .{ .rooms = &one, .size = .{ .w = 256, .h = 224 } },
        .{ .rooms = &one, .size = .{ .w = 256, .h = 224 } },
    };
    const stops = [_]Stop{
        .{
            .station = 2,
            .district = .{ .piece = 0, .room = one[0], .below = .{ .x = 0, .y = 216 } },
        },
        .{
            .station = 3,
            .district = .{ .piece = 1, .room = one[0], .below = .{ .x = 0, .y = 216 } },
        },
    };
    const ties = [_]Tie{.{
        .a = 4,
        .a_at = .{ .x = 0, .y = 0 },
        .b = 1,
        .b_at = .{ .x = 0, .y = 0 },
    }};
    var origins: [5]Point = undefined;
    const size = line(&pieces, &stops, &ties, gap, &origins);

    try std.testing.expectEqual(origins[2].y, origins[3].y);
    try std.testing.expectEqual(Point{ .x = origins[0].x, .y = origins[0].y + 216 }, origins[2]);
    try std.testing.expectEqual(origins[1].x, origins[3].x);
    try std.testing.expectEqual(origins[3].y - gap, origins[1].y + 440);
    // The second district as near the first as its station allows.
    try std.testing.expectEqual(origins[2].x + 256 + gap, origins[3].x);
    // The piece off the line, under the district it is tied to, below everything.
    try std.testing.expectEqual(
        Point{ .x = origins[1].x, .y = origins[3].y + 224 + 2 * gap },
        origins[4],
    );
    try std.testing.expectEqual(Size{ .w = 2 * 256 + gap, .h = origins[4].y + 224 }, size);
}
