//! Translate continuous and one-shot detector graphs into senses, animations and circuits.
const std = @import("std");
const runtime = @import("../detectors.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const connections = @import("first_world_props.zig");
const settings = @import("../settings.zig");
const Route = struct { parameter: u2, message: i16 };
const Spec = struct {
    states: [5]u16,
    enable: i16,
    disable: i16,
    outputs: [2]?Route,
    disable_after_pulse: bool,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.outputs);
        self.allocator.free(self.definitions);
        for (self.profiles) |profile| {
            self.allocator.free(profile.acquire);
            self.allocator.free(profile.sustain);
        }
        self.allocator.free(self.profiles);
        self.allocator.free(self.bindings);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn find(group: rules.Group, state: u16, code: u8) ?rules.Rule {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == state and
            r.conditions[0].code == code and
            r.conditions[1].code == 0) return r;
    }
    return null;
}
fn outputs(rule: rules.Rule) ![2]?Route {
    var result: [2]?Route = @splat(null);
    var count: usize = 0;
    for ([_]rules.Operation{
        rule.conditions[0],
        rule.conditions[1],
        rule.effect,
    }) |operation| if (operation.code >= 35 and operation.code <= 38) {
        if (count == result.len) return error.UnsupportedDetectorOutputs;
        result[count] = .{
            .parameter = @intCast(operation.code - 35),
            .message = operation.argument,
        };
        count += 1;
    };
    return result;
}
fn discover(group: rules.Group) !?Spec {
    if (group.count() != 10 and group.count() != 12 and group.count() != 20) return null;
    const enable = group.at(0);
    if (enable.conditions[0].code != 34 or
        enable.conditions[1].code != 0 or
        enable.source == enable.target) return null;
    const enabled = find(group, enable.target, 0) orelse return null;
    if (enabled.effect.code != 0) return null;
    const disable = find(group, enabled.target, 34) orelse return null;
    const disabled = find(group, disable.target, 0) orelse return null;
    if (disabled.target != enable.source) return null;
    var detecting: ?u16 = null;
    var route: [2]?Route = @splat(null);
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        if (r.source != enabled.target) continue;
        const out = try outputs(r);
        if (out[0] == null) continue;
        if (r.conditions[0].code != 120 and
            r.conditions[0].code != 121 and
            !(r.conditions[0].code == 0 and r.conditions[1].code == 64)) return null;
        if (detecting != null and (r.target != detecting.? or !std.meta.eql(
            route,
            out,
        ))) return error.UnsupportedDetectorPulse;
        detecting = r.target;
        route = out;
    }
    const active = detecting orelse return null;
    const complete = find(group, active, 0) orelse return error.UnsupportedDetectorRecovery;
    if (complete.target != enabled.target and
        complete.target != disable.target) return error.UnsupportedDetectorRecovery;
    return .{
        .states = .{ enable.source, enable.target, enabled.target, active, disable.target },
        .enable = enable.conditions[0].argument,
        .disable = disable.conditions[0].argument,
        .outputs = route,
        .disable_after_pulse = complete.target == disable.target,
    };
}
fn senses(allocator: std.mem.Allocator, group: rules.Group, state: u16) ![]runtime.Sense {
    var result: std.ArrayList(runtime.Sense) = .empty;
    errdefer result.deinit(allocator);
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != state) continue;
        const out = try outputs(rule);
        if (out[0] == null) continue;
        const a = rule.conditions[0];
        const b = rule.conditions[1];
        const sense: runtime.Sense = if (a.code == 120 or a.code == 121) blk: {
            if (a.argument < 0 or a.argument > 64) return error.InvalidDetectorRange;
            break :blk if (a.code == 120) .{ .player_front = a.argument * 16 } else .{ .player_behind = a.argument * 16 };
        } else if (a.code == 0 and b.code == 64) .{ .contacts = .{
            .kind = switch (a.argument) {
                1 => .player,
                3 => .interactable,
                10 => .enemy,
                else => return error.UnsupportedDetectorContactKind,
            },
            .cells = @intCast(@max(1, @min(@abs(b.argument), 16))),
            .behind = b.argument < 0,
        } } else return error.UnsupportedDetectorSense;
        try result.append(allocator, sense);
    }
    return result.toOwnedSlice(allocator);
}
fn resolve(
    allocator: std.mem.Allocator,
    animations: []const u8,
    state: u16,
    clips: *std.ArrayList(animation.OwnedClip),
    resolver: anytype,
) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingDetectorAnchor,
    };
    var owned = try source.resolve(allocator, resolver);
    errdefer owned.deinit();
    try clips.append(allocator, owned);
    return owned.clip();
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    routes: *std.ArrayList(connections.Connection),
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| allocator.free(definition.outputs);
        definitions.deinit(allocator);
    }
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer {
        for (profiles.items) |profile| {
            allocator.free(profile.acquire);
            allocator.free(profile.sustain);
        }
        profiles.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var families: [256]?struct { profile: usize, spec: Spec } = @splat(null);
    var instances: [256]?struct { index: usize, spec: Spec } = @splat(null);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.rule_group >= families.len) return error.InvalidDetectorGroup;
        if (families[record.rule_group] == null) {
            const group = try rules.group(rule_bytes, record.rule_group);
            const spec = try discover(group) orelse continue;
            var resolved: [5]motion.Clip = undefined;
            for (spec.states, &resolved) |state, *clip| clip.* = try resolve(
                allocator,
                animations,
                state,
                &clips,
                resolver,
            );
            const acquire = try senses(
                allocator,
                group,
                spec.states[@backingInt(runtime.Phase.monitoring)],
            );
            errdefer allocator.free(acquire);
            const sustain = if (spec.disable_after_pulse) try allocator.alloc(
                runtime.Sense,
                0,
            ) else try senses(
                allocator,
                group,
                spec.states[@backingInt(runtime.Phase.detecting)],
            );
            errdefer allocator.free(sustain);
            const index = profiles.items.len;
            try profiles.append(
                allocator,
                .{
                    .clips = resolved,
                    .acquire = acquire,
                    .sustain = sustain,
                    .disable_after_pulse = spec.disable_after_pulse,
                },
            );
            families[record.rule_group] = .{ .profile = index, .spec = spec };
        }
        const family = families[record.rule_group].?;
        const phase: runtime.Phase = for (family.spec.states, 0..) |state, j| {
            if (record.initial_state == state) break @fromBackingInt(@as(u3, @intCast(j)));
        } else return error.UnsupportedDetectorStart;
        if (record.room >= rooms.len) return error.InvalidDetectorRoom;
        var out: std.ArrayList(runtime.CircuitId) = .empty;
        errdefer out.deinit(allocator);
        for (family.spec.outputs) |optional| if (optional) |route| {
            const target = record.parameters[route.parameter];
            if (target < 0 or target >= table.count) return error.InvalidDetectorTarget;
            try out.append(
                allocator,
                try connections.internConnection(
                    allocator,
                    routes,
                    @intCast(i),
                    @intCast(target),
                    route.message,
                ),
            );
        };
        const owned_outputs = try out.toOwnedSlice(allocator);
        errdefer allocator.free(owned_outputs);
        instances[i] = .{ .index = definitions.items.len, .spec = family.spec };
        table.register(@intCast(i), .detectors);
        try definitions.append(
            allocator,
            .{
                .profile = family.profile,
                .room = rooms[record.room],
                .position = record.position,
                .facing = if (record.facing_right == 0) .left else .right,
                .initial_phase = phase,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .outputs = owned_outputs,
            },
        );
    }
    for (routes.items) |route| if (instances[route.recipient]) |instance| {
        try bindings.append(
            allocator,
            .{
                .circuit = route.circuit,
                .target = instance.index,
                .action = if (route.message == instance.spec.enable) .enable else if (route.message == instance.spec.disable) .disable else .wake,
                .next_step = route.sender >= route.recipient,
            },
        );
    };
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned_definitions) |definition| allocator.free(definition.outputs);
        allocator.free(owned_definitions);
    }
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer {
        for (owned_profiles) |profile| {
            allocator.free(profile.acquire);
            allocator.free(profile.sustain);
        }
        allocator.free(owned_profiles);
    }
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    return .{
        .allocator = allocator,
        .definitions = owned_definitions,
        .profiles = owned_profiles,
        .bindings = owned_bindings,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
