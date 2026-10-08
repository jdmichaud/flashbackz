//! Compile inventory countdowns and their grant, success and cleanup links.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../timed_items.zig");
const routes = @import("first_world_props.zig");
pub const Spec = struct { states: [3]u16, start: i16, complete: i16, outputs: [3]rules.Operation, failure: i16 };
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 6) return null;
    const source = [_]usize{ 0, 0, 2, 2, 2, 5 };
    const next = [_]u16{ 2, 0, 5, 5, 2, 5 };
    const codes = [_][3]u8{ .{ 34, 48, 36 }, .{ 0, 0, 67 }, .{ 34, 0, 37 }, .{ 39, 0, 92 }, .{ 0, 0, 0 }, .{ 0, 74, 35 } };
    for (source, next, codes, 0..) |from, to, ops, i| {
        const r = group.at(i);
        if (r.source != group.at(from).source or r.target != group.at(to).source or r.next != to or r.dx != 0 or r.dy != 0 or r.flags != (if (i == 4) @as(u8, 2) else 0)) return null;
        for ([_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect }, ops) |op, code| if (op.code != code) return null;
    }
    if (group.at(0).conditions[1].argument != 0 or group.at(5).conditions[1].argument != 0) return null;
    return .{ .states = .{ group.at(0).source, group.at(2).source, group.at(5).source }, .start = group.at(0).conditions[0].argument, .complete = group.at(2).conditions[0].argument, .outputs = .{ group.at(0).effect, group.at(2).effect, group.at(5).effect }, .failure = group.at(3).effect.argument };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: [][2]i16,
    clips: []animation.OwnedClip,
    audible_rooms: []@import("../geometry.zig").RoomId,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.audible_rooms);
    }
    pub fn bind(self: Assets, connections: []const routes.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signals, index| for (connections) |connection| if (connection.recipient == source) {
            for (signals, [_]runtime.Action{ .start, .complete }) |signal, action| if (connection.message == signal) {
                try bindings.append(self.allocator, .{ .circuit = connection.circuit, .target = index, .action = action, .next_step = connection.sender >= source });
            };
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, collision: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, item_sources: []const u16, first_item: u16, connections: *std.ArrayList(routes.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList([2]i16) = .empty;
    errdefer signals.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (item_sources, 0..) |source, index| {
        const record = try table.record(source);
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0] or spec.failure != 62 or record.parameters[3] != 0 or record.flags & 1 == 0) return error.UnsupportedTimedItem;
        var resolved: [3]@import("../motion.zig").Clip = undefined;
        for (spec.states, &resolved) |state, *destination| {
            var src = try animation.decode(allocator, animations, state);
            defer src.deinit();
            for (src.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingTimedItem,
            };
            var clip = try src.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        var output: [3]@import("../world_props.zig").CircuitId = undefined;
        for (spec.outputs, &output) |op, *circuit| {
            const target = record.parameters[op.code - 35];
            if (target < 0 or target >= table.count) return error.InvalidTimedItemConnection;
            circuit.* = try routes.internConnection(allocator, connections, source, @intCast(target), op.argument);
        }
        try definitions.append(allocator, .{ .item = .{ .index = first_item + @as(u16, @intCast(index)), .generation = 1 }, .clips = resolved, .started = output[0], .completed = output[1], .cleanup = output[2], .failure = .reactor_failure });
        try sources.append(allocator, source);
        try signals.append(allocator, .{ spec.start, spec.complete });
        table.register(source, .timed_items);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_signals = try signals.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signals);
    // The original spatial mixer compares carried-item location against raw room
    // neighbors. Empty exits alias that location and make inventory cues audible.
    var audible: std.ArrayList(@import("../geometry.zig").RoomId) = .empty;
    errdefer audible.deinit(allocator);
    for (rooms, 0..) |room, index| for (0..4) |side| {
        if (collision[side * 64 + index] == 255) {
            try audible.append(allocator, room);
            break;
        }
    };
    const owned_audible = try audible.toOwnedSlice(allocator);
    errdefer allocator.free(owned_audible);
    return .{ .audible_rooms = owned_audible, .allocator = allocator, .definitions = owned, .sources = owned_sources, .signals = owned_signals, .clips = try clips.toOwnedSlice(allocator) };
}
