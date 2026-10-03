//! Player equipment and its observable quantities, independently of source entity records.
//! Starting supplies arrive after their introduction finishes. Possessions keep stable
//! handles for the session; this collection does not remove or reuse item slots.
const std = @import("std");
const inventory = @import("inventory.zig");
const motion = @import("motion.zig");
pub const ItemHandle = @import("identity.zig").ItemHandle;
pub const Kind = enum { gun, shield, credits };
pub const Definition = struct {
    kind: Kind,
    icon: motion.VisualId,
    introduction_steps: u16,
    initial_quantity: i16,
    label: []const u8 = "",
    show_quantity: bool = false,
};
pub const Item = struct {
    definition: Definition,
    state: union(enum) { introducing: u16, carried },
    quantity: i16,
};
pub const Received = struct { item: ItemHandle, kind: Kind };

pub const Loadout = struct {
    allocator: std.mem.Allocator,
    entries: []Item,
    inventory: inventory.Inventory,

    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !Loadout {
        if (definitions.len > 65535) return error.TooManyStartingItems;
        const entries = try allocator.alloc(Item, definitions.len);
        errdefer allocator.free(entries);
        for (entries, definitions) |*entry, definition| entry.* = .{
            .definition = definition,
            .state = .{ .introducing = definition.introduction_steps },
            .quantity = definition.initial_quantity,
        };
        return .{ .allocator = allocator, .entries = entries, .inventory = try inventory.Inventory.init(allocator, entries.len) };
    }

    pub fn deinit(self: *Loadout) void {
        self.inventory.deinit();
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn item(self: *const Loadout, handle: ItemHandle) !*const Item {
        if (handle.generation != 1 or handle.index >= self.entries.len) return error.InvalidItemHandle;
        return &self.entries[handle.index];
    }

    pub fn selected(self: *const Loadout) !?*const Item {
        return if (self.inventory.selected()) |handle| try self.item(handle) else null;
    }

    /// Events retain definition order when multiple introductions finish together. Event
    /// storage and inventory capacity are reserved at load time; updates never allocate.
    pub fn advance(self: *Loadout, health: i16, events: []Received) !usize {
        if (events.len < self.entries.len) return error.EventBufferTooSmall;
        var count: usize = 0;
        for (self.entries, 0..) |*entry, index| {
            switch (entry.state) {
                .introducing => |remaining| {
                    if (remaining != 0) {
                        entry.state = .{ .introducing = remaining - 1 };
                        continue;
                    }
                    const handle: ItemHandle = .{ .index = @intCast(index), .generation = 1 };
                    try inventory.transfer(handle, null, &self.inventory);
                    entry.state = .carried;
                    events[count] = .{ .item = handle, .kind = entry.definition.kind };
                    count += 1;
                },
                .carried => {},
            }
            if (entry.definition.kind == .shield) entry.quantity = shieldCharge(health);
        }
        return count;
    }

    pub fn hashInto(self: *const Loadout, hash: *std.hash.Wyhash) void {
        for (self.entries) |entry| {
            const pending: u32 = switch (entry.state) {
                .introducing => |steps| @as(u32, steps) + 1,
                .carried => 0,
            };
            for ([_]u32{ @backingInt(entry.definition.kind), @as(u16, @bitCast(entry.quantity)), pending }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
        for (self.inventory.items()) |handle| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, handle.index)));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, handle.generation)));
        }
    }
};

pub fn shieldCharge(health: i16) i16 {
    return health -% 1;
}

test "supplies arrive after their introductions and preserve simultaneous arrival order" {
    const definitions = [_]Definition{
        .{ .kind = .gun, .icon = @fromBackingInt(4), .introduction_steps = 3, .initial_quantity = 1 },
        .{ .kind = .shield, .icon = @fromBackingInt(8), .introduction_steps = 1, .initial_quantity = 0 },
        .{ .kind = .credits, .icon = @fromBackingInt(3), .introduction_steps = 3, .initial_quantity = 7 },
    };
    var loadout = try Loadout.init(std.testing.allocator, &definitions);
    defer loadout.deinit();
    var events: [3]Received = undefined;
    try std.testing.expectError(error.EventBufferTooSmall, loadout.advance(5, events[0..2]));
    try std.testing.expectEqual(@as(usize, 0), try loadout.advance(5, &events));
    try std.testing.expect((try loadout.selected()) == null);
    try std.testing.expectEqual(@as(usize, 1), try loadout.advance(5, &events));
    try std.testing.expectEqual(.shield, events[0].kind);
    try std.testing.expectEqual(@as(i16, 4), (try loadout.selected()).?.quantity);
    _ = try loadout.advance(3, &events);
    try std.testing.expectEqual(@as(i16, 2), (try loadout.selected()).?.quantity);
    try std.testing.expectEqual(@as(usize, 2), try loadout.advance(3, &events));
    try std.testing.expectEqual(.gun, events[0].kind);
    try std.testing.expectEqual(.credits, events[1].kind);
    try std.testing.expectEqual(@as(u16, 1), loadout.inventory.items()[0].index);
    try std.testing.expectEqual(@as(u16, 0), loadout.inventory.items()[1].index);
    try std.testing.expectEqual(@as(u16, 2), loadout.inventory.items()[2].index);
    try std.testing.expectEqual(@as(usize, 0), try loadout.advance(3, &events));
    try std.testing.expectError(error.InvalidItemHandle, loadout.item(.{ .index = 1, .generation = 2 }));
}
