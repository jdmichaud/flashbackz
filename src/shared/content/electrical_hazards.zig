//! Recover signal-controlled electrical cycles as typed content, independent of source
//! placement and state numbering. Only the complete recognized rule family is accepted.
const std = @import("std");
const runtime = @import("../electrical_hazards.zig");
const rules = @import("rule_table.zig");
const placement = @import("placement.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const connections = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.cycle);
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
pub const Spec = struct { cycle: [32]u16 = undefined, count: usize, contact: u16, disabled: u16, disable_messages: [2]i16, enable_message: i16 };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() < 8 or (group.count() - 3) % 5 != 0) return null;
    const count = (group.count() - 3) / 5;
    if (count > 32) return null;
    for (0..group.count()) |i| {
        const row = group.at(i);
        if (row.dx != 0 or row.dy != 0 or row.flags != 0) return null;
    }
    const contact = group.at(count * 5);
    const enable = group.at(count * 5 + 1);
    const disabled = group.at(count * 5 + 2);
    var spec: Spec = .{ .count = count, .contact = contact.source, .disabled = enable.source, .disable_messages = .{ group.at(0).conditions[0].argument, group.at(1).conditions[0].argument }, .enable_message = enable.conditions[0].argument };
    for (0..count) |i| spec.cycle[i] = group.at(i * 5).source;
    for (0..count) |i| {
        const next = (i + 1) % count;
        for (0..2) |j| {
            const row = group.at(i * 5 + j);
            if (row.source != spec.cycle[i] or row.target != spec.disabled or row.next != count * 5 + 1 or !op(row.conditions[0], 34, spec.disable_messages[j]) or !op(row.conditions[1], 0, 0) or !op(row.effect, 0, 0)) return null;
        }
        const touching = group.at(i * 5 + 2);
        if (touching.source != spec.cycle[i] or touching.target != spec.contact or touching.next != count * 5 or !op(touching.conditions[0], 80, 1) or !op(touching.conditions[1], 0, 0) or !op(touching.effect, 0, 0)) return null;
        for (3..5) |j| {
            const row = group.at(i * 5 + j);
            if (row.source != spec.cycle[i] or row.target != spec.cycle[next] or row.next != next * 5 or !op(row.conditions[0], if (j == 3) 77 else 0, 0) or !op(row.conditions[1], 0, 0) or !op(row.effect, if (j == 3) 67 else 0, 0)) return null;
        }
    }
    if (contact.target != spec.cycle[0] or contact.next != 0 or !op(contact.conditions[0], 90, 9) or !op(contact.conditions[1], 0, 0) or !op(contact.effect, 79, 1)) return null;
    if (enable.target != spec.cycle[0] or enable.next != 0 or !op(enable.conditions[0], 34, spec.enable_message) or !op(enable.conditions[1], 0, 0) or !op(enable.effect, 67, 0)) return null;
    if (disabled.source != spec.disabled or disabled.target != spec.disabled or disabled.next != count * 5 + 1 or !op(disabled.conditions[0], 0, 0) or !op(disabled.conditions[1], 0, 0) or !op(disabled.effect, 67, 0)) return null;
    for (spec.disable_messages) |message| if (message == spec.enable_message) return null;
    return spec;
}
fn resolveClip(allocator: std.mem.Allocator, owned: *std.ArrayList(animation.OwnedClip), bytes: []const u8, state: u16, resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, bytes, state);
    defer source.deinit();
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingHazardAnchor,
    };
    var result = try source.resolve(allocator, resolver);
    errdefer result.deinit();
    try owned.append(allocator, result);
    return result.clip();
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: []const connections.Connection, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| allocator.free(definition.cycle);
        definitions.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*owned| owned.deinit();
        clips.deinit(allocator);
    }
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.room >= rooms.len) return error.InvalidHazardRoom;
        const phase: runtime.Phase = if (record.initial_state == spec.disabled) .disabled else if (record.initial_state == spec.contact) .contact else cycling: {
            for (spec.cycle[0..spec.count], 0..) |state, i| if (state == record.initial_state) break :cycling .{ .cycling = i };
            return error.InvalidHazardStart;
        };
        const cycle = try allocator.alloc(motion.Clip, spec.count);
        errdefer allocator.free(cycle);
        for (spec.cycle[0..spec.count], cycle) |state, *destination| destination.* = try resolveClip(allocator, &clips, animations, state, resolver);
        const contact = try resolveClip(allocator, &clips, animations, spec.contact, resolver);
        const disabled = try resolveClip(allocator, &clips, animations, spec.disabled, resolver);
        for (routes) |route| if (route.recipient == index) {
            const action: runtime.Action = if (route.message == spec.enable_message) .enable else if (route.message == spec.disable_messages[0] or route.message == spec.disable_messages[1]) .disable else .wake;
            // Original update ordering becomes explicit edge latency. The runtime sees
            // semantic actions and opaque circuit IDs, never source entity indices.
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = definitions.items.len, .action = action, .next_step = route.sender >= index });
        };
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .cycle = cycle, .contact = contact, .disabled = disabled, .initial_phase = phase, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0 });
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned_definitions) |definition| allocator.free(definition.cycle);
        allocator.free(owned_definitions);
    }
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    return .{ .allocator = allocator, .definitions = owned_definitions, .bindings = owned_bindings, .clips = try clips.toOwnedSlice(allocator) };
}
