//! Recover credential-operated relay terminals without embedding their destinations.
const std = @import("std");
const rules = @import("rule_table.zig");
const runtime = @import("../credential_terminals.zig");
const animation = @import("animation.zig");
const routes = @import("first_world_props.zig");
const geometry = @import("../geometry.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
const string_table = @import("string_table.zig");
const world_props = @import("../world_props.zig");
pub const Spec = struct { idle: u16, signal: i16, outputs: [2]rules.Operation, notice: i16 };
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 3) return null;
    const codes = [_][3]u8{ .{ 34, 36, 35 }, .{ 34, 0, 123 }, .{ 0, 0, 67 } };
    for (codes, 0..) |ops, i| {
        const r = group.at(i);
        if (r.source != group.at(0).source or
            r.target != r.source or
            r.next != 0 or
            r.dx != 0 or
            r.dy != 0 or
            r.flags != 0) return null;
        for (
            [_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect },
            ops,
        ) |op, code| if (op.code != code) return null;
    }
    if (group.at(1).conditions[0].argument != 30 or group.at(1).effect.argument < 0) return null;
    return .{
        .idle = group.at(0).source,
        .signal = group.at(0).conditions[0].argument,
        .outputs = .{ group.at(0).conditions[1], group.at(0).effect },
        .notice = group.at(1).effect.argument,
    };
}
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
        for (
            self.sources,
            self.signals,
            0..,
        ) |source, signal, index| for (connections) |connection| if (connection.recipient == source and
            connection.message == signal)
        {
            try bindings.append(
                self.allocator,
                .{
                    .circuit = connection.circuit,
                    .target = index,
                    .next_step = connection.sender >= source,
                },
            );
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    bytes: []const u8,
    animations: []const u8,
    names: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    connections: *std.ArrayList(routes.Connection),
    resolver: anytype,
) !Assets {
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
        if (record.kind != 5 or
            record.room >= rooms.len or
            record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.idle or
            record.contact_icon == 0) return error.UnsupportedCredentialTerminal;
        var outputs: [2]world_props.CircuitId = undefined;
        for (spec.outputs, &outputs) |op, *circuit| {
            const target = record.parameters[op.code - 35];
            if (target < 0 or target >= table.count) return error.InvalidTerminalTarget;
            circuit.* = try routes.internConnection(
                allocator,
                connections,
                @intCast(index),
                @intCast(target),
                op.argument,
            );
        }
        var source = try animation.decode(allocator, animations, spec.idle);
        defer source.deinit();
        if (source.sound != null) return error.AudibleTerminalMarker;
        for (source.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingTerminal,
        };
        var clip = try source.resolve(allocator, resolver);
        clips.append(allocator, clip) catch |err| {
            clip.deinit();
            return err;
        };
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.signal);
        const label = try string_table.copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(
            allocator,
            .{
                .footprint = .{
                    .room = rooms[record.room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .clip = clip.clip(),
                .outputs = outputs,
                .notice = @fromBackingInt(@as(u16, @intCast(spec.notice))),
                .hint = try resolver.icon(record.contact_icon - 1),
                .label = label,
                .priority = @intCast(index),
                .initially_active = record.initially_active != 0,
                .accepts_signals = record.flags & 1 != 0,
            },
        );
        table.register(@intCast(index), .credential_terminals);
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
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .signals = owned_signals,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
