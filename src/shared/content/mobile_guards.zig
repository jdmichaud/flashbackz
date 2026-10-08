//! Translate the complete powered-guard family into pursuit, flight and injury content.
//! Rule positions below identify semantic animation roles at import; they are never executed.
const std = @import("std");
const runtime = @import("../actors/mobile_guard.zig");
const flight = @import("../actors/guard_flight.zig");
const wound = @import("../actors/guard_wound.zig");
const motion = @import("../motion.zig");
const combat = @import("../combat.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const routes_mod = @import("first_world_props.zig");
const pistol_shot = @import("../pistol_shot.zig");
const settings = @import("../settings.zig");
const weapon_effects = @import("weapon_effects.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    weapons: []pistol_shot.Definition,
    clips: []animation.OwnedClip,
    sources: []u16,
    activation_signal: i16,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        for (self.profiles) |profile| self.allocator.free(profile.hits);
        self.allocator.free(self.profiles);
        self.allocator.free(self.weapons);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.sources);
    }
    pub fn bind(self: Assets, routes: []const routes_mod.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, 0..) |source, index| for (routes) |route| {
            if (route.recipient == source and
                route.message == self.activation_signal) try bindings.append(
                self.allocator,
                .{ .circuit = route.circuit, .actor = index, .next_step = route.sender >= source },
            );
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
fn recognize(group: rules.Group) bool {
    return group.count() == 207 and
        group.at(0).conditions[0].code == 107 and
        group.at(1).conditions[0].code == 107 and
        group.at(2).conditions[1].code == 122 and
        group.at(9).conditions[0].code == 118 and
        group.at(11).conditions[0].code == 119 and
        group.at(201).conditions[0].code == 34 and
        group.at(201).effect.code == 87 and
        group.at(201).target == group.at(0).source and
        group.at(206).effect.code == 75;
}
const Import = struct {
    allocator: std.mem.Allocator,
    group: rules.Group,
    animations: []const u8,
    clips: *std.ArrayList(animation.OwnedClip),
    policies: std.ArrayList(runtime.HitPolicy) = .empty,
    cached: std.AutoHashMap(u16, motion.Clip),
    fn deinit(self: *Import) void {
        self.policies.deinit(self.allocator);
        self.cached.deinit();
    }
    fn clip(self: *Import, rule_index: usize, resolver: anytype) !motion.Clip {
        const state = self.group.at(rule_index).source;
        if (self.cached.get(state)) |value| return value;
        var source = try animation.decode(self.allocator, self.animations, state);
        defer source.deinit();
        var resolved = try source.resolve(self.allocator, resolver);
        errdefer resolved.deinit();
        var policy: runtime.HitPolicy = .{};
        var order: [4]usize = @splat(std.math.maxInt(usize));
        for (0..self.group.count()) |index| {
            const rule = self.group.at(index);
            if (rule.source != state) continue;
            for (std.enums.values(combat.Impact), 0..) |impact, slot| {
                if (policy.responses[slot] != null) continue;
                const op = rule.conditions[0];
                const matches = (op.code == 107 and op.argument == @as(
                    i16,
                    if (impact == .rear_high or impact == .rear_low) 0 else 1,
                )) or (op.code == 34 and op.argument == @as(i16, @intCast(slot + 1)));
                if (!matches) continue;
                if (rule.conditions[1].code != 0 or
                    rule.effect.code != 0 or
                    rule.flags & ~@as(u8, 5) != 0) return error.UnsupportedGuardHit;
                const direction: wound.Direction = if (rule.target == self.group.at(155).source) .forward else if (rule.target == self.group.at(172).source) .backward else return error.UnsupportedGuardHit;
                policy.responses[slot] = .{
                    .direction = direction,
                    .forward = -@as(i16, rule.dx),
                    .down = rule.dy,
                    .turn = rule.flags & 1 != 0,
                    .health_delta = if (rule.flags & 4 != 0) 1 else 0,
                };
                order[slot] = index;
            }
        }
        for (1..4) |index| {
            var at = index;
            while (at > 0 and
                order[@backingInt(policy.priority[at])] < order[@backingInt(policy.priority[at - 1])]) : (at -= 1) std.mem.swap(
                combat.Impact,
                &policy.priority[at],
                &policy.priority[at - 1],
            );
        }
        resolved.hit_profile = @fromBackingInt(@as(u16, @intCast(self.policies.items.len)));
        try self.policies.append(self.allocator, policy);
        const result = resolved.clip();
        try self.cached.put(state, result);
        try self.clips.append(self.allocator, resolved);
        return result;
    }
    fn landing(
        self: *Import,
        target_rule: usize,
        transition_rule: usize,
        resolver: anytype,
    ) !wound.Landing {
        const rule = self.group.at(transition_rule);
        return .{
            .clip = try self.clip(target_rule, resolver),
            .forward = -@as(i16, rule.dx),
            .down = rule.dy,
        };
    }
    fn profile(self: *Import, resolver: anytype) !runtime.Profile {
        const g = self.group;
        var result: runtime.Profile = .{
            .standing = try self.clip(0, resolver),
            .walks = .{ try self.clip(26, resolver), try self.clip(36, resolver) },
            .turning = try self.clip(47, resolver),
            .checking_takeoff = try self.clip(87, resolver),
            .crouching = try self.clip(62, resolver),
            .crouched = try self.clip(65, resolver),
            .rising = try self.clip(77, resolver),
            .dormant = try self.clip(201, resolver),
            .defeated = try self.clip(206, resolver),
            .firing = .{
                .{
                    .windup = try self.clip(50, resolver),
                    .discharge = try self.clip(55, resolver),
                    .recovery = try self.clip(59, resolver),
                },
                .{
                    .windup = try self.clip(70, resolver),
                    .discharge = try self.clip(74, resolver),
                    .recovery = try self.clip(65, resolver),
                },
                .{
                    .windup = try self.clip(80, resolver),
                    .discharge = try self.clip(83, resolver),
                    .recovery = try self.clip(85, resolver),
                },
            },
            .flight = .{
                .starts = .{
                    try self.clip(93, resolver),
                    try self.clip(116, resolver),
                    try self.clip(126, resolver),
                },
                .thrusts = .{
                    try self.clip(96, resolver),
                    try self.clip(119, resolver),
                    try self.clip(129, resolver),
                },
                .alignments = .{
                    try self.clip(99, resolver),
                    try self.clip(123, resolver),
                    try self.clip(132, resolver),
                },
                .landing = try self.clip(101, resolver),
                .braking = try self.clip(105, resolver),
                .drifting = try self.clip(108, resolver),
                .rising = try self.clip(124, resolver),
                .turning_exit = try self.clip(125, resolver),
                .dropping = try self.clip(133, resolver),
                .seeking_height = try self.clip(136, resolver),
                .turning = try self.clip(144, resolver),
                .turn_confirmed = try self.clip(153, resolver),
                .rising_to_ledge = try self.clip(154, resolver),
                .drifting_to_ledge = try self.clip(113, resolver),
                .search_distances = .{
                    g.at(137).conditions[1].argument,
                    g.at(139).conditions[1].argument,
                    g.at(141).conditions[1].argument,
                },
                .landing_advance = -@as(i16, g.at(100).dx),
            },
            .wound = .{
                .impacts = .{ try self.clip(155, resolver), try self.clip(172, resolver) },
                .forward_recovery = .{
                    try self.clip(187, resolver),
                    try self.clip(186, resolver),
                    try self.clip(185, resolver),
                },
                .backward_recovery = .{
                    try self.clip(191, resolver),
                    try self.clip(190, resolver),
                    try self.clip(189, resolver),
                    try self.clip(188, resolver),
                },
                .forward_fatal = .{
                    .{
                        .launch = try self.clip(170, resolver),
                        .ground = try self.landing(195, 171, resolver),
                        .drop = try self.landing(198, 170, resolver),
                    },
                    .{
                        .launch = try self.clip(168, resolver),
                        .ground = try self.landing(194, 169, resolver),
                        .drop = try self.landing(197, 168, resolver),
                    },
                    .{
                        .launch = try self.clip(164, resolver),
                        .ground = try self.landing(193, 167, resolver),
                        .drop = try self.landing(196, 164, resolver),
                    },
                    .{ .launch = try self.clip(192, resolver) },
                },
                .backward_fatal = .{
                    .{
                        .launch = try self.clip(183, resolver),
                        .ground = try self.landing(199, 184, resolver),
                        .drop = try self.landing(200, 183, resolver),
                    },
                    .{
                        .launch = try self.clip(181, resolver),
                        .ground = try self.landing(199, 182, resolver),
                        .drop = try self.landing(200, 181, resolver),
                    },
                    .{
                        .launch = try self.clip(179, resolver),
                        .ground = try self.landing(199, 180, resolver),
                        .drop = try self.landing(200, 179, resolver),
                    },
                },
                // Main6c0e awards on each successful health predicate, including when
                // the following clearance predicate rejects that particular branch.
                .recovery_score = 100,
                .forward_scores = .{ 100, 200, 300, 400, 500, 600 },
                .backward_scores = .{ 100, 200, 300 },
            },
            .hits = &.{},
            .crouch_senses = .{
                .{ .category = .player, .same_facing = false, .impact = .front_high },
                .{ .category = .player, .same_facing = true, .impact = .rear_high },
            },
            .shoot_distance = g.at(6).conditions[1].argument * 16,
            .ally_wait_distance = g.at(5).conditions[0].argument * 16,
            .ally_scan_cells = @intCast(g.at(5).conditions[1].argument),
            .takeoff_ledges = .{
                -g.at(89).conditions[1].argument,
                -g.at(90).conditions[1].argument,
                -g.at(91).conditions[1].argument,
            },
            .flight_fire_exit_chance = g.at(80).conditions[0].argument,
            .recoil_compensation = -@as(i16, g.at(58).dx),
        };
        result.hits = try self.policies.toOwnedSlice(self.allocator);
        return result;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    routes: *std.ArrayList(routes_mod.Connection),
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer {
        for (profiles.items) |profile| allocator.free(profile.hits);
        profiles.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var weapons: std.ArrayList(pistol_shot.Definition) = .empty;
    errdefer weapons.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var imported: std.AutoHashMap(u16, usize) = .init(allocator);
    defer imported.deinit();
    var weapon_ids: std.AutoHashMap(u16, usize) = .init(allocator);
    defer weapon_ids.deinit();
    var activation_signal: i16 = 0;
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 10 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(rule_bytes, record.rule_group);
        if (!recognize(group)) continue;
        const profile_id = imported.get(record.rule_group) orelse new: {
            var importer: Import = .{
                .allocator = allocator,
                .group = group,
                .animations = animations,
                .clips = &clips,
                .cached = .init(allocator),
            };
            defer importer.deinit();
            const profile = try importer.profile(resolver);
            errdefer allocator.free(profile.hits);
            const id = profiles.items.len;
            try imported.put(record.rule_group, id);
            try profiles.append(allocator, profile);
            break :new id;
        };
        const dormant = record.initial_state == group.at(201).source;
        if (!dormant and
            record.initial_state != group.at(0).source) return error.UnsupportedGuardStart;
        const signal = group.at(201).conditions[0].argument;
        if (activation_signal != 0 and
            activation_signal != signal) return error.UnsupportedMixedGuardSignals;
        activation_signal = signal;
        const endpoint = record.parameters[1];
        if (endpoint < 0 or endpoint >= table.count) return error.InvalidGuardWeapon;
        const weapon = weapon_ids.get(@intCast(endpoint)) orelse new: {
            const result = try weapon_effects.load(
                allocator,
                try table.record(@intCast(endpoint)),
                rule_bytes,
                animations,
                &clips,
                resolver,
            );
            const id = weapons.items.len;
            try weapon_ids.put(@intCast(endpoint), id);
            try weapons.append(allocator, result);
            break :new id;
        };
        const recipient = record.parameters[3];
        if (recipient < 0 or recipient >= table.count) return error.InvalidGuardDefeatLink;
        const output = try routes_mod.internConnection(
            allocator,
            routes,
            @intCast(index),
            @intCast(recipient),
            group.at(192).effect.argument,
        );
        const arrival = record.parameters[2];
        if (dormant and (arrival < 0 or arrival >= rooms.len)) return error.InvalidGuardArrival;
        table.register(@intCast(index), .mobile_guards);
        table.register(@intCast(endpoint), .weapon_effects);
        try definitions.append(
            allocator,
            .{
                .profile = profile_id,
                .room = if (record.room < rooms.len) rooms[record.room] else null,
                .arrival_room = if (dormant) rooms[@intCast(arrival)] else null,
                .position = record.position,
                .facing = if (record.facing_right == 0) .left else .right,
                .dormant = dormant,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
                .contact_width = record.collision_width,
                .health = record.life,
                .posture_range = record.parameters[0],
                .weapon = weapon,
                .shot_next_step = index >= endpoint,
                .defeat_output = output,
                .palette_bank = 5,
                .behind_player = record.visual_flags & 8 != 0,
            },
        );
        try sources.append(allocator, @intCast(index));
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer {
        for (owned_profiles) |profile| allocator.free(profile.hits);
        allocator.free(owned_profiles);
    }
    const owned_weapons = try weapons.toOwnedSlice(allocator);
    errdefer allocator.free(owned_weapons);
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    return .{
        .allocator = allocator,
        .definitions = owned,
        .profiles = owned_profiles,
        .weapons = owned_weapons,
        .clips = owned_clips,
        .sources = try sources.toOwnedSlice(allocator),
        .activation_signal = activation_signal,
    };
}
