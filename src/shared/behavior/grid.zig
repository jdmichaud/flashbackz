//! The collision grid that behavior tables probe: 64 rooms of 7 rows by 16 columns, linked to
//! their neighbors. Probes follow the original's addressing exactly, edge cases included
//! (flashback-re `docs/rules/codes-001-033.md`, section B and C).
const std = @import("std");
const original_memory = @import("original_memory.zig");
const collision = @import("../content/collision.zig");

pub const Side = enum(u2) { up = 0, down = 1, right = 2, left = 3 };

/// A probe either reads a grid byte or lands outside the grid, at an address the caller may
/// resolve (the original then reads unrelated game state) or report.
pub const Read = union(enum) {
    value: i8,
    outside: u16,

    pub fn solid(self: Read) ?bool {
        return switch (self) {
            .value => |v| v != 0,
            .outside => null,
        };
    }
};

pub const Grid = struct {
    /// The original's contiguous layout: four 64-entry neighbor tables (up, down, right,
    /// left), then 64 rooms of 112 cells. Out-of-range reads fall through to adjacent bytes,
    /// as in the original.
    bytes: [layout_size]u8,

    pub const layout_size = collision.size;
    pub const columns = collision.columns;
    pub const rows = collision.rows;
    const cells_per_room = rows * columns;

    pub fn init(decoded: []const u8) !Grid {
        if (decoded.len != layout_size) return error.InvalidCollisionLayout;
        var grid: Grid = undefined;
        @memcpy(&grid.bytes, decoded);
        return grid;
    }

    /// The room on `side`, or null where the original treats the link as missing.
    pub fn neighbor(self: *const Grid, room: u8, side: Side) ?u8 {
        const value = self.signedLink(room, side) orelse return null;
        return if (value < 0) null else @intCast(value);
    }

    /// The byte at row and column of a room record, without crossing into neighbors. Rows and
    /// columns outside the room continue into the bytes that follow or precede it.
    pub fn cell(self: *const Grid, room: u8, row: i32, column: i32) Read {
        const offset = 256 + @as(i32, room) * cells_per_room + row * columns + column;
        const b = self.byte(offset) orelse
            return .{ .outside = original_memory.gridAddress(offset) };
        return .{ .value = @bitCast(b) };
    }

    /// A terrain probe: `row` and `column` are the probe point in the character's room. A
    /// horizontal crossing wins over a vertical one, and only one link is followed.
    pub fn probe(self: *const Grid, room: u8, row: i32, column: i32) Read {
        if (column < 0) {
            const left = self.signedLink(room, .left) orelse return .{ .value = 1 };
            if (left < 0) return .{ .value = 1 };
            return self.cell(@intCast(left), row, column + columns);
        }
        if (column >= columns) {
            // The original tests the right link after zero-extending it, so a missing right
            // neighbor (0xff) is never noticed and the read lands past the grid.
            const link = self.signedLink(room, .right) orelse
                return .{ .outside = original_memory.gridAddress(0) };
            const right: u8 = @bitCast(link);
            return self.cell(right, row, column - columns);
        }
        if (row < 1) {
            const up = self.signedLink(room, .up) orelse return .{ .value = 1 };
            if (up < 0) return .{ .value = 1 };
            return self.cell(@intCast(up), row + rows - 1, column);
        }
        if (row >= rows) {
            const down = self.signedLink(room, .down) orelse return .{ .value = 1 };
            if (down < 0) return .{ .value = 1 };
            return self.cell(@intCast(down), row - (rows - 1), column);
        }
        return self.cell(room, row, column);
    }

    /// Writes a cell inside a room; terrain changes never cross rooms.
    pub fn set(self: *Grid, room: u8, row: u8, column: u8, value: u8) void {
        const offset = 256 + @as(usize, room) * cells_per_room + @as(usize, row) * columns + column;
        self.bytes[offset] = value;
    }

    /// The link byte as stored: a room, or 0xff where there is none.
    pub fn rawLink(self: *const Grid, room: u8, side: Side) u8 {
        return @bitCast(self.signedLink(room, side) orelse -1);
    }

    /// The raw link byte, as the original reads it; rooms past 63 read the next table.
    fn signedLink(self: *const Grid, room: u8, side: Side) ?i8 {
        const b = self.byte(@as(i32, @backingInt(side)) * 64 + room) orelse return null;
        return @bitCast(b);
    }

    fn byte(self: *const Grid, offset: i32) ?u8 {
        if (offset < 0 or offset >= layout_size) return null;
        return self.bytes[@intCast(offset)];
    }
};

/// The column a character stands in: `(x + 8) >> 4`, rounding toward negative infinity.
pub fn columnOf(x: i16) i16 {
    return (x +% 8) >> 4;
}

// A room's height holds three tiers of 72 pixels. The original computes a character's tier in
// five ways, each kept where the original uses it; they differ for heights above the room
// (negative y) and near a tier's top (see the test below).

