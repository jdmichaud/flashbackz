//! Civilian followers: keep a gap, turn toward the player and accept platform invitations.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const platforms = @import("lifts.zig");
const Environment = conrad_environment.Environment;
const activation = @import("activation.zig");
const conrad_environment = @import("actors/conrad_environment.zig");
const perception = @import("actors/perception.zig");
const world_messages = @import("world_messages.zig");
pub const Phase = enum { waiting, walk_first, walk_second, turning, boarding, riding };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    clips: [6]motion.Clip,
    gap: i16,
    stride_advance: i16,
    hint: motion.VisualId,
    label: []const u8,
    notice: world_messages.Id,
    priority: u16,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
};
pub const LiftBinding = struct { actor: usize, platform: usize, next_step: bool };
pub const Actor = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    contact: contacts.Footprint,
    phase: Phase = .waiting,
    playback: motion.Playback = .{},
    active: bool,
    platform: ?usize = null,
    invitation: ?usize = null,
    pending_invitation: ?usize = null,
    release: bool = false,
    pending_release: bool = false,
    late_displacement: i16 = 0,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    weighted_contacts: []contacts.Footprint,
    weighted_count: usize = 0,
    candidate: ?usize = null,
    notice: ?world_messages.Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const visual = switch (definition.clips[0].steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingEscortVisual,
            };
            actor.* = .{
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .room = definition.footprint.room,
                .contact = definition.footprint,
                .active = definition.initially_active,
            };
        }
        return .{
            .allocator = allocator,
            .actors = actors,
            .weighted_contacts = try allocator.alloc(contacts.Footprint, definitions.len),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.weighted_contacts);
    }
    pub fn prepare(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
    ) !void {
        self.candidate = null;
        self.notice = null;
        self.weighted_count = 0;
        const layout: contacts.Layout = .{};
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            actor.contact = .{
                .room = actor.room,
                .position = actor.pose.position,
                .width = definition.footprint.width,
            };
            actor.invitation = actor.pending_invitation;
            actor.pending_invitation = null;
            actor.release = actor.pending_release;
            actor.pending_release = false;
            actor.late_displacement = 0;
            actor.sound = null;
            const near = try activation.around(map, player.room, actor.room, actor.pose.position.y);
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (try layout.overlaps(map, player, actor.contact)) self.candidate = index;
            if (definition.clips[@backingInt(actor.phase)].presses_floor_switches) {
                self.weighted_contacts[self.weighted_count] = actor.contact;
                self.weighted_count += 1;
            }
        }
    }
    pub fn includeOccupancy(
        self: World,
        map: geometry.Map,
        lifts: *const platforms.World,
        definitions: []const platforms.Definition,
        occupancy: []platforms.Occupancy,
    ) !void {
        const layout: contacts.Layout = .{};
        for (self.actors) |actor| for (
            lifts.instances,
            definitions,
            occupancy,
            0..,
        ) |lift, definition, *occupied, index| if (try layout.overlaps(
            map,
            actor.contact,
            lift.footprint(definition),
        )) {
            occupied.contacts = true;
            if (actor.platform != index) occupied.unboarded_items = true;
        };
    }
    pub fn receiveLiftEvents(
        self: *World,
        bindings: []const LiftBinding,
        lifts: *const platforms.World,
        definitions: []const platforms.Definition,
        map: geometry.Map,
    ) !void {
        const layout: contacts.Layout = .{};
        for (bindings) |binding| {
            const actor = &self.actors[binding.actor];
            const lift = lifts.instances[binding.platform];
            if (lift.invite_items and try layout.overlaps(
                map,
                actor.contact,
                lift.footprint(definitions[binding.platform]),
            )) {
                if (binding.next_step) actor.pending_invitation = binding.platform else actor.invitation = binding.platform;
            }
            if (actor.platform == binding.platform) {
                if (binding.next_step) actor.late_displacement +%= lift.displacement else actor.pose.position.y +%= lift.displacement;
                if (lift.release_passengers) {
                    if (binding.next_step) actor.pending_release = true else actor.release = true;
                }
            }
        }
    }
    fn shift(actor: *Actor, amount: i16) void {
        actor.pose.position.x +%= if (actor.pose.facing == .right) amount else -amount;
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
        talk: bool,
    ) !void {
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            if (!actor.active) {
                actor.pose.position.y +%= actor.late_displacement;
                actor.late_displacement = 0;
                continue;
            }
            var clip = definition.clips[@backingInt(actor.phase)];
            const speaking = talk and
                self.candidate == index and
                (actor.phase == .waiting or actor.phase == .turning);
            if (speaking or
                (actor.phase == .waiting and actor.invitation != null) or
                (actor.phase == .riding and actor.release)) actor.playback.completeDisplacement(
                clip,
                &actor.pose,
            );
            if (actor.playback.exhausted(clip)) {
                const env: Environment = .{ .map = map, .room = actor.room };
                const awareness = try perception.observe(
                    map,
                    .{ .room = actor.room, .pose = actor.pose },
                    player,
                    &.{},
                );
                const front = awareness.player(false, 0);
                const behind = awareness.player(true, 0);
                const close = awareness.player(false, definition.gap);
                const room = try map.room(actor.room);
                const same = actor.room == player.room;
                const above = if (same) @divTrunc(player.position.y -% 8, 72) < @divTrunc(actor.pose.position.y, 72) else room.edges.up == .room and room.edges.up.room == player.room;
                const below = if (same) @divTrunc(player.position.y -% 8, 72) > @divTrunc(actor.pose.position.y, 72) else room.edges.down == .room and room.edges.down.room == player.room;
                const support = try env.at(actor.pose, .support, 1);
                const wall = try env.at(actor.pose, .torso, 1);
                switch (actor.phase) {
                    .waiting => {
                        if (speaking) {
                            self.notice = .{
                                .message = definition.notice,
                                .icon = definition.hint,
                                .priority = definition.priority,
                            };
                        } else if (front and actor.invitation != null) {
                            actor.platform = actor.invitation;
                            actor.phase = .boarding;
                        } else if (((above or below) and (!support or wall)) or behind) {
                            actor.phase = .turning;
                        } else if (front and
                            (!support or wall or close))
                        {} else if (front and
                            support)
                        {
                            shift(actor, definition.stride_advance);
                            actor.phase = .walk_first;
                        } else if (actor.invitation != null) {
                            actor.platform = actor.invitation;
                            actor.phase = .riding;
                            actor.active = false;
                        } else if ((above or below) and !wall) {
                            shift(actor, definition.stride_advance);
                            actor.phase = .walk_first;
                        } else if (!same) {
                            const near = try activation.around(
                                map,
                                player.room,
                                actor.room,
                                actor.pose.position.y,
                            );
                            if (!(definition.wake_nearby and near.near)) actor.active = false;
                        }
                    },
                    .walk_first, .walk_second => {
                        if (close or !support or wall) {
                            actor.phase = .waiting;
                        } else if (front or above or below) {
                            shift(actor, definition.stride_advance);
                            actor.phase = if (actor.phase == .walk_first) .walk_second else .walk_first;
                        } else actor.phase = .waiting;
                    },
                    .turning => {
                        if (speaking) self.notice = .{
                            .message = definition.notice,
                            .icon = definition.hint,
                            .priority = definition.priority,
                        };
                        actor.pose.facing = if (actor.pose.facing == .left) .right else .left;
                        actor.phase = .waiting;
                    },
                    .boarding => actor.phase = .riding,
                    .riding => if (actor.release) {
                        actor.platform = null;
                        actor.phase = .waiting;
                    },
                }
                actor.playback = .{};
                _ = try map.handoff(&actor.room, &actor.pose.position);
                clip = definition.clips[@backingInt(actor.phase)];
            }
            actor.invitation = null;
            actor.release = false;
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
            actor.pose.position.y +%= actor.late_displacement;
            actor.late_displacement = 0;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| for ([_]u64{
            @backingInt(actor.phase),
            @backingInt(actor.room),
            @as(u16, @bitCast(actor.pose.position.x)),
            @as(u16, @bitCast(actor.pose.position.y)),
            @backingInt(actor.pose.facing),
            actor.playback.next_step,
            @intFromBool(actor.active),
            if (actor.platform) |p| p + 1 else 0,
            if (actor.invitation) |p| p + 1 else 0,
            if (actor.pending_invitation) |p| p + 1 else 0,
            @intFromBool(actor.release),
            @intFromBool(actor.pending_release),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
