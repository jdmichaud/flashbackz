//! Compile the floppy edition's visibility continuation into typed contact-group choices.
//! The engine receives entity-dependent choices, never a memory image or DOS addresses.
const std = @import("std");
const runtime = @import("../visibility.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
pub const Owner = union(enum) { player, prop: usize, guard: usize, door: usize, item_aid: usize, trader: usize, guide: usize, station: usize, force_field: usize, service_counter: usize, mission_terminal: usize, quest_contact: usize, attentive_contact: usize, escort: usize, ambient_person: usize, rescue_contact: usize, enemy_barrier: usize, gunman: usize, unbound };
pub const Binding = struct { entity: runtime.Entity, owner: Owner };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    bindings: []Binding,
    guard_entities: []runtime.Entity,
    gunman_entities: []runtime.Entity,
    player_entity: runtime.Entity,
    unbound_count: usize,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
        self.allocator.free(self.guard_entities);
        self.allocator.free(self.gunman_entities);
    }
};
fn group(value: u8) ?runtime.Group {
    return if (value < 128) @fromBackingInt(@as(u7, @intCast(value))) else null;
}
fn continuation(table: placement.Table, identities: []const ?runtime.Entity, source: usize, distance: usize) runtime.Pick {
    const at: isize = @as(isize, @intCast(source * 32)) - @as(isize, @intCast(distance));
    if (at >= 0) return .{ .group = group(table.bytes[@intCast(at)]) };
    // Before the first placement, the original scan reaches activation references.
    // Resolve their two possible byte values here into an entity-dependent choice.
    const activation_byte: usize = @intCast(512 + at);
    const actor = activation_byte / 2;
    if (actor >= identities.len or identities[actor] == null) return .{ .group = @fromBackingInt(0) };
    const reference: u16 = @intCast(0x6ad0 + actor * 26);
    const active: u8 = @truncate(if (activation_byte % 2 == 0) reference else reference >> 8);
    return .{ .when_active = .{ .entity = identities[actor].?, .active = group(active), .inactive = @fromBackingInt(0) } };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, owners: anytype) !Assets {
    const identities = try allocator.alloc(?runtime.Entity, table.count);
    defer allocator.free(identities);
    @memset(identities, null);
    var count: usize = 0;
    for (identities, 0..) |*identity, index| {
        if ((try table.record(@intCast(index))).minimum_difficulty > @backingInt(difficulty)) continue;
        identity.* = @fromBackingInt(@as(u16, @intCast(count)));
        count += 1;
    }
    const definitions = try allocator.alloc(runtime.Definition, count);
    errdefer allocator.free(definitions);
    const bindings = try allocator.alloc(Binding, count);
    errdefer allocator.free(bindings);
    const guard_entities = try allocator.alloc(runtime.Entity, owners.guards.sources.len);
    errdefer allocator.free(guard_entities);
    const gunman_entities = try allocator.alloc(runtime.Entity, owners.gunmen.sources.len);
    errdefer allocator.free(gunman_entities);
    var unbound: usize = 0;
    for (identities, 0..) |optional, index| {
        const identity = optional orelse continue;
        const record = try table.record(@intCast(index));
        const definition = &definitions[@backingInt(identity)];
        definition.* = .{ .category = switch (record.kind) {
            1 => .player,
            3 => .interactive,
            10 => .enemy,
            else => .other,
        }, .priority = @intCast(index), .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .initial_body = if (record.room < rooms.len and record.collision_width != 0) .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width } else null, .continuation = undefined };
        for (&definition.continuation, 1..) |*choice, distance| choice.* = continuation(table, identities, index, distance);
        var owner: Owner = if (index == 0) .player else .unbound;
        for (owners.props.definitions, 0..) |prop, i| if (prop.interaction_priority == index) {
            owner = .{ .prop = i };
            break;
        };
        for (owners.guards.sources, 0..) |source, i| if (source == index) {
            owner = .{ .guard = i };
            guard_entities[i] = identity;
            break;
        };
        for (owners.gunmen.sources, 0..) |source, i| if (source == index) {
            owner = .{ .gunman = i };
            gunman_entities[i] = identity;
            break;
        };
        for (owners.doors.source_indices, 0..) |source, i| if (source == index) {
            owner = .{ .door = i };
            break;
        };
        for (owners.item_aid.definitions, 0..) |npc, i| if (npc.interaction_priority == index) {
            owner = .{ .item_aid = i };
            break;
        };
        for (owners.traders.definitions, 0..) |npc, i| if (npc.interaction_priority == index) {
            owner = .{ .trader = i };
            break;
        };
        for (owners.guides.sources, 0..) |source, i| if (source == index) {
            owner = .{ .guide = i };
            break;
        };
        for (owners.story_stations.sources, 0..) |source, i| if (source == index) {
            owner = .{ .station = i };
            break;
        };
        for (owners.force_fields.sources, 0..) |source, i| if (source == index) {
            owner = .{ .force_field = i };
            break;
        };
        for (owners.service_counters.sources, 0..) |source, i| if (source == index) {
            owner = .{ .service_counter = i };
            break;
        };
        for (owners.mission_terminals.sources, 0..) |source, i| if (source == index) {
            owner = .{ .mission_terminal = i };
            break;
        };
        for (owners.enemy_barriers.sources, 0..) |source, i| if (source == index) {
            owner = .{ .enemy_barrier = i };
            break;
        };
        for (owners.rescue_contacts.sources, 0..) |source, i| if (source == index) {
            owner = .{ .rescue_contact = i };
            break;
        };
        for (owners.ambient_people.sources, 0..) |source, i| if (source == index) {
            owner = .{ .ambient_person = i };
            break;
        };
        for (owners.quest_contacts.sources, 0..) |source, i| if (source == index) {
            owner = .{ .quest_contact = i };
            break;
        };
        for (owners.attentive_contacts.sources, 0..) |source, i| if (source == index) {
            owner = .{ .attentive_contact = i };
            break;
        };
        for (owners.escort_followers.sources, 0..) |source, i| if (source == index) {
            owner = .{ .escort = i };
            break;
        };
        if (owner == .unbound) unbound += 1;
        bindings[@backingInt(identity)] = .{ .entity = identity, .owner = owner };
    }
    return .{ .allocator = allocator, .definitions = definitions, .bindings = bindings, .guard_entities = guard_entities, .gunman_entities = gunman_entities, .player_entity = identities[0] orelse return error.MissingPlayerVisibility, .unbound_count = unbound };
}
