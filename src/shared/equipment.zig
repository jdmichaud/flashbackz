//! Player equipment and its observable quantities, independently of source entity records.
//! Starting supplies arrive after their introduction finishes. Possessions keep stable
//! handles for the session; this collection does not remove or reuse item slots.
const std = @import("std");
const inventory = @import("inventory.zig");
const motion = @import("motion.zig");
pub const ItemHandle = @import("identity.zig").ItemHandle;
pub const Kind = enum {
    gun,
    shield,
    credits,
    holocube,
    teleporter,
    stone,
    key,
    cartridge,
    id_card,
    anti_g_belt,
    force_field,
    fuse,
    work_permit,
    parcel,
    papers,
    mission_time,
    terminal_card,
    photo,
};
pub const Credential = union(enum) { fixed: i16, item_charge };
pub const Recharge = struct {
    movie_when: enum { start, completion } = .completion,
    delay_steps: u16,
    restore: union(enum) { player_health: i16, item_charge: i16 },
    movie: @import("story_cue.zig").Cue,
};
pub const Recharged = struct {
    item: ItemHandle,
    health: ?i16,
    movie: ?@import("story_cue.zig").Cue,
};
pub const Definition = struct {
    consumption_movie: ?@import("story_cue.zig").Cue = null,
    consumption_notice: ?@import("world_messages.zig").Id = null,
    recharge: ?Recharge = null,
    use_motion: enum { direct, reach } = .direct,
    kind: Kind,
    icon: motion.VisualId,
    /// Null leaves the instance available for a world pickup.
    introduction_steps: ?u16,
    initial_quantity: i16,
    label: []const u8 = "",
    show_quantity: bool = false,
    use_action: ?union(enum) {
        story: @import("story_cue.zig").Cue,
        throw_item,
        pay,
        deploy_field,
        offer: struct { credential: i16 },
        unlock: struct {
            credential: Credential,
            consume_after_steps: ?u16,
            movie: ?@import("story_cue.zig").Cue = null,
        },
    } = null,
};
pub const Item = struct {
    definition: Definition,
    state: union(enum) { introducing: u16, available, carried, consumed },
    quantity: i16,
    consume_in: ?u16 = null,
    recharge_in: ?u16 = null,
};
pub const Received = struct { item: ItemHandle, kind: Kind };

