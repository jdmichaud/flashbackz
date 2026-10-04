//! Recover gunman motion graphs and perception profiles at import. Placement IDs and
//! instruction numbers never enter the behavior system. One profile serves all placements
//! that reference the same rule family, including its difficulty and stone-response variant.
const std = @import("std");
const actor = @import("../actors/gunman.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const Action = actor.Action;
const Sources = [actor.action_count]u16;

pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []actor.Definition,
    profiles: []actor.Profile,
    weapons: []@import("../pistol_shot.zig").Definition,
    clips: []animation.OwnedClip,
    unclassified: usize,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        self.allocator.free(self.weapons);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};

fn find(group: rules.Group, state: u16, code: u8, ordinal: usize) ?rules.Rule {
    var seen: usize = 0;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != state) continue;
        const matches = if (code == 0) rule.conditions[0].code == 0 and rule.conditions[1].code == 0 else rule.conditions[0].code == code or rule.conditions[1].code == code;
        if (!matches) continue;
        if (seen == ordinal) return rule;
        seen += 1;
    }
    return null;
}
fn required(group: rules.Group, state: u16, code: u8, ordinal: usize) !rules.Rule {
    return find(group, state, code, ordinal) orelse error.UnsupportedGunmanBehavior;
}
fn argument(rule: rules.Rule, code: u8) i16 {
    return if (rule.conditions[0].code == code) rule.conditions[0].argument else rule.conditions[1].argument;
}
fn distance(group: rules.Group, state: u16, code: u8, ordinal: usize) !?i16 {
    const rule = find(group, state, code, ordinal) orelse return null;
    const cells = argument(rule, code);
    if (cells < 0 or cells > 64) return error.InvalidEnemySightRange;
    return cells * 16;
}
fn objectRange(group: rules.Group, state: u16, behind: bool) !?u8 {
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != state or rule.conditions[1].code != 64) continue;
        if (rule.conditions[0].code != 0 or rule.conditions[0].argument != 3) return error.UnsupportedEnemyDistraction;
        const value = rule.conditions[1].argument;
        if ((value < 0) != behind) continue;
        // Each scanned cell consumes two units of the original search budget.
        return @intCast(@min(@abs(value), 16) / 2 + 1);
    }
    return null;
}
fn interest(group: rules.Group, state: u16, behind: bool) !actor.Interest {
    return .{ .player = try distance(group, state, if (behind) 121 else 120, 0), .object = try objectRange(group, state, behind) };
}
fn put(sources: *Sources, action: Action, state: u16) void {
    sources[@backingInt(action)] = state;
}
fn get(sources: Sources, action: Action) u16 {
    return sources[@backingInt(action)];
}

