//! Compile reveal, threat perception, reassurance and rescue acknowledgement into actor data.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../rescue_contacts.zig");
const routes = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: []i16,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |d| self.allocator.free(d.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
    pub fn bind(self: Assets, connections: []const routes.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signal, index| for (connections) |connection| if (connection.recipient == source and connection.message == signal) {
            try bindings.append(self.allocator, .{ .circuit = connection.circuit, .target = index, .next_step = connection.sender >= source });
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
fn recognize(group: rules.Group) bool {
    if (group.count() != 17) return false;
    const sources = [_]usize{ 0, 0, 0, 0, 4, 5, 5, 5, 8, 9, 10, 11, 11, 11, 14, 14, 14 };
    const next = [_]u16{ 0, 4, 0, 0, 5, 8, 5, 5, 9, 10, 11, 11, 14, 11, 14, 14, 14 };
    const codes = [_][3]u8{ .{ 34, 0, 87 }, .{ 121, 0, 35 }, .{ 77, 0, 67 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 34, 0, 0 }, .{ 77, 0, 67 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 77, 0, 67 }, .{ 34, 123, 36 }, .{ 0, 0, 0 }, .{ 77, 0, 75 }, .{ 34, 123, 0 }, .{ 0, 0, 0 } };
    for (sources, next, codes, 0..) |source, target, ops, i| {
        const row = group.at(i);
        if (row.source != group.at(source).source or row.target != group.at(target).source or row.next != target or row.dx != 0 or row.dy != 0 or row.flags != (if (i == 4) @as(u8, 1) else 0)) return false;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, ops) |op, code| if (op.code != code) return false;
    }
    return group.at(0).conditions[0].argument == group.at(5).conditions[0].argument and group.at(0).effect.argument >= 0 and group.at(0).effect.argument <= 3 and group.at(1).conditions[0].argument > 0 and group.at(1).conditions[0].argument <= 16 and group.at(12).conditions[0].argument == 30 and group.at(15).conditions[0].argument == 30 and group.at(12).conditions[1].argument >= 0 and group.at(15).conditions[1].argument >= 0;
}
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(routes.Connection), resolver: anytype) !Assets {
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
        if (record.kind != 3 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (!recognize(group)) continue;
        const hidden = record.room >= rooms.len;
        const room = if (hidden) record.parameters[@intCast(group.at(0).effect.argument)] else @as(i16, record.room);
        if (room < 0 or room >= rooms.len or record.contact_icon == 0) return error.InvalidRescueContact;
        var resolved: [8]@import("../motion.zig").Clip = undefined;
        var initial: ?runtime.Phase = null;
        for ([_]usize{ 0, 4, 5, 8, 9, 10, 11, 14 }, &resolved, 0..) |row, *destination, phase| {
            const state = group.at(row).source;
            if (state == record.initial_state) initial = @fromBackingInt(@as(u3, @intCast(phase)));
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        if (initial == null or (hidden and initial.? != .watching)) return error.UnsupportedRescueContactStart;
        var output: [2]@import("../world_props.zig").CircuitId = undefined;
        for ([_]rules.Operation{ group.at(1).effect, group.at(12).effect }, &output) |op, *circuit| {
            const target = record.parameters[op.code - 35];
            if (target < 0 or target >= table.count) return error.InvalidRescueOutput;
            circuit.* = try routes.internConnection(allocator, connections, @intCast(index), @intCast(target), op.argument);
        }
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, group.at(0).conditions[0].argument);
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .room = rooms[@intCast(room)], .position = record.position, .facing = if (record.facing_right == 0) .left else .right, .width = record.collision_width, .clips = resolved, .initial = initial.?, .hidden = hidden, .trigger_distance = group.at(1).conditions[0].argument * 16, .alert = output[0], .acknowledged = output[1], .messages = .{ @fromBackingInt(@as(u16, @intCast(group.at(12).conditions[1].argument))), @fromBackingInt(@as(u16, @intCast(group.at(15).conditions[1].argument))) }, .hint = try resolver.icon(record.contact_icon - 1), .label = label, .priority = @intCast(index), .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0 });
        table.register(@intCast(index), .rescue_contacts);
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
