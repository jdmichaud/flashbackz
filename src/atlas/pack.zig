//! Packs a level's pieces into one block. The largest piece goes first; each next one goes where
//! the block stays lowest within the width, nested into the empty corners of the others but
//! never nearer to their rooms than the gap, so pieces never seem to touch. Among places as low,
//! a piece goes nearest the pieces it is tied to (the map's joins), then where the block stays
//! narrowest.
const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Point = struct { x: i32, y: i32 };
pub const Size = struct { w: i32, h: i32 };

/// A piece: its rooms' rectangles from its own origin, and its size.
pub const Piece = struct { rooms: []const Rect, size: Size };

/// Two points of two pieces that belong near each other, each from its piece's origin.
pub const Tie = struct { a: usize, a_at: Point, b: usize, b_at: Point };

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
    for (order, 0..) |*o, i| o.* = i;
    std.sort.insertion(usize, order, pieces, struct {
        fn larger(p: []const Piece, a: usize, b: usize) bool {
            return p[a].rooms.len > p[b].rooms.len;
        }
    }.larger);

    var placed: [64]bool = @splat(false);
    var bounds: Rect = .{ .x = 0, .y = 0, .w = pieces[order[0]].size.w, .h = pieces[order[0]].size.h };
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
                if (collides(pieces, origins, order[0..placed_count], pieces[index], at, gap)) continue;
                const grown = merge(bounds, .{ .x = x, .y = y, .w = size.w, .h = size.h });
                const distance = tieDistance(ties, origins, &placed, index, at);
                const key = [5]i64{ grown.h, distance, grown.w, @abs(y), x };
                if (best == null or std.mem.order(i64, &key, &best.?.key) == .lt) best = .{ .key = key, .at = at };
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
        for (pieces[other].rooms) |b| for (piece.rooms) |a| {
            const ax = a.x + at.x;
            const ay = a.y + at.y;
            const bx = b.x + o.x;
            const by = b.y + o.y;
            if (ax < bx + b.w + gap and bx < ax + a.w + gap and
                ay < by + b.h + gap and by < ay + a.h + gap) return true;
        };
    }
    return false;
}

/// How far piece `index`, at `at`, lies from the placed pieces it is tied to.
fn tieDistance(ties: []const Tie, origins: []const Point, placed: []const bool, index: usize, at: Point) i64 {
    var total: i64 = 0;
    for (ties) |tie| {
        const here, const there, const other = if (tie.a == index)
            .{ tie.a_at, tie.b_at, tie.b }
        else if (tie.b == index)
            .{ tie.b_at, tie.a_at, tie.a }
        else
            continue;
        if (!placed[other]) continue;
        total += @abs(at.x + here.x - origins[other].x - there.x) + @abs(at.y + here.y - origins[other].y - there.y);
    }
    return total;
}

fn merge(a: Rect, b: Rect) Rect {
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(a.x + a.w, b.x + b.w) - x, .h = @max(a.y + a.h, b.y + b.h) - y };
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
        const apart = ax >= bx + b.w + 160 or bx >= ax + a.w + 160 or ay >= by + b.h + 160 or by >= ay + a.h + 160;
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
    const ties = [_]Tie{.{ .a = 0, .a_at = .{ .x = 1024, .y = 112 }, .b = 1, .b_at = .{ .x = 128, .y = 0 } }};
    _ = pack(&pieces, &ties, 1024, 64, &origins);
    try std.testing.expectEqual(@as(i32, 768), origins[1].x);
}