/// The character's tier as a row index (0, 2 or 4): `(y / 36) & ~1`, truncating. The update
/// loop zero-extends the quotient's low byte, so heights from -71 to -36 give row 254.
pub fn bandOf(y: i16) i16 {
    const quotient: u8 = @truncate(@as(u16, @bitCast(@divTrunc(y, 36))));
    return quotient & 0xfe;
}

/// `bandOf`, the quotient sign-extended, as when a message ends an animation early: heights from
/// -71 to -36 give row -2.
pub fn bandSignExtended(y: i16) i16 {
    const quotient: i8 = @truncate(@divTrunc(y, 36));
    return @as(i16, quotient) & ~@as(i16, 1);
}

/// `bandOf` with y read as unsigned, as the terrain writers compute it: a negative y gives a row
/// far below the room.
pub fn bandUnsigned(y: i16) i16 {
    return @intCast((@as(u16, @bitCast(y)) / 36) & 0xfffe);
}

/// The tier of a character's height: 0, 1 or 2 in the room.
pub fn tierOf(y: i16) i16 {
    return @divTrunc(y, 72);
}

/// The tier of a contact cell, and of Conrad's height as others see him: 8 pixels higher.
pub fn contactTierOf(y: i16) i16 {
    return @divTrunc(y -% 8, 72);
}

fn testGrid() Grid {
    var grid: Grid = .{ .bytes = @splat(0) };
    // Rooms 0 and 1 side by side; room 2 below room 0; room 0 has no left or up neighbor.
    for (0..64) |r| {
        grid.bytes[r] = 0xff; // up
        grid.bytes[64 + r] = 0xff; // down
        grid.bytes[128 + r] = 0xff; // right
        grid.bytes[192 + r] = 0xff; // left
    }
    grid.bytes[128 + 0] = 1;
    grid.bytes[192 + 1] = 0;
    grid.bytes[64 + 0] = 2;
    grid.bytes[0 + 2] = 0;
    grid.set(1, 3, 2, 1);
    grid.set(2, 2, 5, 1);
    return grid;
}

test "probes cross one link to the left, right and below" {
    const grid = testGrid();
    try std.testing.expectEqual(@as(?bool, true), grid.probe(0, 3, 18).solid());
    try std.testing.expectEqual(@as(?bool, false), grid.probe(0, 3, 17).solid());
    try std.testing.expectEqual(@as(?bool, true), grid.probe(0, 8, 5).solid());
    try std.testing.expectEqual(@as(?bool, false), grid.probe(1, 3, -14).solid());
}

test "missing left and up links are solid; a missing right link reads past the grid" {
    const grid = testGrid();
    try std.testing.expectEqual(@as(?bool, true), grid.probe(0, 3, -1).solid());
    try std.testing.expectEqual(@as(?bool, true), grid.probe(0, 0, 3).solid());
    // Room 1 has no right neighbor: 0x3e46 + 0xff * 0x70 + 5 * 16 + (16 - 16).
    try std.testing.expectEqual(Read{ .outside = 0xae26 }, grid.probe(1, 5, 16));
}

test "corner probes keep the row and run into the neighboring record" {
    const grid = testGrid();
    // Row 7 of room 0 is row 0 of room 1 in memory, reached without following a link.
    try std.testing.expectEqual(grid.cell(1, 0, 4), grid.cell(0, 7, 4));
}

test "column and tier follow the original arithmetic" {
    try std.testing.expectEqual(@as(i16, 7), columnOf(112));
    try std.testing.expectEqual(@as(i16, -1), columnOf(-10));
    try std.testing.expectEqual(@as(i16, 4), bandOf(214));
    try std.testing.expectEqual(@as(i16, 0), bandOf(35));
    try std.testing.expectEqual(@as(i16, 254), bandOf(-40));
}

test "the tier variants agree in the room and differ above it and near a tier's top" {
    for ([_]i16{ 70, 142, 214 }, [_]i16{ 0, 2, 4 }, [_]i16{ 0, 1, 2 }) |y, row, tier| {
        try std.testing.expectEqual(row, bandOf(y));
        try std.testing.expectEqual(row, bandSignExtended(y));
        try std.testing.expectEqual(row, bandUnsigned(y));
        try std.testing.expectEqual(tier, tierOf(y));
        try std.testing.expectEqual(tier, contactTierOf(y));
    }
    // 40 pixels above the room.
    try std.testing.expectEqual(@as(i16, 254), bandOf(-40));
    try std.testing.expectEqual(@as(i16, -2), bandSignExtended(-40));
    try std.testing.expectEqual(@as(i16, 1818), bandUnsigned(-40));
    try std.testing.expectEqual(@as(i16, 0), tierOf(-40));
    // The top 8 pixels of a tier count as the tier above for contacts.
    try std.testing.expectEqual(@as(i16, 1), tierOf(75));
    try std.testing.expectEqual(@as(i16, 0), contactTierOf(75));
}
