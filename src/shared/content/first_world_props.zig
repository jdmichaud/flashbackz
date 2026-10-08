//! Discover supported collectible and pressure-switch families in level data. Source
//! IDs and rule layouts stop here; the world owns ordinary objects and named effects.
const std = @import("std");
const placement = @import("placement.zig");
const animation = @import("animation.zig");
const equipment = @import("../equipment.zig");
const world = @import("../world_props.zig");
const geometry = @import("../geometry.zig");
const strings = @import("string_table.zig");
const cartridges = @import("cartridges.zig");
const credential_cards = @import("credential_cards.zig");
const credit_pickups = @import("credit_pickups.zig");
const credit_wallet = @import("credit_wallet.zig");
const inventory_grants = @import("inventory_grants.zig");
const key_pickups = @import("key_pickups.zig");
const motion = @import("../motion.zig");
const pressure_controls = @import("pressure_controls.zig");
const quest_items = @import("quest_items.zig");
const rule_table = @import("rule_table.zig");
const settings = @import("../settings.zig");
const thrown_item = @import("thrown_item.zig");
const timed_items = @import("timed_items.zig");

// Import-only endpoints let other content importers bind the same opaque circuit.
pub const Connection = struct {
    circuit: world.CircuitId,
    sender: u16,
    recipient: u16,
    message: i16,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    clips: []animation.OwnedClip,
    definitions: []world.Definition,
    items: []equipment.Definition,
    connections: []Connection,
    /// Import-only item provenance for binding item-to-mechanism delivery order.
    item_sources: []u16,
    hint_icon: motion.VisualId,
    pub fn deinit(self: *Assets) void {
        releaseThrows(self.allocator, self.definitions);
        self.allocator.free(self.definitions);
        self.allocator.free(self.connections);
        self.allocator.free(self.item_sources);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        for (self.items) |item| self.allocator.free(item.label);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};
fn firstRule(bytes: []const u8, group: u16, state: u16) ![]const u8 {
    if (bytes.len < 2) return error.InvalidPropRules;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    const body = bytes[2..];
    if (count > 256 or
        group >= count or
        @as(usize, count) * 4 > body.len) return error.InvalidPropRules;
    const offset = std.mem.readInt(u32, body[@as(usize, group) * 4 ..][0..4], .little);
    if (offset < @as(usize, count) * 4 or
        offset > body.len or
        body.len - offset < 2) return error.InvalidPropRules;
    const records = body[offset..];
    const length = std.mem.readInt(u16, records[0..2], .little);
    if (@as(usize, length) * 18 > records.len - 2) return error.InvalidPropRules;
    for (0..length) |i| {
        const record = records[2 + i * 18 ..][0..18];
        if (std.mem.readInt(u16, record[0..2], .little) == state) return record;
    }
    return error.MissingPropRule;
}
pub fn internConnection(
    allocator: std.mem.Allocator,
    routes: *std.ArrayList(Connection),
    sender: u16,
    recipient: u16,
    message: i16,
) !world.CircuitId {
    for (routes.items) |route| if (route.sender == sender and
        route.recipient == recipient and
        route.message == message) return route.circuit;
    if (routes.items.len > std.math.maxInt(u16)) return error.TooManyCircuitConnections;
    const id: world.CircuitId = @fromBackingInt(@as(u16, @intCast(routes.items.len)));
    try routes.append(
        allocator,
        .{ .circuit = id, .sender = sender, .recipient = recipient, .message = message },
    );
    return id;
}

pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    animations: []const u8,
    rules: []const u8,
    names: []const u8,
    room_ids: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    first_item: equipment.ItemHandle,
    supplied_items: []const equipment.Definition,
    resolver: anytype,
) !Assets {
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var definitions: std.ArrayList(world.Definition) = .empty;
    errdefer {
        releaseThrows(allocator, definitions.items);
        definitions.deinit(allocator);
    }
    var items: std.ArrayList(equipment.Definition) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item.label);
        items.deinit(allocator);
    }
    var item_sources: std.ArrayList(u16) = .empty;
    errdefer item_sources.deinit(allocator);
    var connections: std.ArrayList(Connection) = .empty;
    errdefer connections.deinit(allocator);
    const hint = try resolver.icon(0);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rule_table.group(rules, record.rule_group);
        if (timed_items.recognize(group)) |timer| {
            if (record.kind != 3 or
                record.room < room_ids.len or
                record.initial_state != timer.states[0]) return error.UnsupportedTimedItemPlacement;
            const label = try strings.copy(allocator, names, record.text_id);
            errdefer allocator.free(label);
            try item_sources.append(allocator, @intCast(i));
            try items.append(
                allocator,
                .{
                    .kind = .mission_time,
                    .icon = try resolver.icon(record.inventory_icon),
                    .label = label,
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .show_quantity = record.visual_flags & 4 != 0,
                },
            );
            continue;
        }
        if (inventory_grants.recognize(group)) |grant| {
            if (grant.starting != null and
                record.initial_state == grant.starting.? and
                record.initially_active != 0) continue;
            if (record.kind != 3 or
                record.room < room_ids.len or
                record.initial_state != grant.idle or
                record.object_id != grant.object_kind) return error.UnsupportedInventoryGrant;
            const label = try strings.copy(allocator, names, record.text_id);
            errdefer allocator.free(label);
            try item_sources.append(allocator, @intCast(i));
            var consumption_steps: ?u16 = null;
            if (credential_cards.parcel(group)) |parcel| {
                var use = try animation.decode(allocator, animations, parcel.using);
                defer use.deinit();
                consumption_steps = @intCast(use.frames.len);
            }
            if (credential_cards.terminal(group)) |card| {
                var use = try animation.decode(allocator, animations, card.using);
                defer use.deinit();
                consumption_steps = @intCast(use.frames.len);
            }
            if (credential_cards.papers(group)) |papers| {
                var use = try animation.decode(allocator, animations, papers.using);
                defer use.deinit();
                consumption_steps = @intCast(use.frames.len);
            }
            try items.append(
                allocator,
                .{
                    .kind = grant.kind,
                    .consumption_movie = if (grant.kind == .papers) .card_delivery else null,
                    .use_motion = if (record.object_id == 3) .reach else .direct,
                    .use_action = if (grant.kind == .work_permit or
                        grant.kind == .parcel or
                        grant.kind == .papers or
                        grant.kind == .terminal_card or
                        grant.kind == .photo) .{ .unlock = .{
                        .credential = .{ .fixed = record.life },
                        .consume_after_steps = consumption_steps,
                        .movie = if (grant.kind == .parcel) .parcel_delivered else null,
                    } } else null,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                },
            );
            continue;
        }
        const gift = quest_items.card(group);
        var room = record.room;
        if (room >= room_ids.len) {
            const spec = gift orelse continue;
            const destination = record.parameters[spec.room_parameter];
            if (destination < 0 or destination >= room_ids.len) return error.InvalidGiftRoom;
            room = @intCast(destination);
        }
        const pressure_spec = pressure_controls.recognize(try rule_table.group(rules, record.rule_group));
        if (record.kind != 3 and pressure_spec == null) continue;
        const rule = try firstRule(rules, record.rule_group, record.initial_state);
        var behavior: @FieldType(world.Definition, "behavior") = undefined;
        if (record.kind == 3) {
            const stone = isThrowablePickup(rules, record.rule_group, record.initial_state, rule);
            const credit = credit_pickups.recognize(try rule_table.group(rules, record.rule_group));
            const key = key_pickups.recognize(try rule_table.group(rules, record.rule_group));
            const cartridge = cartridges.recognize(try rule_table.group(rules, record.rule_group));
            const device = quest_items.teleporter(group);
            if (record.initial_state != 328 and
                !stone and
                credit == null and
                key == null and
                cartridge == null and
                gift == null and
                device == null) continue;
            if (credit) |spec| {
                if (record.initial_state != spec.idle or
                    record.contact_icon != 1) return error.UnsupportedCreditPickup;
                const recipient = record.parameters[spec.target_parameter];
                if (recipient < 0 or recipient >= table.count) return error.InvalidCreditRecipient;
                const purse = try table.record(@intCast(recipient));
                if (purse.kind != 3 or
                    purse.initially_active == 0 or
                    credit_wallet.signal(try rule_table.group(rules, purse.rule_group)) == null) return error.UnsupportedCreditRecipient;
                const target: equipment.ItemHandle = for (supplied_items, 0..) |item, index| {
                    if (item.kind == .credits) break .{ .index = @intCast(index), .generation = 1 };
                } else return error.MissingCreditPurse;
                const idle = try appendClip(
                    allocator,
                    &clips,
                    animations,
                    record.initial_state,
                    resolver,
                );
                const amount = record.parameters[spec.amount_parameter];
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .credits,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = amount,
                    .label = label,
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = .credits_pickup,
                    .quantity_grant = .{ .target = target, .amount = amount },
                } };
                try items.append(allocator, item);
            } else if (key) |spec| {
                if (record.initial_state != spec.idle or
                    record.contact_icon != 1 or
                    record.parameters[0] != 5) return error.UnsupportedKeyPickup;
                const idle = try appendClip(allocator, &clips, animations, spec.idle, resolver);
                var use = try animation.decode(allocator, animations, spec.using);
                defer use.deinit();
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = spec.kind,
                    .consumption_notice = spec.completion_notice,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .use_action = .{ .unlock = .{
                        .credential = .{ .fixed = record.life },
                        .consume_after_steps = @intCast(use.frames.len),
                    } },
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = spec.pickup,
                } };
                try items.append(allocator, item);
            } else if (cartridge) |spec| {
                if (record.initial_state != spec.idle or
                    record.contact_icon != 1 or
                    record.parameters[0] != 5) return error.UnsupportedCartridgePickup;
                const idle = try appendClip(allocator, &clips, animations, spec.idle, resolver);
                const use_steps = try itemUseDuration(allocator, animations, spec.using);
                const charge_steps = try itemUseDuration(allocator, animations, spec.charging);
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .cartridge,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .show_quantity = record.visual_flags & 4 != 0,
                    .use_action = .{ .unlock = .{
                        .credential = .item_charge,
                        .consume_after_steps = use_steps,
                        .movie = .bridge_activation,
                    } },
                    .recharge = .{
                        .delay_steps = charge_steps,
                        .restore = .{ .item_charge = spec.charge },
                        .movie = .cartridge_recharge,
                        .movie_when = .start,
                    },
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = .cartridge_pickup,
                } };
                try items.append(allocator, item);
            } else if (gift) |spec| {
                const hidden = record.initial_state == spec.hidden;
                if ((!hidden and record.initial_state != spec.idle) or
                    (hidden and record.room < room_ids.len) or
                    record.contact_icon != 1 or
                    record.parameters[0] != 5) return error.UnsupportedGiftPlacement;
                const idle = try appendClip(allocator, &clips, animations, spec.idle, resolver);
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .id_card,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .use_action = .{ .unlock = .{
                        .credential = .{ .fixed = record.life },
                        .consume_after_steps = null,
                    } },
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = .id_card_pickup,
                    .initially_present = !hidden,
                } };
                try items.append(allocator, item);
            } else if (device) |spec| {
                if (record.initial_state != spec.idle or
                    record.contact_icon != 1 or
                    record.parameters[0] != 3) return error.UnsupportedTeleporter;
                const idle = try appendClip(allocator, &clips, animations, spec.idle, resolver);
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .teleporter,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .use_action = .{ .offer = .{ .credential = record.life } },
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = .teleporter_pickup,
                } };
                try items.append(allocator, item);
            } else if (stone) {
                if (record.contact_icon != 1 or
                    record.object_id != 1) return error.UnsupportedThrowableItem;
                const idle = try appendClip(
                    allocator,
                    &clips,
                    animations,
                    record.initial_state,
                    resolver,
                );
                const trajectory = try thrown_item.load(
                    allocator,
                    try rule_table.group(rules, record.rule_group),
                    record.initial_state,
                    word(rule, 4),
                    animations,
                    &clips,
                    resolver,
                );
                errdefer allocator.free(trajectory.arc);
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .stone,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .use_action = .throw_item,
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .throw_motion = trajectory,
                } };
                try items.append(allocator, item);
            } else {
                if (record.kind != 3 or
                    record.minimum_difficulty != 0 or
                    record.contact_icon != 1) return error.UnsupportedHolocube;
                if (word(rule, 4) != 315 or
                    rule[7] != 34 or
                    rule[6] != 90 or
                    rule[9] != 48 or
                    word(rule, 12) != 30 or
                    word(rule, 14) != 1 or
                    word(rule, 16) != 0) return error.UnsupportedPickupRule;
                const use = try firstRule(rules, record.rule_group, 315);
                if (word(use, 4) != 315 or
                    use[7] != 34 or
                    use[6] != 90 or
                    use[9] != 0 or
                    word(use, 12) != 102 or
                    word(use, 14) != 17) return error.UnsupportedItemUse;
                const idle = try appendClip(
                    allocator,
                    &clips,
                    animations,
                    record.initial_state,
                    resolver,
                );
                const label = try strings.copy(allocator, names, record.text_id);
                errdefer allocator.free(label);
                const item: equipment.Definition = .{
                    .kind = .holocube,
                    .icon = try resolver.icon(record.inventory_icon),
                    .introduction_steps = null,
                    .initial_quantity = record.life,
                    .label = label,
                    .use_action = .{ .story = .holocube_recording },
                };
                behavior = .{ .collectible = .{
                    .item = .{
                        .index = first_item.index + @as(u16, @intCast(items.items.len)),
                        .generation = first_item.generation,
                    },
                    .idle = idle,
                    .pickup_movie = .holocube_pickup,
                } };
                try items.append(allocator, item);
            }
        } else {
            const pressure = pressure_spec orelse continue;
            if (record.initial_state != pressure.rest) return error.UnsupportedPressureStart;
            const target = record.parameters[pressure.target_parameter];
            if (target < 0 or target >= table.count) return error.InvalidSwitchConnection;
            const rest = try appendClip(allocator, &clips, animations, pressure.rest, resolver);
            const press = try appendClip(allocator, &clips, animations, pressure.pressed, resolver);
            const recipient: u16 = @intCast(target);
            const message = pressure.message;
            const circuit = for (connections.items) |connection| {
                if (connection.sender == i and
                    connection.recipient == recipient and
                    connection.message == message) break connection.circuit;
            } else fresh: {
                const id: world.CircuitId = @fromBackingInt(@as(u16, @intCast(connections.items.len)));
                try connections.append(
                    allocator,
                    .{
                        .circuit = id,
                        .sender = @intCast(i),
                        .recipient = recipient,
                        .message = message,
                    },
                );
                break :fresh id;
            };
            behavior = .{ .floor_switch = .{
                .rest = rest,
                .press = press,
                .circuit = circuit,
                .accepts_objects = !pressure.player_only,
                .initially_active = record.initially_active != 0,
                .wake_on_contact = record.flags & 2 != 0,
                .sleep_after_press = pressure.sleep_after_press,
            } };
        }
        if (behavior == .collectible) {
            items.items[items.items.len - 1].use_motion = if (record.object_id == 3) .reach else .direct;
            try item_sources.append(allocator, @intCast(i));
            behavior.collectible.initially_active = record.initially_active != 0;
            behavior.collectible.wake_nearby = record.flags & 4 != 0;
        }
        errdefer if (behavior == .collectible) {
            if (behavior.collectible.throw_motion) |throw| allocator.free(throw.arc);
        };
        table.register(@intCast(i), .world_props);
        try definitions.append(
            allocator,
            .{
                .interaction_priority = @intCast(i),
                .footprint = .{
                    .room = room_ids[room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .palette_bank = @intCast(record.visual_flags & 3),
                .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player,
                .behavior = behavior,
            },
        );
    }
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer {
        releaseThrows(allocator, owned_definitions);
        allocator.free(owned_definitions);
    }
    const owned_connections = try connections.toOwnedSlice(allocator);
    errdefer allocator.free(owned_connections);
    const owned_sources = try item_sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{
        .allocator = allocator,
        .item_sources = owned_sources,
        .connections = owned_connections,
        .clips = owned_clips,
        .definitions = owned_definitions,
        .items = try items.toOwnedSlice(allocator),
        .hint_icon = hint,
    };
}
fn itemUseDuration(allocator: std.mem.Allocator, animations: []const u8, state: u16) !u16 {
    var clip = try animation.decode(allocator, animations, state);
    defer clip.deinit();
    if (clip.sound != null) return error.UnsupportedHiddenItemSound;
    for (clip.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |value| if (value.dx != 0 or value.dy != 0) return error.MovingInventoryItem,
    };
    return @intCast(clip.frames.len);
}

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn appendClip(
    allocator: std.mem.Allocator,
    clips: *std.ArrayList(animation.OwnedClip),
    animations: []const u8,
    id: u16,
    resolver: anytype,
) !motion.Clip {
    var source = try animation.decode(allocator, animations, id);
    defer source.deinit();
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |value| if (value.dx != 0 or value.dy != 0) return error.UnsupportedMovingProp,
    };
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try clips.append(allocator, clip);
    return clip.clip();
}