fn discover(group: rules.Group) !?Sources {
    if (group.count() == 0) return null;
    // These predicates identify the recovered jungle variants. City gunmen add alarm
    // and neighboring-room senses; leave that profile unclassified until those are bound.
    for (0..group.count()) |i| for (group.at(i).conditions) |condition| switch (condition.code) {
        0, 14, 16, 18, 26, 27, 30, 32, 34, 63, 64, 68, 77, 97, 98, 99, 107, 120, 121 => {},
        else => return null,
    };
    const relaxed = group.at(0).source;
    const wake = find(group, relaxed, 120, 0) orelse return null;
    const shift = find(group, relaxed, 97, 0) orelse return null;
    const lean = find(group, relaxed, 97, 1) orelse return null;
    const sleep = find(group, relaxed, 77, 0) orelse return null;
    if (sleep.effect.code != 67 or sleep.target != relaxed) return null;
    var sources: Sources = undefined;
    put(&sources, .relaxed, relaxed);
    put(&sources, .raising_weapon, wake.target);
    put(&sources, .ready, (try required(group, wake.target, 0, 0)).target);
    const ready = get(sources, .ready);
    put(&sources, .lowering_weapon, (try required(group, ready, 97, 0)).target);
    if ((try required(group, get(sources, .lowering_weapon), 0, 0)).target != relaxed) return error.UnsupportedGunmanBehavior;
    put(&sources, .shifting_weight, shift.target);
    put(&sources, .leaning, lean.target);
    put(&sources, .weight_shifted, (try required(group, shift.target, 0, 0)).target);
    put(&sources, .leaned, (try required(group, lean.target, 0, 0)).target);
    put(&sources, .settling_weight, (try required(group, get(sources, .weight_shifted), 0, 0)).target);
    put(&sources, .straightening, (try required(group, get(sources, .leaned), 0, 0)).target);
    put(&sources, .blocked, (try required(group, ready, 26, 0)).target);
    put(&sources, .assessing, (try required(group, ready, 120, 0)).target);
    put(&sources, .turning, (try required(group, ready, 121, 0)).target);
    put(&sources, .walk_start, (try required(group, get(sources, .assessing), 0, 0)).target);
    put(&sources, .walk_finish, (try required(group, get(sources, .walk_start), 0, 0)).target);
    put(&sources, .raising_aim, (try required(group, get(sources, .assessing), 120, 0)).target);
    put(&sources, .aiming, (try required(group, get(sources, .raising_aim), 68, 0)).target);
    put(&sources, .firing_windup, (try required(group, get(sources, .aiming), 63, 0)).target);
    const fire = try required(group, get(sources, .firing_windup), 0, 0);
    if (fire.effect.code != 36 or fire.effect.argument != 40) return error.UnsupportedEnemyWeapon;
    put(&sources, .firing, fire.target);
    put(&sources, .lowering_aim, (try required(group, fire.target, 68, 0)).target);
    put(&sources, .recovering, (try required(group, get(sources, .lowering_aim), 0, 0)).target);
    put(&sources, .ducking, (try required(group, get(sources, .assessing), 98, 0)).target);
    put(&sources, .crouched_aim, (try required(group, get(sources, .ducking), 68, 0)).target);
    put(&sources, .rising, (try required(group, get(sources, .crouched_aim), 0, 0)).target);
    put(&sources, .crouched_windup, (try required(group, get(sources, .crouched_aim), 63, 0)).target);
    const low_fire = try required(group, get(sources, .crouched_windup), 0, 0);
    if (low_fire.effect.code != 36 or low_fire.effect.argument != 41) return error.UnsupportedEnemyWeapon;
    put(&sources, .crouched_fire, low_fire.target);
    put(&sources, .crouched_recovery, (try required(group, low_fire.target, 68, 0)).target);
    // Every imported action must be a distinct clip role in this family. The runtime
    // chooses intent; these source relationships are only used to identify its artwork.
    for (sources, 0..) |state, i| for (sources[0..i]) |previous| if (state == previous) return error.UnsupportedGunmanMotionGraph;
    return sources;
}

fn postureSenses(group: rules.Group, state: u16) ![4]?@import("../actors/perception.zig").PostureSense {
    var result: [4]?@import("../actors/perception.zig").PostureSense = @splat(null);
    var count: usize = 0;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != state or (rule.conditions[1].code != 98 and rule.conditions[1].code != 99)) continue;
        if (count == result.len or rule.conditions[0].code != 0 or rule.conditions[1].argument < 1 or rule.conditions[1].argument > 4) return error.UnsupportedEnemyPostureSense;
        result[count] = .{
            .category = switch (rule.conditions[0].argument) {
                1 => .player,
                10 => .enemy,
                else => return error.UnsupportedEnemyPostureCategory,
            },
            .same_facing = rule.conditions[1].code == 99,
            .impact = @fromBackingInt(@as(u2, @intCast(rule.conditions[1].argument - 1))),
        };
        count += 1;
    }
    return result;
}

