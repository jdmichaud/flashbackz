//! Recover released-civilian conversations and their item/station/path connections.
const std = @import("std");
const runtime = @import("../actors/rescued_guide.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const routes_mod = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    sources: []u16,
    signals: []i16,
    payments: []runtime.Payment,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
        self.allocator.free(self.payments);
    }
    pub fn bind(self: Assets, routes: []const routes_mod.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signal, index| for (routes) |route| {
            if (route.recipient == source and route.message == signal) try bindings.append(
                self.allocator,
                .{ .circuit = route.circuit, .actor = index, .next_step = route.sender >= source },
            );
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
const Spec = struct {
    states: [14]u16,
    distance: i16,
    cycles: i16,
    end: i16,
    invitation: i16,
    briefing: i16,
    incoming: i16,
    outputs: [3]i16,
};
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 25) return null;
    const starts = [_]usize{
        0,
        0,
        0,
        3,
        4,
        4,
        4,
        7,
        8,
        9,
        10,
        10,
        10,
        13,
        13,
        13,
        16,
        17,
        18,
        19,
        19,
        21,
        22,
        22,
        22,
    };
    const next = [_]u16{
        3,
        0,
        0,
        4,
        7,
        4,
        4,
        8,
        9,
        10,
        10,
        16,
        10,
        13,
        13,
        13,
        17,
        18,
        19,
        21,
        18,
        22,
        13,
        22,
        22,
    };
    const codes = [_][3]u8{
        .{ 120, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 34, 123, 0 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 34, 123, 35 },
        .{ 0, 0, 0 },
        .{ 37, 0, 0 },
        .{ 62, 0, 0 },
        .{ 0, 0, 0 },
        .{ 63, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 36 },
        .{ 34, 0, 0 },
        .{ 34, 123, 0 },
        .{ 0, 0, 0 },
    };
    for (starts, next, codes, 0..) |source, target, operations, index| {
        const r = group.at(index);
        if (r.source != group.at(source).source or
            r.target != group.at(target).source or
            r.next != target or
            r.dx != 0 or
            r.dy != 0 or
            r.flags != @as(
                u8,
                if (index == 3 or index == 16) 1 else 0,
            )) return null;
        for (
            [_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect },
            operations,
        ) |operation, code| if (operation.code != code) return null;
    }
    for ([_]usize{
        11,
        14,
        23,
    }) |index| if (group.at(index).conditions[0].argument != 30) return null;
    if (group.at(4).conditions[0].argument != group.at(22).conditions[0].argument or
        group.at(11).conditions[1].argument != group.at(23).conditions[1].argument) return null;
    var states: [14]u16 = undefined;
    for (
        &states,
        [_]usize{ 0, 3, 4, 7, 8, 9, 10, 13, 16, 17, 18, 19, 21, 22 },
    ) |*state, index| state.* = group.at(index).source;
    return .{
        .states = states,
        .distance = group.at(0).conditions[0].argument * 16,
        .cycles = group.at(17).conditions[0].argument,
        .end = group.at(19).conditions[0].argument,
        .invitation = group.at(11).conditions[1].argument,
        .briefing = group.at(14).conditions[1].argument,
        .incoming = group.at(4).conditions[0].argument,
        .outputs = .{
            group.at(14).effect.argument,
            group.at(21).effect.argument,
            group.at(16).conditions[0].argument,
        },
    };
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    names: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: @import("../settings.zig").Difficulty,
    routes: *std.ArrayList(routes_mod.Connection),
    supplies: []const @import("../equipment.zig").Definition,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList(i16) = .empty;
    errdefer signals.deinit(allocator);
    var payments: std.ArrayList(runtime.Payment) = .empty;
    errdefer payments.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 3 or
            record.room >= rooms.len or
            record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.contact_icon == 0 or
            spec.invitation < 0 or
            spec.briefing < 0) return error.UnsupportedGuidePresentation;
        const initial: runtime.Phase = for (spec.states, 0..) |state, phase| {
            if (state == record.initial_state) break @fromBackingInt(@as(u4, @intCast(phase)));
        } else return error.UnsupportedGuideStart;
        var profile: runtime.Profile = .{
            .clips = undefined,
            .attention_distance = spec.distance,
            .walking_cycles = spec.cycles,
            .walking_end = spec.end,
            .invitation = @fromBackingInt(@as(u16, @intCast(spec.invitation))),
            .briefing = @fromBackingInt(@as(u16, @intCast(spec.briefing))),
        };
        for (spec.states, &profile.clips) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            if (source.kind != .composition) return error.UnsupportedGuideArtwork;
            var resolved = try source.resolve(allocator, resolver);
            errdefer resolved.deinit();
            try clips.append(allocator, resolved);
            destination.* = resolved.clip();
        }
        const profile_index = profiles.items.len;
        try profiles.append(allocator, profile);
        var outputs: [3]@import("../world_props.zig").CircuitId = undefined;
        for (&outputs, spec.outputs, 0..) |*output, signal, parameter| {
            const target = record.parameters[parameter];
            if (target < 0 or target >= table.count) return error.InvalidGuideConnection;
            output.* = try routes_mod.internConnection(
                allocator,
                routes,
                @intCast(index),
                @intCast(target),
                signal,
            );
        }
        for (0..table.count) |source| {
            const item = try table.record(@intCast(source));
            if (item.initially_active == 0 or item.parameters[0] != record.kind) continue;
            const signal = @import("credit_wallet.zig").signal(try rules.group(
                rule_bytes,
                item.rule_group,
            )) orelse continue;
            if (signal != spec.incoming) continue;
            for (supplies, 0..) |supply, item_index| if (supply.kind == .credits) {
                try payments.append(
                    allocator,
                    .{
                        .item = .{ .index = @intCast(item_index), .generation = 1 },
                        .actor = definitions.items.len,
                        .next_step = source >= index,
                    },
                );
                break;
            };
        }
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.incoming);
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        table.register(@intCast(index), .rescued_guides);
        try definitions.append(
            allocator,
            .{
                .profile = profile_index,
                .initial_phase = initial,
                .footprint = .{
                    .room = rooms[record.room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
                .interaction_priority = @intCast(index),
                .hint = try resolver.icon(record.contact_icon - 1),
                .label = label,
                .offer_threshold = record.life,
                .path = outputs[0],
                .station = outputs[1],
                .reward = outputs[2],
            },
        );
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_signals = try signals.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signals);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .profiles = owned_profiles,
        .clips = owned_clips,
        .sources = owned_sources,
        .signals = owned_signals,
        .payments = try payments.toOwnedSlice(allocator),
    };
}