/// Ground transfer plus separate throw/drop inventory messages identifies this family.
/// The rest of the object's rules describe its flight and are imported separately.
fn isThrowablePickup(bytes: []const u8, group: u16, initial: u16, pickup: []const u8) bool {
    if (pickup[2] != 0 or
        pickup[3] != 0 or
        pickup[8] != 0 or
        pickup[7] != 34 or
        word(pickup, 12) != 30 or
        pickup[6] != 90 or
        word(pickup, 14) != 8 or
        pickup[9] != 48) return false;
    const carried = word(pickup, 4);
    const view = rule_table.group(bytes, group) catch return false;
    var throws = false;
    var drops = false;
    for (0..view.count()) |i| {
        const rule = view.at(i);
        if (rule.source != carried or
            rule.conditions[0].code != 34 or
            rule.conditions[1].code != 0 or
            rule.effect.code != 49 or
            rule.flags != 0 or
            rule.dx != 0 or
            rule.dy != 0) continue;
        if (rule.conditions[0].argument == 100 and rule.target != initial) throws = true;
        if (rule.conditions[0].argument == 102 and rule.target == initial) drops = true;
    }
    return throws and drops;
}

fn releaseThrows(allocator: std.mem.Allocator, definitions: []const world.Definition) void {
    for (definitions) |definition| if (definition.behavior == .collectible) {
        if (definition.behavior.collectible.throw_motion) |throw| allocator.free(throw.arc);
    };
}
