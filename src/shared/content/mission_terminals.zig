//! Import every mission terminal from its complete family and explicit assignment links.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../mission_terminals.zig");
const routes = @import("first_world_props.zig");
const Cue = story_cue.Cue;
const credit_wallet = @import("credit_wallet.zig");
const equipment = @import("../equipment.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
const story_cue = @import("../story_cue.zig");
const string_table = @import("string_table.zig");
pub const Spec = struct {
    states: [5]u16,
    signals: [3]i16,
    briefing: Cue,
    completion: Cue,
    assignment_parameter: u2,
    assignment_signal: i16,
    successor_parameter: u2,
    successor_signal: i16,
    purse_parameter: u2,
};
fn briefing(scene: i16) ?Cue {
    return switch (scene) {
        37 => .delivery_briefing,
        38, 39 => .escort_briefing,
        40 => .reactor_briefing,
        41 => .android_briefing,
        42 => .mutant_briefing,
        else => null,
    };
}
fn completion(scene: i16) ?Cue {
    return switch (scene) {
        66, 67 => .delivery_completed,
        68 => .escort_completed,
        69 => .android_completed,
        70 => .reactor_completed,
        71 => .mutant_completed,
        else => null,
    };
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 12) return null;
    const sources = [_]usize{ 0, 0, 0, 0, 4, 4, 4, 4, 8, 8, 10, 11 };
    const next = [_]u16{ 0, 4, 0, 0, 4, 10, 4, 4, 0, 8, 11, 11 };
    const codes = [_][3]u8{
        .{ 34, 90, 0 },
        .{ 34, 35, 90 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 34, 90, 0 },
        .{ 34, 90, 36 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 34, 0, 0 },
        .{ 0, 0, 67 },
        .{ 0, 101, 0 },
        .{ 0, 0, 67 },
    };
    for (sources, next, codes, 0..) |source, target, ops, index| {
        const r = group.at(index);
        if (r.source != group.at(source).source or
            r.target != group.at(target).source or
            r.next != target or
            r.dx != 0 or
            r.dy != 0 or
            r.flags != 0) return null;
        for (
            [_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect },
            ops,
        ) |value, code| if (value.code != code) return null;
    }
    const a = group.at(0);
    const accept = group.at(1);
    const finished = group.at(5);
    const payout = group.at(10);
    if (a.conditions[0].argument != 30 or
        group.at(4).conditions[0].argument != 30 or
        a.conditions[1].argument != group.at(4).conditions[1].argument or
        accept.effect.argument != 45 or
        payout.conditions[1].argument < 0 or
        payout.conditions[1].argument > 2) return null;
    return .{
        .states = .{
            group.at(8).source,
            a.source,
            group.at(4).source,
            group.at(10).source,
            group.at(11).source,
        },
        .signals = .{
            group.at(8).conditions[0].argument,
            accept.conditions[0].argument,
            finished.conditions[0].argument,
        },
        .briefing = briefing(a.conditions[1].argument) orelse return null,
        .completion = completion(finished.conditions[1].argument) orelse return null,
        .assignment_parameter = @intCast(accept.conditions[1].code - 35),
        .assignment_signal = accept.conditions[1].argument,
        .successor_parameter = @intCast(finished.effect.code - 35),
        .successor_signal = finished.effect.argument,
        .purse_parameter = @intCast(payout.conditions[1].argument),
    };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    signals: [][3]i16,
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
        var result: std.ArrayList(runtime.Binding) = .empty;
        errdefer result.deinit(self.allocator);
        for (
            self.sources,
            self.signals,
            0..,
        ) |source, signals, index| for (connections) |connection| {
            if (connection.recipient != source) continue;
            for (
                signals,
                [_]runtime.Action{ .unlock, .accept, .complete },
            ) |signal, action| if (signal == connection.message) {
                try result.append(
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
        return result.toOwnedSlice(self.allocator);
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
    supplies: []const equipment.Definition,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList([3]i16) = .empty;
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
        const initial: runtime.Phase = for (spec.states, 0..) |state, phase| {
            if (state == record.initial_state) break @fromBackingInt(@as(u3, @intCast(phase)));
        } else return error.UnsupportedMissionTerminalStart;
        var resolved: [5]motion.Clip = undefined;
        for (spec.states, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingMissionTerminal,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const purse_source = record.parameters[spec.purse_parameter];
        if (purse_source < 0 or purse_source >= table.count) return error.InvalidMissionPurse;
        const wallet = try table.record(@intCast(purse_source));
        if (credit_wallet.signal(try rules.group(
            bytes,
            wallet.rule_group,
        )) == null) return error.UnsupportedMissionPurse;
        const purse: equipment.ItemHandle = for (supplies, 0..) |item, i| {
            if (item.kind == .credits) break .{ .index = @intCast(i), .generation = 1 };
        } else return error.MissingMissionPurse;
        const assignment = record.parameters[spec.assignment_parameter];
        const successor = record.parameters[spec.successor_parameter];
        if (assignment < 0 or
            assignment >= table.count or
            successor < 0 or
            successor >= table.count or
            record.contact_icon == 0) return error.InvalidMissionConnection;
        const output = try routes.internConnection(
            allocator,
            connections,
            @intCast(index),
            @intCast(assignment),
            spec.assignment_signal,
        );
        const next = try routes.internConnection(
            allocator,
            connections,
            @intCast(index),
            @intCast(successor),
            spec.successor_signal,
        );
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.signals);
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
                .facing = if (record.facing_right == 0) .left else .right,
                .clips = resolved,
                .initial_phase = initial,
                .briefing = spec.briefing,
                .acceptance = .mission_accepted,
                .completion = spec.completion,
                .assignment = output,
                .successor = next,
                .purse = purse,
                .reward = record.parameters[@as(usize, spec.purse_parameter) + 1],
                .hint = try resolver.icon(record.contact_icon - 1),
                .label = label,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
            },
        );
        table.register(@intCast(index), .mission_terminals);
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
