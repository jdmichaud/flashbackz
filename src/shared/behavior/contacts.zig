//! Which characters share which cells. Before each update every relevant character
//! registers the cells it covers: from its position, `width` cells to the right, on its tier.
//! Cells shared by several characters form a slot; checks such as `touching` and `sees`
//! read the slots. The model keeps the original's storage (flashback-re engine notes,
//! section 2): slots are numbered by first appearance, a slot lists its newest registration
//! first, and slots beyond this update's count keep their older contents.
const std = @import("std");
const grid = @import("grid.zig");

pub const Key = u16;
pub const no_slot: u8 = 0xff;
pub const capacity = 256;

/// The characters that met in a cell as one registered: the newcomer and the cell's newest,
/// for each of at most a room's 16 columns.
pub const Shared = struct {
    items: [2 * grid.Grid.columns]u16 = undefined,
    len: usize = 0,

    fn add(self: *Shared, character: u16) void {
        self.items[self.len] = character;
        self.len += 1;
    }

    pub fn slice(self: *const Shared) []const u16 {
        return self.items[0..self.len];
    }
};

pub const Entry = struct {
    key: Key = 0,
    /// The next entry in the same slot.
    next: ?u16 = null,
    character: u16 = 0,
    /// The same character's next slot, if it covers more cells.
    next_slot: ?u8 = null,
};

pub const Contacts = struct {
    entries: [capacity]Entry = @splat(.{}),
    entry_count: u16 = 0,
    /// Each slot's newest entry. Slots at or past `slot_count` hold older contents.
    slots: [capacity]?u16 = @splat(null),
    slot_count: u8 = 0,
    /// The view room and its left and right neighbors, by tier and column: slot or none.
    window: [3 * 48]u8 = @splat(no_slot),

    pub fn begin(self: *Contacts) void {
        self.entry_count = 0;
        self.slot_count = 0;
    }

    /// The cell key at `x + offset`, or null where the original has none: after crossing
    /// into a neighbor on one axis only, on column 16 or outside the three tiers.
    pub fn cellKey(collision: *const grid.Grid, room_in: u8, x_in: i16, y_in: i16) ?Key {
        var room = room_in;
        var x: i32 = x_in;
        var y: i32 = y_in;
        if (room >= 128) return null;
        if (x < 0) {
            room = collision.neighbor(room, .left) orelse return null;
            x += 256;
        } else if (x >= 256) {
            room = collision.neighbor(room, .right) orelse return null;
            x -= 256;
        } else if (y < 0) {
            room = collision.neighbor(room, .up) orelse return null;
            y += 216;
        } else if (y >= 216) {
            room = collision.neighbor(room, .down) orelse return null;
            y -= 216;
        }
        const column = (x + 8) >> 4;
        if (column > 15) return null;
        const band = grid.contactTierOf(@intCast(y));
        if (band < 0 or band > 2) return null;
        return @intCast(@as(i32, room) * 64 + band * 16 + column);
    }

    /// Registers `width` cells from `x` (at most a room's columns, as the data-set loader
    /// checks), adding to `shared` the characters that meet in a cell. Returns the first slot,
    /// or null when the pool is full before the first cell (the original then keeps the
    /// character's old slot).
    pub fn register(
        self: *Contacts,
        collision: *const grid.Grid,
        character: u16,
        room: u8,
        x: i16,
        y: i16,
        width: u8,
        shared: *Shared,
    ) ?u8 {
        if (width == 0) return no_slot;
        var first: ?u8 = null;
        var previous: ?u16 = null;
        for (0..width) |k| {
            if (self.entry_count == capacity) return first;
            const entry_index = self.entry_count;
            self.entry_count += 1;
            const key = cellKey(collision, room, x +% @as(i16, @intCast(k * 16)), y) orelse {
                if (previous) |p| self.entries[p].next_slot = null;
                return first orelse no_slot;
            };
            const slot = self.find(key);
            const head = if (slot) |s| self.slots[s] else null;
            self.entries[entry_index] = .{ .key = key, .next = head, .character = character };
            const used = slot orelse new: {
                const s = self.slot_count;
                self.slot_count +%= 1;
                break :new s;
            };
            self.slots[used] = entry_index;
            if (slot != null) {
                shared.add(character);
                if (head) |h| shared.add(self.entries[h].character);
            }
            if (previous) |p| self.entries[p].next_slot = used else first = used;
            previous = entry_index;
        }
        return first;
    }

    fn find(self: *const Contacts, key: Key) ?u8 {
        for (self.slots[0..self.slot_count], 0..) |head, slot| {
            const entry = head orelse continue;
            if (self.entries[entry].key == key) return @intCast(slot);
        }
        return null;
    }

    /// Fill the window for the view room and its neighbors from this update's slots.
    pub fn buildWindow(self: *Contacts, collision: *const grid.Grid, view_room: u8) void {
        self.window = @splat(no_slot);
        const left = collision.rawLink(view_room, .left);
        const right = collision.rawLink(view_room, .right);
        for (self.slots[0..self.slot_count], 0..) |head, slot| {
            const key = self.entries[head orelse continue].key;
            const room: u8 = @truncate(key >> 6);
            const base: usize = if (room == view_room)
                48
            else if (room == left)
                0
            else if (room == right)
                96
            else
                continue;
            self.window[base + (key & 0x3f)] = @intCast(slot);
        }
    }

    /// Characters in a slot, newest registration first.
    pub fn occupants(self: *const Contacts, slot: u8) Occupants {
        return .{ .contacts = self, .next = self.slots[slot] };
    }

    pub const Occupants = struct {
        contacts: *const Contacts,
        next: ?u16,
        pub fn nextEntry(self: *Occupants) ?Entry {
            const index = self.next orelse return null;
            const entry = self.contacts.entries[index];
            self.next = entry.next;
            return entry;
        }
    };
};

test "cell keys cross one axis and reject column 16" {
    var layout: [grid.Grid.layout_size]u8 = @splat(0);
    @memset(layout[0..256], 0xff);
    layout[128 + 3] = 4; // room 3's right neighbor is room 4
    const collision = try grid.Grid.init(&layout);
    try std.testing.expectEqual(
        @as(?Key, 3 * 64 + 2 * 16 + 7),
        Contacts.cellKey(&collision, 3, 112, 214),
    );
    try std.testing.expectEqual(
        @as(?Key, 4 * 64 + 2 * 16 + 1),
        Contacts.cellKey(&collision, 3, 272, 214),
    );
    try std.testing.expectEqual(@as(?Key, null), Contacts.cellKey(&collision, 3, 250, 214));
    try std.testing.expectEqual(@as(?Key, null), Contacts.cellKey(&collision, 3, -16, 214));
}

test "shared cells form one slot, newest registration first" {
    var layout: [grid.Grid.layout_size]u8 = @splat(0);
    @memset(layout[0..256], 0xff);
    const collision = try grid.Grid.init(&layout);
    var contacts: Contacts = .{};
    var shared: Shared = .{};
    contacts.begin();
    const a = contacts.register(&collision, 7, 1, 100, 214, 2, &shared);
    const b = contacts.register(&collision, 9, 1, 116, 214, 1, &shared);
    try std.testing.expectEqual(@as(?u8, 0), a);
    try std.testing.expectEqual(@as(?u8, 1), b);
    var in_slot = contacts.occupants(1);
    try std.testing.expectEqual(@as(u16, 9), in_slot.nextEntry().?.character);
    try std.testing.expectEqual(@as(u16, 7), in_slot.nextEntry().?.character);
    try std.testing.expectEqualSlices(u16, &.{ 9, 7 }, shared.slice());
}
