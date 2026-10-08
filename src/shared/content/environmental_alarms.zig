//! Recover circuit-controlled random rumble bursts and their authored cadence.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../environmental_alarms.zig");
const routes = @import("first_world_props.zig");
pub const Spec = struct {
    states: [3]u16,
    signals: [2]i16,
    chance: i16,
    count_parameter: u2,
    sound: @import("../motion.zig").SoundId,
};
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 8) return null;
    const sources = [_]usize{ 0, 0, 2, 2, 2, 5, 5, 5 };
    const next = [_]u16{ 2, 0, 0, 5, 2, 0, 2, 5 };
    const codes = [_][3]u8{
        .{ 34, 0, 0 },
        .{ 0, 0, 67 },
        .{ 34, 0, 75 },
        .{ 97, 68, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 75 },
        .{ 63, 0, 0 },
        .{ 0, 125, 133 },
    };
    for (sources, next, codes, 0..) |source, target, ops, i| {
        const r = group.at(i);
        if (r.source != group.at(source).source or
            r.target != group.at(target).source or
            r.next != target or
            r.dx != 0 or
            r.dy != 0 or
            r.flags != 0) return null;
        for (
            [_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect },
            ops,
        ) |op, code| if (op.code != code) return null;
    }
    if (group.at(2).conditions[0].argument != group.at(5).conditions[0].argument or
        group.at(3).conditions[0].argument <= 0 or
        group.at(3).conditions[1].argument < 0 or
        group.at(3).conditions[1].argument > 3 or
        group.at(7).conditions[1].argument < 0 or
        group.at(7).conditions[1].argument >= 66) return null;
    return .{
        .states = .{ group.at(0).source, group.at(2).source, group.at(5).source },
        .signals = .{ group.at(0).conditions[0].argument, group.at(2).conditions[0].argument },
        .chance = group.at(3).conditions[0].argument,
        .count_parameter = @intCast(group.at(3).conditions[1].argument),
        .sound = @fromBackingInt(@as(u16, @intCast(group.at(7).conditions[1].argument))),
    };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: [][2]i16,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
    pub fn bind(self: Assets, connections: []const routes.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (
            self.sources,
            self.signals,
            0..,
        ) |source, signals, index| for (connections) |connection| if (connection.recipient == source) {
            for (
                signals,
                [_]runtime.Action{ .start, .stop },
            ) |signal, action| if (connection.message == signal) {
                try bindings.append(
                    self.allocator,
                    .{
                        .circuit = connection.circuit,
                        .target = index,
                        .action = action,
                        .next_step = connection.sender >= source,
                    },
                );
            };
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
pub fn load(
    allocator: std.mem.Allocator,
    table: @import("placement.zig").Table,
    bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]@import("../geometry.zig").RoomId,
    difficulty: @import("../settings.zig").Difficulty,
    resolver: anytype,
) !Assets {
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
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 6 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0]) return error.UnsupportedAlarmStart;
        var resolved: [3]@import("../motion.zig").Clip = undefined;
        for (spec.states, &resolved) |state, *destination| {
            var src = try animation.decode(allocator, animations, state);
            defer src.deinit();
            for (src.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingAlarm,
            };
            var clip = try src.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        try definitions.append(
            allocator,
            .{
                .room = if (record.room < rooms.len) rooms[record.room] else null,
                .clips = resolved,
                .chance_denominator = spec.chance,
                .burst_cycles = record.parameters[spec.count_parameter],
                .burst_sound = spec.sound,
                .initially_active = record.initially_active != 0,
                .accepts_signals = record.flags & 1 != 0,
            },
        );
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.signals);
        table.register(@intCast(index), .environmental_alarms);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_signals = try signals.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signals);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .signals = owned_signals,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
