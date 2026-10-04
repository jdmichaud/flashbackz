//! Discover supported collectible and pressure-switch families in level data. Source
//! IDs and rule layouts stop here; the world owns ordinary objects and named effects.
const std = @import("std");
const placement = @import("placement.zig");
const animation = @import("animation.zig");
const equipment = @import("../equipment.zig");
const world = @import("../world_props.zig");
const geometry = @import("../geometry.zig");
const strings = @import("string_table.zig");

// Import-only endpoints let other content importers bind the same opaque circuit.
pub const Connection = struct { circuit: world.CircuitId, recipient: u16, message: i16 };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    clips: []animation.OwnedClip,
    definitions: []world.Definition,
    items: []equipment.Definition,
    connections: []Connection,
    hint_icon: @import("../motion.zig").VisualId,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.connections);
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
    if (count > 256 or group >= count or @as(usize, count) * 4 > body.len) return error.InvalidPropRules;
    const offset = std.mem.readInt(u32, body[@as(usize, group) * 4 ..][0..4], .little);
    if (offset < @as(usize, count) * 4 or offset > body.len or body.len - offset < 2) return error.InvalidPropRules;
    const records = body[offset..];
    const length = std.mem.readInt(u16, records[0..2], .little);
    if (@as(usize, length) * 18 > records.len - 2) return error.InvalidPropRules;
    for (0..length) |i| {
        const record = records[2 + i * 18 ..][0..18];
        if (std.mem.readInt(u16, record[0..2], .little) == state) return record;
    }
    return error.MissingPropRule;
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, animations: []const u8, rules: []const u8, names: []const u8, room_ids: *const [64]geometry.RoomId, first_item: equipment.ItemHandle, resolver: anytype) !Assets {
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var definitions: std.ArrayList(world.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var items: std.ArrayList(equipment.Definition) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item.label);
        items.deinit(allocator);
    }
    var connections: std.ArrayList(Connection) = .empty;
    errdefer connections.deinit(allocator);
    const hint = try resolver.icon(0);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.room >= room_ids.len) continue;
        if (record.initial_state != 328 and record.initial_state != 307) continue;
        const rule = try firstRule(rules, record.rule_group, record.initial_state);
        var behavior: @FieldType(world.Definition, "behavior") = undefined;
        if (record.initial_state == 328) {
            if (record.kind != 3 or record.minimum_difficulty != 0 or record.contact_icon != 1) return error.UnsupportedHolocube;
            if (word(rule, 4) != 315 or rule[7] != 34 or rule[6] != 90 or rule[9] != 48 or word(rule, 12) != 30 or word(rule, 14) != 1 or word(rule, 16) != 0) return error.UnsupportedPickupRule;
            const use = try firstRule(rules, record.rule_group, 315);
            if (word(use, 4) != 315 or use[7] != 34 or use[6] != 90 or use[9] != 0 or word(use, 12) != 102 or word(use, 14) != 17) return error.UnsupportedItemUse;
            const idle = try appendClip(allocator, &clips, animations, record.initial_state, resolver);
            const label = try strings.copy(allocator, names, record.text_id);
            errdefer allocator.free(label);
            const item: equipment.Definition = .{ .kind = .holocube, .icon = try resolver.icon(record.inventory_icon), .introduction_steps = null, .initial_quantity = record.life, .label = label, .use_action = .{ .story = .holocube_recording } };
            behavior = .{ .collectible = .{ .item = .{ .index = first_item.index + @as(u16, @intCast(items.items.len)), .generation = first_item.generation }, .idle = idle, .pickup_movie = .holocube_pickup } };
            try items.append(allocator, item);
        } else {
            // The continuously active pressure family is already qualified. Other switch
            // families need activation/sleep and interaction semantics before integration.
            // Their instances and connections are reported by the mechanism survey.
            const recovery = try firstRule(rules, record.rule_group, 306);
            if (rule[7] != 0 or rule[6] != 61 or rule[9] != 35 or word(rule, 4) != 306 or recovery[9] != 0) continue;
            if (record.kind != 7 or record.parameters[0] < 0 or record.parameters[0] >= table.count) return error.InvalidSwitchConnection;
            const rest = try appendClip(allocator, &clips, animations, record.initial_state, resolver);
            const press = try appendClip(allocator, &clips, animations, word(rule, 4), resolver);
            const recipient: u16 = @intCast(record.parameters[0]);
            const message: i16 = @bitCast(word(rule, 16));
            const circuit = for (connections.items) |connection| {
                if (connection.recipient == recipient and connection.message == message) break connection.circuit;
            } else fresh: {
                const id: world.CircuitId = @fromBackingInt(@as(u16, @intCast(connections.items.len)));
                try connections.append(allocator, .{ .circuit = id, .recipient = recipient, .message = message });
                break :fresh id;
            };
            behavior = .{ .floor_switch = .{ .rest = rest, .press = press, .circuit = circuit } };
        }
        try definitions.append(allocator, .{ .footprint = .{ .room = room_ids[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .behavior = behavior });
    }
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_definitions);
    const owned_connections = try connections.toOwnedSlice(allocator);
    errdefer allocator.free(owned_connections);
    return .{ .allocator = allocator, .connections = owned_connections, .clips = owned_clips, .definitions = owned_definitions, .items = try items.toOwnedSlice(allocator), .hint_icon = hint };
}
fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn appendClip(allocator: std.mem.Allocator, clips: *std.ArrayList(animation.OwnedClip), animations: []const u8, id: u16, resolver: anytype) !@import("../motion.zig").Clip {
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
