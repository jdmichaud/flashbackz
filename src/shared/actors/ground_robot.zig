//! Deployable ground robots. Closed locomotion, deployed pursuit, low strikes and an
//! overload sequence share ordinary motion, perception, terrain and combat components.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const contacts = @import("../contacts.zig");
const combat = @import("../combat.zig");
const perception = @import("perception.zig");
const Environment = @import("conrad_environment.zig").Environment;
const shift = @import("conrad_roll.zig").shiftForward;
pub const Phase = enum {
    closed_idle,
    closed_walk,
    closed_turn,
    deploying,
    open_idle_a,
    open_idle_b,
    open_walk_a,
    open_walk_b,
    open_turn,
    retracting,
    collapsing_front,
    collapsing_rear,
    overloading,
    exploding,
};
pub const phase_count = @typeInfo(Phase).@"enum".field_names.len;
pub const Profile = struct {
    clips: [phase_count]motion.Clip,
    deployment_distance: i16,
    strike_distance: i16,
    obstacle_distance: i16,
    pursuit_distance: [2]i16,
    walking_pursuit_distance: i16,
    explosion_distance: i16,
    closed_step: i16,
    open_step: i16,
    wall_ahead: i16,
    floor_ahead: i16,
    pub fn clip(self: Profile, phase: Phase) motion.Clip {
        return self.clips[@backingInt(phase)];
    }
};
pub const Definition = struct {
    profile: usize,
    footprint: contacts.Footprint,
    facing: motion.Facing,
    initially_active: bool,
    wake_nearby: bool,
    palette_bank: u4,
    behind_player: bool,
    strike_cells: u16,
};
pub const Actor = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    contact: contacts.Footprint,
    phase: Phase = .closed_idle,
    playback: motion.Playback = .{},
    active: bool,
    removed: bool = false,
    pending_hits: combat.ImpactSet = .{},
    sound: ?motion.SoundId = null,

    pub fn vulnerability(self: Actor) combat.Vulnerability {
        return switch (self.phase) {
            .open_idle_a, .open_idle_b, .open_walk_a, .open_walk_b, .open_turn => .{
                .rear_low = true,
                .front_low = true,
            },
            else => .{},
        };
    }
    fn reverse(self: *Actor) void {
        self.pose.facing = if (self.pose.facing == .left) .right else .left;
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    outgoing: []combat.Hit,
    outgoing_count: usize = 0,
    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const Definition,
        profiles: []const Profile,
    ) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const visual = switch (profiles[definition.profile].clip(.closed_idle).steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingRobotVisual,
            };
            actor.* = .{
                .room = definition.footprint.room,
                .contact = definition.footprint,
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .active = definition.initially_active,
            };
        }
        return .{
            .allocator = allocator,
            .actors = actors,
            .outgoing = try allocator.alloc(combat.Hit, definitions.len),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.outgoing);
    }
    pub fn prepare(self: *World) void {
        for (self.actors) |*actor| {
            actor.contact.room = actor.room;
            actor.contact.position = actor.pose.position;
        }
    }
    fn strike(
        self: *World,
        actor: *const Actor,
        definition: Definition,
        terrain: @import("../terrain.zig").View,
        targets: []const combat.Target,
        first_target: usize,
    ) !bool {
        const hit = try combat.trace(
            terrain,
            actor.room,
            actor.pose,
            .crouched,
            definition.strike_cells,
            targets,
        ) orelse return false;
        const index = @backingInt(hit.target);
        if (index >= first_target and index < first_target + self.actors.len) {
            const other = &self.actors[index - first_target];
            if (other.room == hit.sender_room) other.pending_hits.set(hit.impact);
        } else {
            self.outgoing[self.outgoing_count] = hit;
            self.outgoing_count += 1;
        }
        return true;
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        profiles: []const Profile,
        terrain: @import("../terrain.zig").View,
        player: contacts.Footprint,
        targets: []combat.Target,
        first_target: usize,
    ) !void {
        self.outgoing_count = 0;
        const current = try terrain.geometry.room(player.room);
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            actor.sound = null;
            if (actor.removed) continue;
            const same_room = actor.room == player.room;
            var adjacent = same_room;
            for ([_]geometry.Edge{
                current.edges.left,
                current.edges.right,
                current.edges.up,
                current.edges.down,
            }) |edge| if (edge == .room and edge.room == actor.room) {
                adjacent = true;
            };
            if (definition.wake_nearby) {
                const above = current.edges.up == .room and
                    current.edges.up.room == actor.room and
                    actor.pose.position.y >= 48;
                const below = current.edges.down == .room and
                    current.edges.down.room == actor.room and
                    actor.pose.position.y >= 176;
                if (same_room or above or below) actor.active = true;
            }
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clip(actor.phase);
            const hits = actor.pending_hits;
            actor.pending_hits = .{};
            const vulnerable = actor.vulnerability();
            const impact: ?combat.Impact = if (hits.front_low and
                vulnerable.front_low) .front_low else if (hits.rear_low and
                vulnerable.rear_low) .rear_low else null;
            if (impact != null) actor.playback.completeDisplacement(clip, &actor.pose);
            if (actor.playback.exhausted(clip)) {
                const previous = actor.phase;
                var audible = true;
                const environment: Environment = .{ .map = terrain.geometry, .room = actor.room };
                const awareness = try perception.observe(
                    terrain.geometry,
                    .{ .room = actor.room, .pose = actor.pose },
                    player,
                    &.{},
                );
                if (impact) |hit| {
                    actor.phase = if (hit == .front_low) .collapsing_front else .collapsing_rear;
                } else switch (actor.phase) {
                    .closed_idle, .closed_walk => {
                        if (awareness.player(
                            false,
                            profile.deployment_distance,
                        )) actor.phase = if (previous == .closed_idle) .deploying else .closed_idle else if (awareness.player(
                            false,
                            0,
                        ) and try environment.at(
                            actor.pose,
                            .torso,
                            profile.wall_ahead,
                        )) actor.phase = .closed_idle else if (awareness.player(
                            false,
                            0,
                        ) and try environment.at(
                            actor.pose,
                            .support,
                            profile.floor_ahead,
                        )) actor.phase = .closed_walk else if (awareness.player(
                            true,
                            0,
                        )) actor.phase = .closed_turn else {
                            actor.phase = .closed_idle;
                            if (previous == .closed_idle) {
                                audible = false;
                                if (!definition.wake_nearby or !adjacent) actor.active = false;
                            }
                        }
                    },
                    .closed_turn, .retracting => actor.phase = .closed_idle,
                    .deploying, .open_turn => actor.phase = .open_idle_a,
                    .open_idle_a, .open_idle_b => {
                        const alternate: Phase = if (previous == .open_idle_a) .open_idle_b else .open_idle_a;
                        if (awareness.player(false, profile.strike_distance) and try self.strike(
                            actor,
                            definition,
                            terrain,
                            targets,
                            first_target,
                        )) actor.phase = alternate else if (awareness.player(
                            true,
                            0,
                        )) actor.phase = .open_turn else if (awareness.player(
                            false,
                            profile.obstacle_distance,
                        ) and try environment.at(
                            actor.pose,
                            .torso,
                            profile.wall_ahead,
                        )) actor.phase = alternate else if (awareness.player(
                            false,
                            profile.pursuit_distance[@intFromBool(previous == .open_idle_b)],
                        ) and try environment.at(
                            actor.pose,
                            .support,
                            profile.floor_ahead,
                        )) actor.phase = .open_walk_a else actor.phase = .retracting;
                    },
                    .open_walk_a => {
                        if (awareness.player(false, profile.strike_distance)) _ = try self.strike(
                            actor,
                            definition,
                            terrain,
                            targets,
                            first_target,
                        );
                        actor.phase = .open_walk_b;
                    },
                    .open_walk_b => {
                        if (awareness.player(false, profile.strike_distance) and try self.strike(
                            actor,
                            definition,
                            terrain,
                            targets,
                            first_target,
                        )) actor.phase = .open_idle_a else if (awareness.player(
                            false,
                            profile.obstacle_distance,
                        ) and try environment.at(
                            actor.pose,
                            .torso,
                            profile.wall_ahead,
                        )) actor.phase = .open_idle_a else if (awareness.player(
                            false,
                            profile.walking_pursuit_distance,
                        ) and try environment.at(
                            actor.pose,
                            .support,
                            profile.floor_ahead,
                        )) actor.phase = .open_walk_a else actor.phase = .open_idle_a;
                    },
                    .collapsing_front, .collapsing_rear => actor.phase = .overloading,
                    .overloading => {
                        // The backward condition still uses the current forward strike ray;
                        // only a successful hit then turns the body before its explosion.
                        if (awareness.player(true, profile.explosion_distance)) {
                            if (try self.strike(
                                actor,
                                definition,
                                terrain,
                                targets,
                                first_target,
                            )) actor.reverse();
                        } else if (awareness.player(
                            false,
                            profile.explosion_distance,
                        )) _ = try self.strike(
                            actor,
                            definition,
                            terrain,
                            targets,
                            first_target,
                        );
                        actor.phase = .exploding;
                    },
                    .exploding => {
                        actor.removed = true;
                        actor.active = false;
                        audible = false;
                    },
                }
                if (previous == .closed_turn or previous == .open_turn) actor.reverse();
                if (previous == .closed_walk) shift(&actor.pose, profile.closed_step);
                if (previous == .open_walk_a or previous == .open_walk_b) shift(
                    &actor.pose,
                    profile.open_step,
                );
                actor.playback = .{};
                _ = try terrain.geometry.handoff(&actor.room, &actor.pose.position);
                clip = profile.clip(actor.phase);
                if (audible) actor.sound = clip.sound;
            }
            if (!actor.removed) _ = actor.playback.advance(clip, &actor.pose);
            targets[first_target + index].facing = actor.pose.facing;
            targets[first_target + index].active = actor.active and !actor.removed;
            targets[first_target + index].vulnerable = actor.vulnerability();
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| {
            for ([_]u32{
                @backingInt(actor.room),
                @as(u16, @bitCast(actor.pose.position.x)),
                @as(u16, @bitCast(actor.pose.position.y)),
                @backingInt(actor.pose.visual.id),
                @intCast(actor.playback.next_step),
            }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
            hash.update(&.{
                @backingInt(actor.phase),
                @backingInt(actor.pose.facing),
                @intFromBool(actor.pose.visual.mirrored),
                @intFromBool(actor.active),
                @intFromBool(actor.removed),
                @intFromBool(actor.pending_hits.front_low),
                @intFromBool(actor.pending_hits.rear_low),
            });
        }
    }
};
