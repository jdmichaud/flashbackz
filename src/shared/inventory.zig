//! An actor's ordered possessions. The first item is selected; selecting another item
//! moves it to the front while preserving the relative order of all remaining items.
const std = @import("std");
pub const ItemHandle = identity.ItemHandle;
const identity = @import("identity.zig");

pub const Inventory = struct {
    allocator: std.mem.Allocator,
    storage: []ItemHandle,
    length: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Inventory {
        return .{ .allocator = allocator, .storage = try allocator.alloc(ItemHandle, capacity) };
    }

    pub fn deinit(self: *Inventory) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn items(self: *const Inventory) []const ItemHandle {
        return self.storage[0..self.length];
    }

    pub fn selected(self: *const Inventory) ?ItemHandle {
        return if (self.length == 0) null else self.storage[0];
    }

    fn indexOf(self: *const Inventory, item: ItemHandle) ?usize {
        for (self.items(), 0..) |candidate, i| if (candidate.eql(item)) return i;
        return null;
    }

    pub fn contains(self: *const Inventory, item: ItemHandle) bool {
        return self.indexOf(item) != null;
    }

    pub fn select(self: *Inventory, item: ItemHandle) bool {
        const index = self.indexOf(item) orelse return false;
        std.mem.copyBackwards(ItemHandle, self.storage[1 .. index + 1], self.storage[0..index]);
        self.storage[0] = item;
        return true;
    }

    pub fn remove(self: *Inventory, item: ItemHandle) bool {
        const index = self.indexOf(item) orelse return false;
        std.mem.copyForwards(
            ItemHandle,
            self.storage[index .. self.length - 1],
            self.storage[index + 1 .. self.length],
        );
        self.length -= 1;
        return true;
    }
};

/// Transfer appends to the destination, including a transfer within the same inventory.
/// Validate before removal so a full destination cannot lose an item from its source.
pub fn transfer(item: ItemHandle, source: ?*Inventory, destination: *Inventory) !void {
    if (source) |from| if (!from.contains(item)) return error.ItemNotOwned;
    const same = if (source) |from| from == destination else false;
    if (!same) {
        if (destination.contains(item)) return error.DuplicateInventoryItem;
        if (destination.length == destination.storage.len) return error.InventoryFull;
    }
    if (source) |from| _ = from.remove(item);
    destination.storage[destination.length] = item;
    destination.length += 1;
}

test "selection and transfer preserve observable inventory order" {
    var bag = try Inventory.init(std.testing.allocator, 3);
    defer bag.deinit();
    const a: ItemHandle = .{ .index = 2, .generation = 1 };
    const b: ItemHandle = .{ .index = 7, .generation = 1 };
    const c: ItemHandle = .{ .index = 4, .generation = 3 };
    for ([_]ItemHandle{ a, b, c }) |item| try transfer(item, null, &bag);
    try std.testing.expect(bag.select(c));
    try std.testing.expectEqualSlices(ItemHandle, &.{ c, a, b }, bag.items());
    try transfer(c, &bag, &bag);
    try std.testing.expectEqualSlices(ItemHandle, &.{ a, b, c }, bag.items());
    try std.testing.expect(bag.remove(a));
    try std.testing.expect(bag.selected().?.eql(b));
    try std.testing.expect(!bag.select(.{ .index = b.index, .generation = 2 }));
}

test "ownership and capacity failures leave both inventories intact" {
    var source = try Inventory.init(std.testing.allocator, 2);
    defer source.deinit();
    var destination = try Inventory.init(std.testing.allocator, 1);
    defer destination.deinit();
    const a: ItemHandle = .{ .index = 0, .generation = 1 };
    const b: ItemHandle = .{ .index = 1, .generation = 1 };
    try transfer(a, null, &source);
    try transfer(b, null, &destination);
    try std.testing.expectError(error.InventoryFull, transfer(a, &source, &destination));
    try std.testing.expect(source.contains(a));
    try std.testing.expect(destination.contains(b));
    try std.testing.expectError(error.ItemNotOwned, transfer(b, &source, &destination));
    try std.testing.expectError(error.DuplicateInventoryItem, transfer(b, null, &destination));
    try std.testing.expect(destination.remove(b));
    try transfer(a, &source, &destination);
    try std.testing.expectEqual(@as(usize, 0), source.items().len);
    try std.testing.expect(destination.selected().?.eql(a));
}
