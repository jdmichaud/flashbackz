//! Recover stationary gun profiles, timers, trigger routes and projectile bindings.
const std = @import("std");
const runtime = @import("../ceiling_guns.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const connections = @import("first_world_props.zig");
const Spec = struct {
    states: [7]u16,
    cycle: runtime.Cycle,
    triggers: [3]?i16 = @splat(null),
    stop: ?i16 = null,
    rearm: ?i16 = null,
    initial_parameter: u2,
    charge_parameter: ?u2 = null,
    repeat_parameter: ?u2 = null,
    cooling_wait: i16,
    weapon_parameter: u2,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    bindings: []runtime.Binding,
    weapons: []@import("../pistol_shot.zig").Definition,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        self.allocator.free(self.bindings);
        self.allocator.free(self.weapons);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn find(group: rules.Group, state: u16, code: u8) ?rules.Rule {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source != state) continue;
        if (code == 0) {
            if (r.conditions[0].code == 0 and r.conditions[1].code == 0) return r;
        } else if (r.conditions[0].code == code or r.conditions[1].code == code) return r;
    }
    return null;
}
fn parameter(op: rules.Operation) !u2 {
    if (op.code != 68 or op.argument < 0 or op.argument > 3) return error.UnsupportedCeilingGunTimer;
    return @intCast(op.argument);
}
fn discover(group: rules.Group) !?Spec {
    if (group.count() != 10 and group.count() != 14 and group.count() != 19) return null;
    const first = group.at(0);
    if (first.conditions[0].code != 34 or first.conditions[1].code != 0 or first.source == first.target) return null;
    const deployed = find(group, first.target, 68) orelse return null;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    }
    const shot = for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.conditions[1].code >= 35 and r.conditions[1].code <= 38 and r.conditions[1].argument == 40) break r;
    } else return null;
    const charge = for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.conditions[0].code == 63 and r.target == shot.source) break r.source;
    } else return error.MissingCeilingGunCharge;
    const waiting = if (deployed.target == charge) shot.target else deployed.target;
    const retract = for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source != first.source and r.target == first.source and r.conditions[0].code == 0 and r.conditions[1].code == 0 and r.effect.code == 0) break r.source;
    } else return error.MissingCeilingGunRetraction;
    const cycle: runtime.Cycle = if (deployed.target == charge) .per_signal else blk: {
        const complete = find(group, shot.target, 0) orelse return error.MissingCeilingGunCooling;
        break :blk if (complete.effect.code == 68 and complete.target == waiting) .repeating else .retract_after_shot;
    };
    var spec: Spec = .{
        .states = .{ first.source, first.target, waiting, charge, shot.source, if (cycle == .per_signal) waiting else shot.target, retract },
        .cycle = cycle,
        .initial_parameter = try parameter(deployed.conditions[0]),
        .cooling_wait = if (shot.effect.code == 62) shot.effect.argument else 0,
        .weapon_parameter = @intCast(shot.conditions[1].code - 35),
    };
    var trigger_count: usize = 0;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == first.source and r.target == first.target and r.conditions[0].code == 34) {
            if (trigger_count == spec.triggers.len) return error.TooManyCeilingGunTriggers;
            spec.triggers[trigger_count] = r.conditions[0].argument;
            trigger_count += 1;
        }
    }
    if (cycle != .per_signal) {
        const waiting_end = find(group, waiting, 63) orelse return error.MissingCeilingGunWait;
        spec.charge_parameter = try parameter(waiting_end.conditions[1]);
        if (cycle == .repeating) {
            spec.repeat_parameter = try parameter((find(group, shot.target, 0) orelse return error.MissingCeilingGunCooling).effect);
        } else {
            const stop = find(group, waiting, 34) orelse return error.MissingCeilingGunStop;
            const rearm = find(group, shot.target, 34) orelse return error.MissingCeilingGunRearm;
            if (stop.target != retract or rearm.target != waiting) return error.UnsupportedCeilingGunControl;
            spec.stop = stop.conditions[0].argument;
            spec.rearm = rearm.conditions[0].argument;
            spec.repeat_parameter = try parameter(rearm.effect);
        }
    }
    return spec;
}
fn resolve(allocator: std.mem.Allocator, animations: []const u8, state: u16, clips: *std.ArrayList(animation.OwnedClip), resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    var dx: i32 = 0;
    var dy: i32 = 0;
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |f| {
            dx += f.dx;
            dy += f.dy;
        },
    };
    // Firing rocks the gun by one pixel and returns it to the mount.
    if (dx != 0 or dy != 0) return error.DriftingCeilingGunAnchor;
    var owned = try source.resolve(allocator, resolver);
    errdefer owned.deinit();
    try clips.append(allocator, owned);
    return owned.clip();
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: []const connections.Connection, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var weapons: std.ArrayList(@import("../pistol_shot.zig").Definition) = .empty;
    errdefer weapons.deinit(allocator);
    var families: [256]?struct { index: usize, spec: Spec } = @splat(null);
    var weapon_ids: [256]?usize = @splat(null);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 4 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.rule_group >= families.len) return error.InvalidCeilingGunGroup;
        if (families[record.rule_group] == null) {
            const spec = try discover(try rules.group(rule_bytes, record.rule_group)) orelse continue;
            var resolved: [7]motion.Clip = undefined;
            for (spec.states, &resolved) |state, *clip| clip.* = try resolve(allocator, animations, state, &clips, resolver);
            const index = profiles.items.len;
            try profiles.append(allocator, .{ .clips = resolved, .cycle = spec.cycle, .cooling_wait = spec.cooling_wait });
            families[record.rule_group] = .{ .index = index, .spec = spec };
        }
        const family = families[record.rule_group].?;
        const spec = family.spec;
        if (record.initial_state != spec.states[0] or record.room >= rooms.len) return error.UnsupportedCeilingGunPlacement;
        const endpoint = record.parameters[spec.weapon_parameter];
        if (endpoint < 0 or endpoint >= table.count) return error.InvalidCeilingGunWeapon;
        const weapon_index: usize = @intCast(endpoint);
        if (weapon_ids[weapon_index] == null) {
            const target = try table.record(@intCast(endpoint));
            if (target.flags & 1 == 0) return error.UnsupportedCeilingGunEmitter;
            const weapon = try @import("weapon_effects.zig").load(allocator, target, rule_bytes, animations, &clips, resolver);
            const index = weapons.items.len;
            try weapons.append(allocator, weapon);
            weapon_ids[weapon_index] = index;
        }
        for (routes) |route| if (route.recipient == i) {
            const action: runtime.Action = if (spec.rearm != null and route.message == spec.rearm.?) .rearm else if (spec.stop != null and route.message == spec.stop.?) .stop else trigger: {
                for (spec.triggers) |message| if (message != null and message.? == route.message) break :trigger .trigger;
                break :trigger .wake;
            };
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = definitions.items.len, .action = action, .next_step = route.sender >= i });
        };
        table.register(@intCast(i), .ceiling_guns);
        table.register(@intCast(weapon_index), .weapon_effects);
        try definitions.append(allocator, .{ .profile = family.index, .room = rooms[record.room], .position = record.position, .facing = if (record.facing_right == 0) .left else .right, .initial_wait = record.parameters[spec.initial_parameter], .charge_wait = if (spec.charge_parameter) |p| record.parameters[p] else 0, .repeat_wait = if (spec.repeat_parameter) |p| record.parameters[p] else 0, .weapon = weapon_ids[weapon_index].?, .shot_next_step = i > weapon_index, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0 });
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_definitions);
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    const owned_weapons = try weapons.toOwnedSlice(allocator);
    errdefer allocator.free(owned_weapons);
    return .{ .allocator = allocator, .definitions = owned_definitions, .profiles = owned_profiles, .bindings = owned_bindings, .weapons = owned_weapons, .clips = try clips.toOwnedSlice(allocator) };
}
