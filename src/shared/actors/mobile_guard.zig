//! Armed guards combine ground pursuit, powered flight and clearance-aware hit recovery.
//! Definitions supply artwork and encounter links; no room or source actor is singled out.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const contacts = @import("../contacts.zig");
const combat = @import("../combat.zig");
const perception = @import("perception.zig");
const flight = @import("guard_flight.zig");
const wound = @import("guard_wound.zig");
const Environment = @import("conrad_environment.zig").Environment;
const shift = @import("conrad_roll.zig").shiftForward;
const Circuit = @import("../world_props.zig").CircuitId;
pub const Posture = enum { standing, crouched, airborne };
pub const Firing = struct { posture: Posture, phase: enum { windup, discharge, recovery } = .windup };
pub const Activity = union(enum) { standing, walking: u1, turning, checking_takeoff, crouching, crouched, rising, firing: Firing, flying: flight.State, wounded: wound.State, dormant, defeated, removed };
pub const HitResponse = struct { direction: wound.Direction, forward: i16 = 0, down: i16 = 0, turn: bool = false, health_delta: i8 = 0 };
pub const HitPolicy = struct {
    priority: [4]combat.Impact = .{ .rear_high, .rear_low, .front_high, .front_low },
    responses: [4]?HitResponse = @splat(null),
    pub fn vulnerability(self: HitPolicy) combat.Vulnerability {
        var result: combat.Vulnerability = .{};
        for (std.enums.values(combat.Impact), self.responses) |impact, response| if (response != null) {
            result.set(impact);
        };
        return result;
    }
};
pub const WeaponMotion = struct { windup: motion.Clip, discharge: motion.Clip, recovery: motion.Clip };
pub const Profile = struct {
    standing: motion.Clip,
    walks: [2]motion.Clip,
    turning: motion.Clip,
    checking_takeoff: motion.Clip,
    crouching: motion.Clip,
    crouched: motion.Clip,
    rising: motion.Clip,
    dormant: motion.Clip,
    defeated: motion.Clip,
    firing: [3]WeaponMotion,
    flight: flight.Profile,
    wound: wound.Profile,
    hits: []const HitPolicy,
    crouch_senses: [2]?perception.PostureSense,
    shoot_distance: i16,
    ally_wait_distance: i16,
    ally_scan_cells: u8,
    takeoff_ledges: [3]i16,
    flight_fire_exit_chance: i16,
    recoil_compensation: i16,
    pub fn clip(self: Profile, activity: Activity) motion.Clip {
        return switch (activity) {
            .standing => self.standing,
            .walking => |stride| self.walks[stride],
            .turning => self.turning,
            .checking_takeoff => self.checking_takeoff,
            .crouching => self.crouching,
            .crouched => self.crouched,
            .rising => self.rising,
            .dormant => self.dormant,
            .defeated, .removed => self.defeated,
            .firing => |state| switch (state.phase) {
                .windup => self.firing[@backingInt(state.posture)].windup,
                .discharge => self.firing[@backingInt(state.posture)].discharge,
                .recovery => self.firing[@backingInt(state.posture)].recovery,
            },
            .flying => |state| state.clip(self.flight),
            .wounded => |state| state.clip(self.wound),
        };
    }
};
pub const Definition = struct {
    profile: usize,
    room: ?geometry.RoomId,
    arrival_room: ?geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    dormant: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    contact_width: u8,
    health: i16,
    posture_range: i16,
    weapon: usize,
    shot_next_step: bool,
    defeat_output: Circuit,
    palette_bank: u4,
    behind_player: bool,
};
pub const Binding = struct { circuit: Circuit, actor: usize, next_step: bool };
pub const Actor = struct {
    pose: motion.Pose,
    room: ?geometry.RoomId,
    contact: ?contacts.Footprint = null,
    activity: Activity = .standing,
    playback: motion.Playback = .{},
    active: bool,
    health: i16,
    pending_hits: combat.ImpactSet = .{},
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
    shot: ?Posture = null,

    pub fn vulnerability(self: Actor, profile: Profile) combat.Vulnerability {
        const id = profile.clip(self.activity).hit_profile orelse return .{};
        return profile.hits[@backingInt(id)].vulnerability();
    }
    fn turn(self: *Actor) void {
        self.pose.facing = if (self.pose.facing == .left) .right else .left;
    }
    fn chooseGround(self: *Actor, profile: Profile, environment: Environment, awareness: perception.Awareness, player: contacts.Footprint, above: bool, below: bool, duck: bool, ally_ahead: bool) !void {
        const layout: contacts.Layout = .{};
        const contact = if (self.contact) |body| try layout.overlaps(environment.map, body, player) else false;
        if (contact and !try environment.at(self.pose, .torso, 0) and try environment.at(self.pose, .support, 1)) {
            self.activity = .{ .walking = 0 };
            return;
        }
        if (duck) {
            self.activity = .crouching;
            return;
        }
        if (awareness.player(false, profile.ally_wait_distance) and ally_ahead) return;
        if (environment.room == player.room and awareness.player(false, profile.shoot_distance)) {
            self.activity = .{ .firing = .{ .posture = .standing } };
            return;
        }
        const front = awareness.player(false, 0);
        if (front and try environment.ledge(self.pose, .support, 0, .ahead)) {
            self.activity = .checking_takeoff;
            return;
        }
        if (front and !try environment.at(self.pose, .torso, 1)) {
            self.activity = .{ .walking = 0 };
            return;
        }
        if (above and (try environment.ledge(self.pose, .head, 0, .ahead) or try environment.ledge(self.pose, .head, 1, .behind))) {
            self.activity = .{ .flying = .{ .kind = .ascend } };
            return;
        }
        if (below and try environment.ledge(self.pose, .support, 0, .ahead)) {
            self.activity = .{ .flying = .{ .kind = .descend } };
            return;
        }
        if (!try environment.at(self.pose, .support, 0)) {
            self.activity = .{ .flying = .{ .kind = .descend, .phase = .aligning } };
            return;
        }
        if ((above and try environment.ledge(self.pose, .head, 0, .behind)) or (below and try environment.ledge(self.pose, .support, 0, .behind)) or ((above or below) and try environment.at(self.pose, .torso, 1)) or awareness.player(true, 0)) {
            self.activity = .turning;
            return;
        }
        if (front and try environment.at(self.pose, .torso, 1)) return;
        if ((above or below) and try environment.at(self.pose, .support, 1)) {
            self.activity = .{ .walking = 0 };
            return;
        }
        if (above) self.activity = .turning;
    }
    fn finishFiring(self: *Actor, state: Firing, profile: Profile, environment: Environment, awareness: perception.Awareness, random: anytype) !void {
        switch (state.posture) {
            .standing => switch (state.phase) {
                .windup => {
                    if (!try environment.at(self.pose, .support, 0)) self.activity = .{ .flying = .{ .kind = .descend, .phase = .aligning } } else if (!try environment.at(self.pose, .torso, 1)) {
                        self.shot = .standing;
                        self.activity = .{ .firing = .{ .posture = .standing, .phase = .discharge } };
                    } else self.activity = .{ .firing = .{ .posture = .standing, .phase = .recovery } };
                },
                .discharge => {
                    const unsupported = !try environment.at(self.pose, .support, 0);
                    shift(&self.pose, profile.recoil_compensation);
                    self.activity = if (unsupported) .{ .flying = .{ .kind = .descend, .phase = .aligning } } else .{ .firing = .{ .posture = .standing, .phase = .recovery } };
                },
                .recovery => self.activity = .standing,
            },
            .crouched => {
                if (state.phase == .windup and !try environment.at(self.pose, .torso, 1)) {
                    self.shot = .crouched;
                    self.activity = .{ .firing = .{ .posture = .crouched, .phase = .discharge } };
                } else self.activity = .crouched;
            },
            .airborne => switch (state.phase) {
                .windup => {
                    const leave = profile.flight_fire_exit_chance != 0 and @rem(@as(i16, @bitCast(random.next())), profile.flight_fire_exit_chance) == 0;
                    if (!leave and !try environment.at(self.pose, .torso, 1) and awareness.player(false, 0)) {
                        self.shot = .airborne;
                        self.activity = .{ .firing = .{ .posture = .airborne, .phase = .discharge } };
                    } else self.activity = .{ .firing = .{ .posture = .airborne, .phase = .recovery } };
                },
                .discharge => self.activity = .{ .firing = .{ .posture = .airborne, .phase = .recovery } },
                .recovery => {
                    if (try environment.at(self.pose, .support, 1)) {
                        shift(&self.pose, profile.flight.landing_advance);
                        self.activity = .{ .flying = .{ .phase = .landing } };
                    } else self.activity = .{ .flying = .{ .phase = .drifting_to_ledge } };
                },
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
            const activity: Activity = if (definition.dormant) .dormant else .standing;
            const clip = profiles[definition.profile].clip(activity);
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingGuardVisual,
            };
            actor.* = .{ .room = definition.room, .pose = .{ .position = definition.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } }, .activity = activity, .active = definition.initially_active, .health = definition.health };
        }
        return .{ .allocator = allocator, .actors = actors, .pulses = try allocator.alloc(Circuit, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player_room: geometry.RoomId) !void {
        self.pulse_count = 0;
        self.score_requested = 0;
        for (self.actors, definitions) |*actor, definition| {
            if (actor.activity != .removed and definition.wake_nearby) if (actor.room) |room| {
                if ((try @import("../activation.zig").around(map, player_room, room, actor.pose.position.y)).wake) actor.active = true;
            };
            actor.ready = actor.pending;
            actor.pending = false;
            actor.shot = null;
            actor.sound = null;
            actor.contact = if (actor.room) |room| .{ .room = room, .position = actor.pose.position, .width = definition.contact_width } else null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (pulse != binding.circuit) continue;
            if (binding.next_step) self.actors[binding.actor].pending = true else self.actors[binding.actor].ready = true;
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: contacts.Footprint, player_down: bool, targets: []combat.Target, first_target: usize, visibility: *@import("../visibility.zig").World, visibility_entities: []const @import("../visibility.zig").Entity, random: anytype) !void {
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            if (actor.activity == .removed) continue;
            if (actor.ready and definition.accepts_signals) actor.active = true;
            if (actor.room) |room| {
                const neighborhood = try @import("../activation.zig").around(map, player.room, room, actor.pose.position.y);
                if (definition.wake_nearby and neighborhood.wake) actor.active = true;
            }
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clip(actor.activity);
            const hits = actor.pending_hits;
            actor.pending_hits = .{};
            if (clip.hit_profile) |policy_id| {
                const policy = profile.hits[@backingInt(policy_id)];
                for (policy.priority) |impact| {
                    if (!hits.accepts(impact)) continue;
                    const response = policy.responses[@backingInt(impact)] orelse continue;
                    actor.playback.completeDisplacement(clip, &actor.pose);
                    if (response.turn) actor.turn();
                    shift(&actor.pose, response.forward);
                    actor.pose.position.y +%= response.down;
                    actor.health +%= response.health_delta;
                    actor.activity = .{ .wounded = .{ .direction = response.direction } };
                    actor.playback = .{};
                    clip = profile.clip(actor.activity);
                    break;
                }
            }
            if (actor.activity == .dormant and actor.ready) actor.playback.completeDisplacement(clip, &actor.pose);
            if (actor.playback.exhausted(clip)) {
                if (actor.activity == .dormant) {
                    if (actor.ready) {
                        actor.room = definition.arrival_room orelse return error.MissingGuardArrival;
                        actor.activity = .standing;
                    } else actor.active = false;
                } else if (actor.room) |room| {
                    const environment: Environment = .{ .map = map, .room = room };
                    const observer: perception.Observer = .{ .room = room, .pose = actor.pose };
                    const awareness = try perception.observe(map, observer, player, &.{});
                    const origin = try map.room(room);
                    const same = room == player.room;
                    const above = if (same) @divTrunc(player.position.y -% 8, 72) < @divTrunc(actor.pose.position.y, 72) else origin.edges.up == .room and origin.edges.up.room == player.room;
                    const below = if (same) @divTrunc(player.position.y -% 8, 72) > @divTrunc(actor.pose.position.y, 72) else origin.edges.down == .room and origin.edges.down.room == player.room;
                    switch (actor.activity) {
                        .standing => {
                            const id: combat.Id = @fromBackingInt(@as(u16, @intCast(first_target + index)));
                            const duck = try perception.unhittableTarget(map, observer, id, definition.posture_range, targets, &profile.crouch_senses);
                            const ally = awareness.player(false, profile.ally_wait_distance) and (try visibility.scan(map, player.room, visibility_entities[index], actor.pose, room, .enemy, profile.ally_scan_cells, false)) != null;
                            try actor.chooseGround(profile, environment, awareness, player, above, below, duck, ally);
                            if (actor.activity == .standing and !same) {
                                const neighborhood = try @import("../activation.zig").around(map, player.room, room, actor.pose.position.y);
                                if (!(definition.wake_nearby and neighborhood.near)) actor.active = false;
                            }
                        },
                        .walking => |stride| {
                            const stop = (same and awareness.player(false, profile.shoot_distance)) or try environment.at(actor.pose, .torso, 1) or try environment.ledge(actor.pose, .support, 0, .ahead) or (above and (try environment.ledge(actor.pose, .head, 0, .ahead) or try environment.ledge(actor.pose, .head, 0, .behind)));
                            actor.activity = if (stop) .standing else if (below or awareness.player(false, 0) or (stride == 1 and above)) .{ .walking = stride ^ 1 } else .standing;
                        },
                        .turning => {
                            actor.turn();
                            actor.activity = .standing;
                        },
                        .checking_takeoff => {
                            actor.activity = .standing;
                            for (profile.takeoff_ledges) |distance| if (try environment.ledge(actor.pose, .support, distance, .behind)) {
                                actor.activity = .{ .flying = .{} };
                                break;
                            };
                        },
                        .crouching => actor.activity = .crouched,
                        .crouched => if (same and awareness.player(false, profile.shoot_distance)) {
                            actor.activity = .{ .firing = .{ .posture = .crouched } };
                        } else if (!(same and player_down)) {
                            actor.activity = .rising;
                        },
                        .rising => actor.activity = .standing,
                        .firing => |state| try actor.finishFiring(state, profile, environment, awareness, random),
                        .flying => |*state| {
                            const outcome = try state.finish(profile.flight, &actor.pose, environment, awareness.player(true, 0), awareness.player(true, 16));
                            switch (outcome) {
                                .continued => {},
                                .grounded => actor.activity = .standing,
                                .fire => actor.activity = .{ .firing = .{ .posture = .airborne } },
                            }
                        },
                        .wounded => |*state| {
                            const outcome = try state.finish(profile.wound, actor.health, &actor.pose, environment);
                            if (outcome.damage) actor.health -%= 1;
                            self.score_requested +%= outcome.score;
                            switch (outcome.next) {
                                .continued => {},
                                .turn_in_flight => actor.activity = .{ .flying = .{ .phase = .turning } },
                                .fire_in_flight => actor.activity = .{ .firing = .{ .posture = .airborne } },
                                .defeated => {
                                    actor.activity = .defeated;
                                    self.pulses[self.pulse_count] = definition.defeat_output;
                                    self.pulse_count += 1;
                                },
                            }
                        },
                        .defeated => {
                            actor.activity = .removed;
                            actor.active = false;
                            actor.room = null;
                        },
                        .dormant, .removed => unreachable,
                    }
                }
                actor.playback = .{};
                clip = profile.clip(actor.activity);
                if (actor.room) |*room| _ = map.handoff(room, &actor.pose.position) catch |err| switch (err) {
                    error.ExitWithoutDestination => {
                        actor.activity = .removed;
                        actor.active = false;
                        actor.room = null;
                    },
                    else => return err,
                };
            }
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
            actor.ready = false;
            visibility.setActive(visibility_entities[index], actor.active and actor.activity != .removed);
            const target = &targets[first_target + index];
            target.facing = actor.pose.facing;
            target.vulnerable = actor.vulnerability(profile);
            target.active = actor.active and actor.room != null and actor.activity != .removed;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| {
            for ([_]u32{ if (actor.room) |room| @backingInt(room) else 0, @as(u16, @bitCast(actor.pose.position.x)), @as(u16, @bitCast(actor.pose.position.y)), @backingInt(actor.pose.facing), @backingInt(actor.pose.visual.id), @intFromBool(actor.pose.visual.mirrored), @as(u16, @bitCast(actor.health)), @intCast(actor.playback.next_step) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
            hash.update(&.{ @intFromBool(actor.active), @intFromBool(actor.ready), @intFromBool(actor.pending) });
            hash.update(@tagName(actor.activity));
            switch (actor.activity) {
                .walking => |stride| hash.update(&.{stride}),
                .firing => |state| hash.update(&.{ @backingInt(state.posture), @backingInt(state.phase) }),
                .flying => |state| hash.update(&.{ @backingInt(state.kind), @backingInt(state.phase) }),
                .wounded => |state| hash.update(&.{ @backingInt(state.direction), @backingInt(state.phase), state.clearance, @intFromBool(state.dropped) }),
                else => {},
            }
            for (std.enums.values(combat.Impact)) |impact| hash.update(&.{@intFromBool(actor.pending_hits.accepts(impact))});
        }
    }
};
