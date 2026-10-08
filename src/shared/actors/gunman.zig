//! A gunman chooses actions from awareness, terrain and its own recovery timer. Animation
//! clips own poses and timing; shared immutable profiles distinguish encounter variants.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const perception = @import("perception.zig");
const combat = @import("../combat.zig");
const defeat_mod = @import("gunman_defeat.zig");
const Circuit = @import("../world_props.zig").CircuitId;
pub const Binding = struct { circuit: Circuit, actor: usize, next_step: bool };
const Environment = @import("conrad_environment.zig").Environment;

pub const Action = enum {
    relaxed,
    raising_weapon,
    lowering_weapon,
    leaning,
    leaned,
    straightening,
    shifting_weight,
    weight_shifted,
    settling_weight,
    ready,
    walk_start,
    walk_finish,
    turning,
    blocked,
    assessing,
    raising_aim,
    aiming,
    firing_windup,
    firing,
    lowering_aim,
    recovering,
    ducking,
    crouched_aim,
    crouched_windup,
    crouched_fire,
    crouched_recovery,
    rising,
};
pub const action_count = @typeInfo(Action).@"enum".field_names.len;
pub const Clips = [action_count]motion.Clip;
pub const Interest = struct { player: ?i16 = null, object: ?u8 = null };
pub const Reaction = struct { forward: i16, down: i16, turn: bool, damage: u1, score: u16 };
pub const Opportunism = struct {
    approach_chance: i16,
    close_distance: i16,
    aim_cover_chance: i16,
    fire_chance: i16,
    low_fire_chance: i16,
    low_rise_chance: i16,
    recovery_fire_chance: i16,
    recovery_cover_chance: i16,
    visible_player_cells: u8,
};
const Senses = struct { awareness: perception.Awareness, duck: bool, stay_low: bool, visible_player: bool, same_room: bool, above: bool, keep_awake: bool };
pub const Profile = struct {
    dormant_clip: ?motion.Clip = null,
    opportunism: ?Opportunism = null,
    reactions: [action_count][4]?Reaction,
    hit_priority: [action_count][4]combat.Impact,
    defeat: defeat_mod.Definition,
    clips: Clips,
    crouch_senses: [4]?perception.PostureSense,
    stay_low_senses: [4]?perception.PostureSense,
    relaxed_front: Interest,
    relaxed_behind: Interest,
    fidget_front: Interest,
    ready_front: Interest,
    ready_behind: Interest,
    stopping_front: Interest,
    following_front: Interest,
    obstacle_object: ?u8,
    shoot_distance: i16,
    obstacle_shoot_distance: i16,
    obstacle_wait_distance: i16,
    immediate_fire_distance: ?i16,
    crouched_fire_distance: ?i16,
    aiming_distance: i16,
    lean_chance: i16,
    shift_chance: i16,
    fidget_hold_chance: i16,
    relax_chance: i16,
    shifted_forward: i16,
    settled_forward: i16,
    repeat_crouched_fire: bool,

    pub fn clip(self: Profile, action: Action) motion.Clip {
        return self.clips[@backingInt(action)];
    }
};
pub const Definition = struct {
    dormant: bool = false,
    accepts_signals: bool = false,
    cover_output: ?Circuit = null,
    defeat_output: ?Circuit = null,
    crouched_recovery_delay: ?i16 = null,
    weapon: usize,
    shot_next_step: bool,
    profile: usize,
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    initial_action: Action,
    contact_width: u8,
    initially_active: bool,
    wake_nearby: bool,
    behind_player: bool,
    health: i16,
    aim_delay: i16,
    posture_range: i16,
    recovery_delay: i16,
};
pub const Actor = struct {
    dormant: bool = false,
    ready: bool = false,
    pending: bool = false,
    cover_requested: bool = false,
    body_width: u8 = 1,
    pose: motion.Pose,
    room: geometry.RoomId,
    action: Action,
    playback: motion.Playback = .{},
    active: bool,
    health: i16,
    timer: i16 = 0,
    sound: ?motion.SoundId = null,
    shot: ?combat.Height = null,
    defeat: ?defeat_mod.State = null,
    pending_hits: combat.ImpactSet = .{},
    contact: @import("../contacts.zig").Footprint,
    lost: bool = false,

    pub fn vulnerability(self: Actor, profile: Profile) combat.Vulnerability {
        var result: combat.Vulnerability = .{};
        if (self.defeat != null or self.lost or self.dormant) return result;
        for (std.enums.values(combat.Impact), profile.reactions[@backingInt(self.action)]) |impact, reaction| if (reaction != null) {
            result.set(impact);
        };
        return result;
    }
    fn clip(self: Actor, profile: Profile) motion.Clip {
        if (self.dormant) return profile.dormant_clip.?;
        return if (self.defeat) |state| state.clip(profile.defeat) else profile.clip(self.action);
    }

    fn interested(awareness: perception.Awareness, interest: Interest, behind: bool) bool {
        return awareness.player(behind, interest.player) or awareness.object(behind, interest.object);
    }
    fn chance(random: anytype, denominator: i16) bool {
        return denominator != 0 and @rem(@as(i16, @bitCast(random.next())), denominator) == 0;
    }
    fn countdown(self: *Actor) bool {
        self.timer -%= 1;
        return self.timer == 0;
    }
    fn moveAnchor(self: *Actor, forward: i16) void {
        self.pose.position.x +%= if (self.pose.facing == .right) forward else -%forward;
    }
    fn choose(self: *Actor, definition: Definition, profile: Profile, environment: Environment, senses: Senses, random: anytype) !Action {
        const awareness = senses.awareness;
        const duck = senses.duck;
        const stay_low = senses.stay_low;
        switch (self.action) {
            .relaxed => {
                if (interested(awareness, profile.relaxed_front, false) or interested(awareness, profile.relaxed_behind, true) or (profile.opportunism != null and senses.above)) return .raising_weapon;
                if (!senses.same_room) {
                    self.active = senses.keep_awake;
                    return .relaxed;
                }
                if (chance(random, profile.shift_chance)) return .shifting_weight;
                if (chance(random, profile.lean_chance)) return .leaning;
                return .relaxed;
            },
            .shifting_weight => {
                self.moveAnchor(profile.shifted_forward);
                return .weight_shifted;
            },
            .leaning => return .leaned,
            .weight_shifted, .leaned => {
                if (!interested(awareness, profile.fidget_front, false) and chance(random, profile.fidget_hold_chance)) return self.action;
                if (self.action == .weight_shifted) {
                    self.moveAnchor(profile.settled_forward);
                    return .settling_weight;
                }
                return .straightening;
            },
            .settling_weight, .straightening, .lowering_weapon => return .relaxed,
            .raising_weapon, .rising => return .ready,
            .ready => {
                if (!try environment.at(self.pose, .support, 2) or try environment.at(self.pose, .torso, 1)) return .blocked;
                if (interested(awareness, profile.ready_front, false)) return .assessing;
                if (interested(awareness, profile.ready_behind, true)) return .turning;
                if (!senses.same_room) {
                    self.active = senses.keep_awake;
                    return .ready;
                }
                if (profile.opportunism != null and senses.above) return .ready;
                return if (chance(random, profile.relax_chance)) .lowering_weapon else .ready;
            },
            .assessing => {
                if (profile.opportunism) |policy| {
                    if (duck) {
                        self.cover_requested = true;
                        return .ducking;
                    }
                    if (chance(random, policy.approach_chance) and awareness.player(false, profile.shoot_distance)) {
                        self.cover_requested = true;
                        return .raising_aim;
                    }
                    return if (senses.same_room and awareness.player(false, policy.close_distance)) .raising_aim else .walk_start;
                }
                return if (duck) .ducking else if (awareness.player(false, profile.shoot_distance)) .raising_aim else .walk_start;
            },
            .blocked => {
                if (profile.opportunism != null) {
                    if (awareness.player(false, profile.obstacle_shoot_distance)) return .raising_aim;
                    if (awareness.player(false, profile.obstacle_wait_distance)) return .blocked;
                    return if (duck) .ducking else .turning;
                }
                if (awareness.object(false, profile.obstacle_object)) return .blocked;
                if (duck) return .ducking;
                if (awareness.player(false, profile.obstacle_shoot_distance)) return .raising_aim;
                if (awareness.player(false, profile.obstacle_wait_distance)) return .blocked;
                return .turning;
            },
            .walk_start => return .walk_finish,
            .walk_finish => {
                if (!try environment.at(self.pose, .support, 2) or try environment.at(self.pose, .torso, 1)) return .ready;
                if (interested(awareness, profile.stopping_front, false)) return .ready;
                return if (interested(awareness, profile.following_front, false)) .walk_start else .ready;
            },
            .turning => {
                self.pose.facing = if (self.pose.facing == .left) .right else .left;
                return .ready;
            },
            .raising_aim => {
                self.timer = definition.aim_delay;
                if (profile.opportunism) |policy| if (chance(random, policy.aim_cover_chance)) {
                    self.cover_requested = true;
                };
                return .aiming;
            },
            .aiming => {
                if (profile.opportunism) |policy| {
                    if (chance(random, policy.fire_chance) or self.countdown()) return .firing_windup;
                    return if (senses.visible_player) .aiming else .lowering_aim;
                }
                if (awareness.player(false, profile.immediate_fire_distance) or self.countdown()) return .firing_windup;
                return if (awareness.player(false, profile.aiming_distance)) .aiming else .lowering_aim;
            },
            .firing_windup => {
                self.shot = .standing;
                return .firing;
            },
            .firing => {
                self.timer = definition.recovery_delay;
                return .lowering_aim;
            },
            .lowering_aim => return .recovering,
            .recovering => return if (self.countdown()) .ready else .recovering,
            .ducking => {
                self.timer = definition.aim_delay;
                return .crouched_aim;
            },
            .crouched_aim => {
                if (profile.opportunism) |policy| {
                    if (chance(random, policy.low_fire_chance) or self.countdown()) return .crouched_windup;
                    if (chance(random, policy.low_rise_chance)) return .rising;
                    return if (awareness.player(false, profile.aiming_distance)) .crouched_aim else .rising;
                }
                if (awareness.player(false, profile.crouched_fire_distance) or self.countdown()) return .crouched_windup;
                return if (stay_low) .crouched_aim else .rising;
            },
            .crouched_windup => {
                self.shot = .crouched;
                return .crouched_fire;
            },
            .crouched_fire => {
                self.timer = definition.crouched_recovery_delay orelse definition.recovery_delay;
                return .crouched_recovery;
            },
            .crouched_recovery => {
                if (profile.opportunism) |policy| {
                    if (self.countdown() or chance(random, policy.recovery_fire_chance)) {
                        self.timer = definition.aim_delay;
                        return .crouched_aim;
                    }
                    if (awareness.player(false, profile.aiming_distance) and chance(random, policy.recovery_cover_chance)) self.cover_requested = true;
                    return .crouched_recovery;
                }
                return if (self.countdown()) (if (profile.repeat_crouched_fire) .crouched_aim else .rising) else .crouched_recovery;
            },
        }
    }
};

pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    pulses: []Circuit,
    pulse_count: usize = 0,
    score_requested: u32 = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, profiles: []const Profile) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const clip = if (definition.dormant) profiles[definition.profile].dormant_clip.? else profiles[definition.profile].clip(definition.initial_action);
            const first = switch (clip.steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingEnemyVisual,
            };
            actor.* = .{ .dormant = definition.dormant, .body_width = definition.contact_width, .contact = .{ .room = definition.room, .position = definition.position, .width = if (definition.dormant) 0 else definition.contact_width }, .room = definition.room, .pose = .{ .position = definition.position, .facing = definition.facing, .visual = .{ .id = first.id, .mirrored = first.mirrored != (definition.facing == .left) } }, .action = definition.initial_action, .active = definition.initially_active, .health = definition.health };
        }
        return .{ .allocator = allocator, .actors = actors, .pulses = try allocator.alloc(Circuit, definitions.len * 2) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.pulses);
    }

    pub fn prepare(self: *World) void {
        self.score_requested = 0;
        self.pulse_count = 0;
        for (self.actors) |*actor| {
            actor.ready = actor.pending;
            actor.pending = false;
            actor.contact = .{ .room = actor.room, .position = actor.pose.position, .width = if (actor.dormant or actor.lost) 0 else actor.body_width };
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.actors[binding.actor].pending = true else self.actors[binding.actor].ready = true;
        };
    }
    fn emit(self: *World, circuit: ?Circuit) void {
        if (circuit) |value| {
            self.pulses[self.pulse_count] = value;
            self.pulse_count += 1;
        }
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: @import("../contacts.zig").Footprint, distractions: []const @import("../contacts.zig").Footprint, targets: []combat.Target, visibility: *@import("../visibility.zig").World, visibility_entities: []const @import("../visibility.zig").Entity, random: anytype) !void {
        self.score_requested = 0;
        return self.advanceRange(definitions, profiles, map, player, distractions, targets, visibility, visibility_entities, random, 0, self.actors.len);
    }
    pub fn advanceOne(self: *World, index: usize, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: @import("../contacts.zig").Footprint, distractions: []const @import("../contacts.zig").Footprint, targets: []combat.Target, visibility: *@import("../visibility.zig").World, visibility_entities: []const @import("../visibility.zig").Entity, random: anytype) !void {
        return self.advanceRange(definitions, profiles, map, player, distractions, targets, visibility, visibility_entities, random, index, index + 1);
    }
    fn advanceRange(self: *World, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: @import("../contacts.zig").Footprint, distractions: []const @import("../contacts.zig").Footprint, targets: []combat.Target, visibility: *@import("../visibility.zig").World, visibility_entities: []const @import("../visibility.zig").Entity, random: anytype, range_start: usize, range_end: usize) !void {
        const current = try map.room(player.room);
        for (range_start..range_end) |index| {
            const actor = &self.actors[index];
            const definition = definitions[index];
            // Later characters in this update observe the activity left by this one.
            defer visibility.setActive(visibility_entities[index], actor.active and !actor.lost and !actor.dormant);
            actor.sound = null;
            actor.shot = null;
            actor.cover_requested = false;
            if (actor.ready and definition.accepts_signals) actor.active = true;
            if (actor.dormant and actor.ready and definition.accepts_signals) {
                actor.dormant = false;
                actor.active = true;
                actor.playback = .{};
            }
            actor.ready = false;
            if (actor.lost or actor.dormant) continue;
            const same_room = actor.room == player.room;
            var adjacent = same_room;
            for ([_]geometry.Edge{ current.edges.left, current.edges.right, current.edges.up, current.edges.down }) |edge| if (edge == .room and edge.room == actor.room) {
                adjacent = true;
            };
            if (definition.wake_nearby and actor.defeat == null) {
                const above = current.edges.up == .room and current.edges.up.room == actor.room and actor.pose.position.y >= 48;
                const below = current.edges.down == .room and current.edges.down.room == actor.room and actor.pose.position.y >= 176;
                if (same_room or above or below) actor.active = true;
            }
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            const hits = actor.pending_hits;
            actor.pending_hits = .{};
            if (actor.defeat == null) for (profile.hit_priority[@backingInt(actor.action)]) |hit| {
                if (!hits.accepts(hit)) continue;
                const reaction = profile.reactions[@backingInt(actor.action)][@backingInt(hit)] orelse continue;
                actor.playback.completeDisplacement(actor.clip(profile), &actor.pose);
                if (reaction.turn) actor.pose.facing = if (actor.pose.facing == .right) .left else .right;
                actor.moveAnchor(reaction.forward);
                actor.pose.position.y +%= reaction.down;
                actor.health -%= reaction.damage;
                actor.defeat = .{ .direction = if (hit == .front_high or hit == .front_low) .backward else .forward };
                actor.playback = .{};
                actor.sound = actor.clip(profile).sound;
                self.score_requested +%= reaction.score;
                _ = try map.handoff(&actor.room, &actor.pose.position);
                break;
            };
            var clip = actor.clip(profile);
            if (actor.playback.exhausted(clip)) {
                if (actor.defeat) |*state| {
                    if (state.phase == .resting) {
                        if (state.track(profile.defeat).mark_dead) actor.health = -1;
                        const track = state.track(profile.defeat);
                        if (track.notify_while_resting) self.emit(definition.defeat_output);
                        if (track.remove_offscreen and !same_room) {
                            actor.lost = true;
                            actor.active = false;
                        } else actor.active = track.notify_while_resting;
                    } else {
                        const track = state.track(profile.defeat);
                        if ((state.phase == .landing and track.notify_on_landing) or (state.phase == .fall_landing and track.notify_on_fall_landing)) self.emit(definition.defeat_output);
                        try state.advance(profile.defeat, &actor.pose, .{ .map = map, .room = actor.room });
                    }
                } else if ((actor.action == .ready or actor.action == .relaxed) and !same_room and profile.opportunism == null) {
                    if (!definition.wake_nearby or !adjacent) actor.active = false;
                } else {
                    const awareness = try perception.observe(map, .{ .room = actor.room, .pose = actor.pose }, player, distractions);
                    const observer: perception.Observer = .{ .room = actor.room, .pose = actor.pose };
                    const id: combat.Id = @fromBackingInt(@as(u16, @intCast(index + 1)));
                    const duck = (actor.action == .assessing or actor.action == .blocked) and try perception.unhittableTarget(map, observer, id, definition.posture_range, targets, &profile.crouch_senses);
                    const stay_low = actor.action == .crouched_aim and try perception.unhittableTarget(map, observer, id, definition.posture_range, targets, &profile.stay_low_senses);
                    const origin = try map.room(actor.room);
                    const above = if (same_room) @divTrunc(player.position.y -% 8, 72) < @divTrunc(actor.pose.position.y, 72) else origin.edges.up == .room and origin.edges.up.room == player.room;
                    const visible = if (profile.opportunism) |policy| (try visibility.scan(map, player.room, visibility_entities[index], actor.pose, actor.room, .player, policy.visible_player_cells, false)) != null else false;
                    actor.action = try actor.choose(definition, profile, .{ .map = map, .room = actor.room }, .{ .awareness = awareness, .duck = duck, .stay_low = stay_low, .visible_player = visible, .same_room = same_room, .above = above, .keep_awake = definition.wake_nearby and adjacent }, random);
                }
                actor.playback = .{};
                _ = map.handoff(&actor.room, &actor.pose.position) catch |err| switch (err) {
                    error.ExitWithoutDestination => {
                        actor.lost = true;
                        actor.active = false;
                        continue;
                    },
                    else => return err,
                };
                clip = actor.clip(profile);
                actor.sound = clip.sound;
            }
            if (actor.cover_requested) self.emit(definition.cover_output);
            _ = actor.playback.advance(clip, &actor.pose);
            targets[index + 1].facing = actor.pose.facing;
            targets[index + 1].vulnerable = actor.vulnerability(profile);
            targets[index + 1].active = actor.active and !actor.lost;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| {
            for ([_]i16{ actor.pose.position.x, actor.pose.position.y, actor.health, actor.timer }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, value)));
            for ([_]u64{ @backingInt(actor.room), @backingInt(actor.action), actor.playback.next_step, @backingInt(actor.pose.visual.id) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            const hits = actor.pending_hits;
            hash.update(&.{ @intFromBool(hits.rear_high), @intFromBool(hits.rear_low), @intFromBool(hits.front_high), @intFromBool(hits.front_low), @intFromBool(actor.defeat != null), @intFromBool(actor.lost), @intFromBool(actor.dormant), @intFromBool(actor.ready), @intFromBool(actor.pending) });
            if (actor.defeat) |state| hash.update(&.{ @backingInt(state.direction), @backingInt(state.phase), state.clearance });
            hash.update(&.{ @backingInt(actor.pose.facing), @intFromBool(actor.pose.visual.mirrored), @intFromBool(actor.active) });
        }
    }
};