pub const Loadout = struct {
    allocator: std.mem.Allocator,
    entries: []Item,
    inventory: inventory.Inventory,
    recharged: ?Recharged = null,
    notice: ?@import("world_messages.zig").Id = null,
    used_movie: ?@import("story_cue.zig").Cue = null,

    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !Loadout {
        if (definitions.len > 65535) return error.TooManyStartingItems;
        const entries = try allocator.alloc(Item, definitions.len);
        errdefer allocator.free(entries);
        for (entries, definitions) |*entry, definition| entry.* = .{
            .definition = definition,
            .state = if (definition.introduction_steps) |steps| .{ .introducing = steps } else .available,
            .quantity = definition.initial_quantity,
        };
        return .{
            .allocator = allocator,
            .entries = entries,
            .inventory = try inventory.Inventory.init(allocator, entries.len),
        };
    }

    pub fn deinit(self: *Loadout) void {
        self.inventory.deinit();
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn item(self: *const Loadout, handle: ItemHandle) !*const Item {
        if (handle.generation != 1 or
            handle.index >= self.entries.len) return error.InvalidItemHandle;
        return &self.entries[handle.index];
    }

    pub fn acquire(self: *Loadout, handle: ItemHandle) !void {
        const entry = try self.item(handle);
        if (entry.state != .available) return error.ItemNotAvailable;
        try inventory.transfer(handle, null, &self.inventory);
        self.entries[handle.index].state = .carried;
    }

    pub fn grant(self: *Loadout, handle: ItemHandle) !void {
        const entry = try self.item(handle);
        if (entry.state != .available and
            entry.state != .carried and
            entry.state != .consumed) return error.ItemNotGrantable;
        try inventory.transfer(
            handle,
            if (entry.state == .carried) &self.inventory else null,
            &self.inventory,
        );
        self.entries[handle.index].state = .carried;
    }
    pub fn credit(self: *Loadout, handle: ItemHandle, amount: i16) !void {
        _ = try self.item(handle);
        self.entries[handle.index].quantity +%= amount;
    }

    pub fn debit(self: *Loadout, handle: ItemHandle, amount: i16) !void {
        _ = try self.item(handle);
        self.entries[handle.index].quantity -%= amount;
    }

    pub fn release(self: *Loadout, handle: ItemHandle) !void {
        if ((try self.item(handle)).state != .carried) return error.ItemNotCarried;
        if (!self.inventory.remove(handle)) return error.ItemNotCarried;
        self.entries[handle.index].state = .available;
    }

    /// Quantity pickups disappear into an existing possession rather than adding a
    /// duplicate inventory slot. Consume the ground handle exactly once.
    pub fn consumeInto(self: *Loadout, pickup: ItemHandle, target: ItemHandle, amount: i16) !void {
        if ((try self.item(pickup)).state != .available) return error.ItemNotAvailable;
        if ((try self.item(target)).state != .carried) return error.ItemNotCarried;
        self.entries[target.index].quantity +%= amount;
        self.entries[pickup.index].state = .consumed;
    }

    pub fn beginRecharge(self: *Loadout, handle: ItemHandle) !bool {
        const entry = try self.item(handle);
        const capability = entry.definition.recharge orelse return false;
        if (entry.state != .carried or entry.recharge_in != null) return false;
        self.entries[handle.index].recharge_in = capability.delay_steps;
        return true;
    }

    pub fn consume(self: *Loadout, handle: ItemHandle) !void {
        if ((try self.item(handle)).state != .carried) return error.ItemNotCarried;
        if (!self.inventory.remove(handle)) return error.ItemNotCarried;
        self.entries[handle.index].state = .consumed;
        self.entries[handle.index].consume_in = null;
        self.entries[handle.index].recharge_in = null;
    }

    pub fn consumeAfter(self: *Loadout, handle: ItemHandle, steps: u16) !void {
        if ((try self.item(handle)).state != .carried) return error.ItemNotCarried;
        self.entries[handle.index].consume_in = steps;
    }

    pub fn carries(self: *const Loadout, kind: Kind) bool {
        for (self.entries) |entry| if (entry.state == .carried and
            entry.definition.kind == kind) return true;
        return false;
    }

    pub fn selected(self: *const Loadout) !?*const Item {
        return if (self.inventory.selected()) |handle| try self.item(handle) else null;
    }

    /// Events retain definition order when multiple introductions finish together. Event
    /// storage and inventory capacity are reserved at load time; updates never allocate.
    pub fn advance(self: *Loadout, health: i16, events: []Received) !usize {
        if (events.len < self.entries.len) return error.EventBufferTooSmall;
        var count: usize = 0;
        self.recharged = null;
        self.notice = null;
        self.used_movie = null;
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
                .available, .consumed => continue,
                .carried => {},
            }
            if (entry.consume_in) |remaining| {
                if (remaining <= 1) {
                    const handle: ItemHandle = .{ .index = @intCast(index), .generation = 1 };
                    if (!self.inventory.remove(handle)) return error.ItemNotCarried;
                    self.notice = entry.definition.consumption_notice;
                    self.used_movie = entry.definition.consumption_movie;
                    entry.state = .consumed;
                    entry.consume_in = null;
                } else entry.consume_in = remaining - 1;
            }
            const charging = entry.recharge_in != null;
            if (entry.recharge_in) |remaining| {
                if (remaining <= 1) {
                    const capability = entry.definition.recharge orelse return error.MissingRechargeCapability;
                    var restored_health: ?i16 = null;
                    switch (capability.restore) {
                        .player_health => |value| restored_health = value,
                        .item_charge => |value| entry.quantity = value,
                    }
                    self.recharged = .{
                        .item = .{ .index = @intCast(index), .generation = 1 },
                        .health = restored_health,
                        .movie = if (capability.movie_when == .completion) capability.movie else null,
                    };
                    entry.recharge_in = null;
                } else entry.recharge_in = remaining - 1;
            }
            if (entry.definition.kind == .shield and
                !charging) entry.quantity = shieldCharge(health);
        }
        return count;
    }

    pub fn hashInto(self: *const Loadout, hash: *std.hash.Wyhash) void {
        for (self.entries) |entry| {
            const pending: u32 = switch (entry.state) {
                .introducing => |steps| @as(u32, steps) + 1,
                .carried => 0,
                .available => std.math.maxInt(u32),
                .consumed => std.math.maxInt(u32) - 1,
            };
            for ([_]u32{
                @backingInt(entry.definition.kind),
                @as(u16, @bitCast(entry.quantity)),
                pending,
                if (entry.consume_in) |steps| @as(u32, steps) + 1 else 0,
                if (entry.recharge_in) |steps| @as(u32, steps) + 1 else 0,
            }) |value|
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

test "quantity pickup updates the existing purse exactly once" {
    const definitions = [_]Definition{
        .{
            .kind = .credits,
            .icon = @fromBackingInt(1),
            .introduction_steps = 0,
            .initial_quantity = 7,
        },
        .{
            .kind = .credits,
            .icon = @fromBackingInt(2),
            .introduction_steps = null,
            .initial_quantity = 100,
        },
    };
    var loadout = try Loadout.init(std.testing.allocator, &definitions);
    defer loadout.deinit();
    var received: [2]Received = undefined;
    _ = try loadout.advance(5, &received);
    const purse: ItemHandle = .{ .index = 0, .generation = 1 };
    const ground: ItemHandle = .{ .index = 1, .generation = 1 };
    try loadout.consumeInto(ground, purse, 100);
    try std.testing.expectEqual(@as(i16, 107), (try loadout.item(purse)).quantity);
    try std.testing.expectEqual(@as(usize, 1), loadout.inventory.items().len);
    try std.testing.expect((try loadout.item(ground)).state == .consumed);
    try std.testing.expectError(error.ItemNotAvailable, loadout.consumeInto(ground, purse, 100));
}

test "supplies arrive after their introductions and preserve simultaneous arrival order" {
    const definitions = [_]Definition{
        .{
            .kind = .gun,
            .icon = @fromBackingInt(4),
            .introduction_steps = 3,
            .initial_quantity = 1,
        },
        .{
            .kind = .shield,
            .icon = @fromBackingInt(8),
            .introduction_steps = 1,
            .initial_quantity = 0,
        },
        .{
            .kind = .credits,
            .icon = @fromBackingInt(3),
            .introduction_steps = 3,
            .initial_quantity = 7,
        },
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
    try std.testing.expectError(
        error.InvalidItemHandle,
        loadout.item(.{ .index = 1, .generation = 2 }),
    );
}

test "a repeatable grant can reissue a consumed possession without duplicating its handle" {
    const definitions = [_]Definition{.{
        .kind = .papers,
        .icon = @fromBackingInt(0),
        .introduction_steps = null,
        .initial_quantity = 51,
    }};
    var loadout = try Loadout.init(std.testing.allocator, &definitions);
    defer loadout.deinit();
    const handle: ItemHandle = .{ .index = 0, .generation = 1 };
    try loadout.grant(handle);
    try loadout.consume(handle);
    try loadout.grant(handle);
    try loadout.grant(handle);
    try std.testing.expectEqual(@as(usize, 1), loadout.inventory.items().len);
    try std.testing.expect(loadout.inventory.selected().?.eql(handle));
    try std.testing.expectEqual(@as(i16, 51), (try loadout.item(handle)).quantity);
}
