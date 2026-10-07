//! Bounded PGE records for content recovery. These source identifiers and parameters are
//! temporary import data; world definitions must assign game meanings before using them.
const std = @import("std");
const motion = @import("../motion.zig");

pub const Record = struct {
    initial_state: u16,
    position: motion.Position,
    rule_group: u16,
    life: i16,
    parameters: [4]i16,
    kind: u8,
    room: u8,
    initially_active: u8,
    visual_flags: u8,
    contact_icon: u8,
    inventory_icon: u8,
    object_id: u8,
    minimum_difficulty: u8,
    facing_right: u8,
    flags: u8,
    collision_width: u8,
    reserved: u8,
    text_id: u16,
};

pub const Table = struct {
    bytes: []const u8,
    count: u16,
    audit: ?*@import("import_audit.zig").Ledger = null,

    pub fn register(self: Table, index: u16, system: @import("import_audit.zig").System) void {
        if (self.audit) |audit| audit.record(index, system);
    }

    pub fn init(bytes: []const u8) !Table {
        if (bytes.len < 2) return error.InvalidPlacementTable;
        const count = word(bytes, 0);
        if (count > 256 or bytes.len != 2 + @as(usize, count) * 32) return error.InvalidPlacementTable;
        return .{ .bytes = bytes[2..], .count = count };
    }

    pub fn record(self: Table, index: u16) !Record {
        if (index >= self.count) return error.MissingPlacement;
        const bytes = self.bytes[@as(usize, index) * 32 ..][0..32];
        return .{
            .initial_state = word(bytes, 0),
            .position = .{ .x = @bitCast(word(bytes, 2)), .y = @bitCast(word(bytes, 4)) },
            .rule_group = word(bytes, 6),
            .life = @bitCast(word(bytes, 8)),
            .parameters = .{ @bitCast(word(bytes, 10)), @bitCast(word(bytes, 12)), @bitCast(word(bytes, 14)), @bitCast(word(bytes, 16)) },
            .kind = bytes[18],
            .room = bytes[19],
            .initially_active = bytes[20],
            .visual_flags = bytes[21],
            .contact_icon = bytes[22],
            .inventory_icon = bytes[23],
            .object_id = bytes[24],
            .minimum_difficulty = bytes[25],
            .facing_right = bytes[26],
            .flags = bytes[27],
            .collision_width = bytes[28],
            .reserved = bytes[29],
            .text_id = word(bytes, 30),
        };
    }
};

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

test "placement records preserve signed values and do not assume every entry is an active actor" {
    var bytes: [34]u8 = @splat(0);
    bytes[0] = 1;
    bytes[4] = 0xfe;
    bytes[5] = 0xff;
    bytes[10] = 0xff;
    bytes[11] = 0xff;
    bytes[21] = 64; // Source's off-map placement, not a valid world room.
    bytes[27] = 33; // An entry excluded from every normal difficulty.
    const table = try Table.init(&bytes);
    const value = try table.record(0);
    try std.testing.expectEqual(@as(i16, -2), value.position.x);
    try std.testing.expectEqual(@as(i16, -1), value.life);
    try std.testing.expectEqual(@as(u8, 64), value.room);
    try std.testing.expectEqual(@as(u8, 33), value.minimum_difficulty);
    try std.testing.expectError(error.MissingPlacement, table.record(1));
    try std.testing.expectError(error.InvalidPlacementTable, Table.init(bytes[0..33]));
    try std.testing.expectError(error.InvalidPlacementTable, Table.init(&.{ 1, 1 }));
}
