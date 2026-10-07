//! Compile scripted transport, destination templates and their paired visual effects.
//! Operation130's protection wrapper is deliberately excluded; only relocation is imported.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../scripted_transport.zig");
const routes = @import("first_world_props.zig");
const motion = @import("../motion.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: []i16,
    clips: []animation.OwnedClip,
    player_clips: ?[2]motion.Clip,
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
        for (self.sources, self.signals, 0..) |source, signal, index| for (connections) |connection| if (connection.recipient == source and connection.message == signal) {
            try bindings.append(self.allocator, .{ .circuit = connection.circuit, .target = index, .next_step = connection.sender >= source });
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
fn resolve(allocator: std.mem.Allocator, clips: *std.ArrayList(animation.OwnedClip), bytes: []const u8, state: u16, resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, bytes, state);
    defer source.deinit();
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try clips.append(allocator, clip);
    return clip.clip();
}
fn validRows(group: rules.Group, sources: []const usize, next: []const u16, codes: []const [3]u8) bool {
    if (group.count() != sources.len) return false;
    for (sources, next, codes, 0..) |source, target, operations, i| {
        const row = group.at(i);
        if (row.source != group.at(source).source or row.target != group.at(target).source or row.next != target or row.dx != 0 or row.dy != 0 or row.flags != 0) return false;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, operations) |op, code| if (op.code != code) return false;
    }
    return true;
}
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(routes.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList(i16) = .empty;
    errdefer signals.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var player_clips: ?[2]motion.Clip = null;
    const player = try table.record(0);
    const player_rules = try rules.group(bytes, player.rule_group);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 0 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (!validRows(group, &.{ 0, 0, 2, 2, 4 }, &.{ 2, 0, 4, 2, 0 }, &.{ .{ 34, 0, 0 }, .{ 0, 0, 67 }, .{ 34, 0, 37 }, .{ 0, 0, 35 }, .{ 0, 130, 75 } })) continue;
        const start = group.at(0);
        const ack = group.at(2);
        const request = group.at(3);
        const finish = group.at(4);
        if (record.initial_state != start.source or ack.conditions[0].argument != 12 or record.parameters[0] != 0 or finish.conditions[1].argument != 0) return error.UnsupportedScriptedTransport;
        const target = record.parameters[1];
        const effect_id = record.parameters[2];
        if (target < 0 or target >= table.count or effect_id < 0 or effect_id >= table.count or effect_id <= index) return error.InvalidTransportTarget;
        const destination = try table.record(@intCast(target));
        const effect = try table.record(@intCast(effect_id));
        if (destination.room >= rooms.len or destination.rule_group != player.rule_group or destination.initial_state != 1 or effect.parameters[0] != 0 or effect.flags & 1 == 0) return error.UnsupportedTransportDestination;
        const effect_rules = try rules.group(bytes, effect.rule_group);
        if (!validRows(effect_rules, &.{ 0, 0, 2, 2, 4 }, &.{ 2, 0, 4, 2, 0 }, &.{ .{ 34, 0, 49 }, .{ 0, 0, 75 }, .{ 0, 0, 49 }, .{ 0, 0, 75 }, .{ 0, 0, 75 } }) or effect_rules.at(0).conditions[0].argument != ack.effect.argument or effect_rules.at(0).effect.argument != 0 or effect_rules.at(2).effect.argument != 0 or effect.initial_state != effect_rules.at(0).source) return error.UnsupportedTransportEffect;
        // The player's receiver supplies its acknowledgement and two motion phases.
        const receiver = for (0..player_rules.count()) |i| {
            const row = player_rules.at(i);
            if (row.source == 1 and row.conditions[0].code == 111 and row.conditions[0].argument == request.effect.argument) break row;
        } else return error.MissingTransportReceiver;
        const departure = player_rules.at(receiver.next);
        const recovery = player_rules.at(departure.next);
        if (receiver.dx != 0 or receiver.dy != 0 or receiver.flags != 0 or receiver.conditions[1].code != 0 or receiver.effect.code != 0 or departure.source != receiver.target or recovery.source != departure.target or recovery.target != 1) return error.UnsupportedTransportReceiver;
        for ([_]rules.Rule{ departure, recovery }) |row| {
            if (row.dx != 0 or row.dy != 0 or row.flags != 0 or row.conditions[0].code != 0 or row.conditions[1].code != 0 or row.effect.code != 0) return error.UnsupportedTransportRecovery;
        }
        if (player_clips == null) player_clips = .{ try resolve(allocator, &clips, animations, departure.source, resolver), try resolve(allocator, &clips, animations, recovery.source, resolver) };
        const cadence = [3]motion.Clip{ try resolve(allocator, &clips, animations, start.source, resolver), try resolve(allocator, &clips, animations, ack.source, resolver), try resolve(allocator, &clips, animations, finish.source, resolver) };
        for (cadence) |clip| {
            if (clip.sound != null) return error.AudibleTransportCadence;
            for (clip.steps) |step| switch (step) {
                .hold => {},
                .frame => |frame| if (frame.forward != 0 or frame.down != 0) return error.MovingTransportCadence,
            };
        }
        const effect_clips = [2]motion.Clip{ try resolve(allocator, &clips, animations, effect_rules.at(2).source, resolver), try resolve(allocator, &clips, animations, effect_rules.at(4).source, resolver) };
        // Register every authored output even when the consumer is compiled into this component.
        _ = try routes.internConnection(allocator, connections, @intCast(index), @intCast(effect_id), ack.effect.argument);
        _ = try routes.internConnection(allocator, connections, @intCast(index), 0, request.effect.argument);
        try definitions.append(allocator, .{ .destination = .{ .room = rooms[destination.room], .position = destination.position, .facing = if (destination.facing_right == 0) .left else .right }, .cadence = cadence, .effect_clips = effect_clips, .palette_bank = @intCast(effect.visual_flags & 3), .behind_player = effect.visual_flags & 8 != 0, .accepts_signals = record.flags & 1 != 0 });
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, start.conditions[0].argument);
        table.register(@intCast(index), .scripted_transport);
        table.register(@intCast(effect_id), .scripted_transport);
        table.register(@intCast(target), .transport_templates);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_signals = try signals.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signals);
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .signals = owned_signals, .clips = try clips.toOwnedSlice(allocator), .player_clips = player_clips };
}
