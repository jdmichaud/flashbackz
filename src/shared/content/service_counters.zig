//! Import credential service desks with a four-pose idle cycle and linked reward.
const std = @import("std");
const rules = @import("rule_table.zig");
const runtime = @import("../service_counters.zig");
const animation = @import("animation.zig");
const routes = @import("first_world_props.zig");
pub const Spec = struct { states: [4]u16, signal: i16, message: i16, output: i16, parameter: u2, chances: [2]i16 };
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 18) return null;
    const starts = [_]usize{ 0, 5, 9, 14 };
    const target_phases = [_]usize{ 0, 2, 2, 0 };
    const first = group.at(0);
    const text = group.at(1);
    if (first.conditions[0].code != 34 or first.conditions[1].code != 0 or first.effect.code < 35 or first.effect.code > 38 or text.effect.code != 123 or text.effect.argument < 0) return null;
    var result: Spec = .{ .states = undefined, .signal = first.conditions[0].argument, .message = text.effect.argument, .output = first.effect.argument, .parameter = @intCast(first.effect.code - 35), .chances = .{ group.at(3).conditions[0].argument, group.at(12).conditions[0].argument } };
    if (result.chances[0] <= 0 or result.chances[1] <= 0) return null;
    for (starts, target_phases, 0..) |start, target_phase, phase| {
        result.states[phase] = group.at(start).source;
        const count: usize = if (phase == 0 or phase == 2) 5 else 4;
        for (0..count) |slot| {
            const r = group.at(start + slot);
            const random = slot == 3 and count == 5;
            const destination = if (slot < 2) starts[target_phase] else if (random) starts[phase + 1] else if (slot == count - 1 and count == 4) starts[target_phase] else start;
            if (r.source != group.at(start).source or r.target != group.at(destination).source or r.next != destination or r.dx != 0 or r.dy != 0 or r.flags != 0 or r.conditions[1].code != 0) return null;
            const condition: u8 = if (slot < 2) 34 else if (slot == 2) 77 else if (random) 97 else 0;
            const effect: u8 = if (slot == 0) first.effect.code else if (slot == 1) 123 else if (slot == 2) 67 else 0;
            if (r.conditions[0].code != condition or r.effect.code != effect) return null;
            if (slot == 0 and (r.conditions[0].argument != result.signal or r.effect.argument != result.output) or slot == 1 and (r.conditions[0].argument != 30 or r.effect.argument != result.message) or slot == 2 and r.conditions[0].argument != 0) return null;
        }
    }
    return result;
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: []i16,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
    pub fn bind(self: Assets, connections: []const routes.Connection) ![]runtime.Binding {
        var result: std.ArrayList(runtime.Binding) = .empty;
        errdefer result.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signal, index| for (connections) |connection| if (connection.recipient == source and connection.message == signal) {
            try result.append(self.allocator, .{ .circuit = connection.circuit, .target = index, .next_step = connection.sender >= source });
        };
        return result.toOwnedSlice(self.allocator);
    }
};
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(routes.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList(i16) = .empty;
    errdefer signals.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 5 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0] or record.contact_icon == 0) return error.UnsupportedCounterStart;
        const recipient = record.parameters[spec.parameter];
        if (recipient < 0 or recipient >= table.count) return error.InvalidCounterRecipient;
        var resolved: [4]@import("../motion.zig").Clip = undefined;
        for (spec.states, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingCounter,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const output = try routes.internConnection(allocator, connections, @intCast(index), @intCast(recipient), spec.output);
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.signal);
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .clips = resolved, .gesture_chance = spec.chances[0], .return_chance = spec.chances[1], .output = output, .notice = @fromBackingInt(@as(u16, @intCast(spec.message))), .hint = try resolver.icon(record.contact_icon - 1), .label = label, .priority = @intCast(index), .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0 });
        table.register(@intCast(index), .service_counters);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_signals = try signals.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signals);
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .signals = owned_signals, .clips = try clips.toOwnedSlice(allocator) };
}