fn profile(group: rules.Group, sources: Sources, clips: actor.Clips, hit_priority: [actor.action_count][4]@import("../combat.zig").Impact, reactions: [actor.action_count][4]?actor.Reaction, defeat: @import("../actors/gunman_defeat.zig").Definition) !actor.Profile {
    const ready = get(sources, .ready);
    const relaxed = get(sources, .relaxed);
    const aiming = get(sources, .aiming);
    var aim_immediate: ?i16 = null;
    var aim_hold: ?i16 = null;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != aiming or rule.conditions[1].code != 120) continue;
        if (rule.target == aiming) aim_hold = try distance(group, aiming, 120, if (aim_immediate == null) 0 else 1) else aim_immediate = try distance(group, aiming, 120, 0);
    }
    const recovery_target = (try required(group, get(sources, .crouched_recovery), 63, 0)).target;
    if (recovery_target != get(sources, .crouched_aim) and recovery_target != get(sources, .rising)) return error.UnsupportedEnemyRecovery;
    return .{
        .clips = clips,
        .crouch_senses = try postureSenses(group, get(sources, .assessing)),
        .stay_low_senses = try postureSenses(group, get(sources, .crouched_aim)),
        .reactions = reactions,
        .hit_priority = hit_priority,
        .defeat = defeat,
        .relaxed_front = try interest(group, relaxed, false),
        .relaxed_behind = try interest(group, relaxed, true),
        .fidget_front = try interest(group, get(sources, .leaned), false),
        .ready_front = try interest(group, ready, false),
        .ready_behind = try interest(group, ready, true),
        .stopping_front = try interest(group, get(sources, .walk_finish), false),
        .following_front = .{ .player = try distance(group, get(sources, .walk_finish), 120, 1), .object = following: {
            const state = get(sources, .walk_finish);
            const rule = find(group, state, 64, 1) orelse break :following null;
            break :following @intCast(@min(@abs(argument(rule, 64)), 16) / 2 + 1);
        } },
        .obstacle_object = try objectRange(group, get(sources, .blocked), false),
        .shoot_distance = (try distance(group, get(sources, .assessing), 120, 0)).?,
        .obstacle_shoot_distance = (try distance(group, get(sources, .blocked), 120, 0)).?,
        .obstacle_wait_distance = (try distance(group, get(sources, .blocked), 120, 1)).?,
        .immediate_fire_distance = aim_immediate,
        .aiming_distance = aim_hold orelse return error.MissingEnemyAimRange,
        .crouched_fire_distance = try distance(group, get(sources, .crouched_aim), 120, 0),
        .lean_chance = argument(try required(group, relaxed, 97, 1), 97),
        .shift_chance = argument(try required(group, relaxed, 97, 0), 97),
        .fidget_hold_chance = argument(try required(group, get(sources, .leaned), 97, 0), 97),
        .relax_chance = argument(try required(group, ready, 97, 0), 97),
        .shifted_forward = -@as(i16, (try required(group, get(sources, .shifting_weight), 0, 0)).dx),
        .settled_forward = -@as(i16, (try required(group, get(sources, .weight_shifted), 0, 0)).dx),
        .repeat_crouched_fire = recovery_target == get(sources, .crouched_aim),
    };
}

pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, room_ids: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, score_awards: [16]u16, resolver: anytype) !Assets {
    var definitions: std.ArrayList(actor.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var profiles: std.ArrayList(actor.Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var weapons: std.ArrayList(@import("../pistol_shot.zig").Definition) = .empty;
    errdefer weapons.deinit(allocator);
    var weapon_ids: [256]?usize = @splat(null);
    var imported: [256]?struct { index: usize, sources: Sources } = @splat(null);
    var unclassified: usize = 0;
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 10 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.rule_group >= imported.len) return error.InvalidEnemyRuleGroup;
        if (imported[record.rule_group] == null) {
            const group = try rules.group(rule_bytes, record.rule_group);
            const sources = try discover(group) orelse {
                unclassified += 1;
                continue;
            };
            var resolved: actor.Clips = undefined;
            for (sources, &resolved) |state, *destination| {
                var source = try animation.decode(allocator, animations, state);
                defer source.deinit();
                if (source.kind != .sprite) return error.UnsupportedGunmanArtwork;
                var clip = try source.resolve(allocator, resolver);
                errdefer clip.deinit();
                try clips.append(allocator, clip);
                destination.* = clip.clip();
            }
            var reactions: [actor.action_count][4]?actor.Reaction = @splat(@splat(null));
            var hit_priority: [actor.action_count][4]@import("../combat.zig").Impact = undefined;
            var impacts: [2]?u16 = @splat(null);
            for (sources, &reactions, &hit_priority) |state, *responses, *priority| {
                var first_rule: [4]usize = @splat(std.math.maxInt(usize));
                for (0..4) |slot| {
                    const message: i16 = @intCast(slot + 1);
                    for (0..group.count()) |j| {
                        const rule = group.at(j);
                        if (rule.source != state) continue;
                        const op = rule.conditions[0];
                        const accepts = (op.code == 34 and op.argument == message) or (op.code == 107 and (if (op.argument == 0) message <= 2 else message >= 3));
                        if (!accepts) continue;
                        if (rule.conditions[1].code != 0 or rule.effect.code != 0 or rule.flags & 12 != 0) return error.UnsupportedEnemyHit;
                        const side: usize = if (slot < 2) 0 else 1;
                        if (impacts[side] != null and impacts[side].? != rule.target) return error.UnsupportedEnemyHit;
                        impacts[side] = rule.target;
                        first_rule[slot] = j;
                        responses[slot] = .{ .forward = -@as(i16, rule.dx), .down = rule.dy, .turn = rule.flags & 1 != 0, .damage = @intFromBool(rule.flags & 2 != 0), .score = score_awards[rule.flags >> 4] + @as(u16, if (rule.flags & 2 != 0) 100 else 0) };
                        break;
                    }
                }
                priority.* = .{ .rear_high, .rear_low, .front_high, .front_low };
                for (1..4) |slot| {
                    var position = slot;
                    while (position > 0 and first_rule[@backingInt(priority[position])] < first_rule[@backingInt(priority[position - 1])]) : (position -= 1) std.mem.swap(@import("../combat.zig").Impact, &priority[position], &priority[position - 1]);
                }
            }
            const defeat_import = @import("gunman_defeat.zig");
            const defeat: @import("../actors/gunman_defeat.zig").Definition = .{
                .forward = try defeat_import.track(allocator, group, animations, impacts[0] orelse return error.MissingEnemyHit, false, &clips, resolver),
                .backward = try defeat_import.track(allocator, group, animations, impacts[1] orelse return error.MissingEnemyHit, true, &clips, resolver),
            };
            const recovered = try profile(group, sources, resolved, hit_priority, reactions, defeat);
            const index = profiles.items.len;
            try profiles.append(allocator, recovered);
            imported[record.rule_group] = .{ .index = index, .sources = sources };
        }
        const family = imported[record.rule_group].?;
        const initial: Action = if (record.initial_state == get(family.sources, .relaxed)) .relaxed else if (record.initial_state == get(family.sources, .ready)) .ready else return error.UnsupportedEnemyStart;
        if (record.room >= room_ids.len) return error.InvalidEnemyRoom;
        const group = try rules.group(rule_bytes, record.rule_group);
        const aim_param = argument(try required(group, get(family.sources, .raising_aim), 68, 0), 68);
        const recovery_param = argument(try required(group, get(family.sources, .firing), 68, 0), 68);
        if (aim_param < 0 or aim_param > 3 or recovery_param < 0 or recovery_param > 3) return error.InvalidEnemyTimer;
        if (record.parameters[0] < -64 or record.parameters[0] > 64) return error.InvalidEnemyPostureRange;
        const endpoint = record.parameters[1];
        if (endpoint < 0 or endpoint >= table.count) return error.InvalidEnemyWeaponBinding;
        const endpoint_index: usize = @intCast(endpoint);
        if (weapon_ids[endpoint_index] == null) {
            const weapon = try @import("gunman_weapon.zig").load(allocator, try table.record(@intCast(endpoint)), rule_bytes, animations, &clips, resolver);
            const id = weapons.items.len;
            try weapons.append(allocator, weapon);
            weapon_ids[endpoint_index] = id;
        }
        try definitions.append(allocator, .{ .weapon = weapon_ids[endpoint_index].?, .shot_next_step = i > endpoint_index, .profile = family.index, .room = room_ids[record.room], .position = record.position, .facing = if (record.facing_right == 0) .left else .right, .initial_action = initial, .contact_width = record.collision_width, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .behind_player = record.visual_flags & 8 != 0, .health = record.life, .aim_delay = record.parameters[@intCast(aim_param)], .posture_range = record.parameters[0], .recovery_delay = record.parameters[@intCast(recovery_param)] });
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_definitions);
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    const owned_weapons = try weapons.toOwnedSlice(allocator);
    errdefer allocator.free(owned_weapons);
    return .{ .allocator = allocator, .definitions = owned_definitions, .profiles = owned_profiles, .weapons = owned_weapons, .clips = try clips.toOwnedSlice(allocator), .unclassified = unclassified };
}
