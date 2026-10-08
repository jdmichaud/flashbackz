//! A frightened civilian alerts an encounter, waits for safety and acknowledges the rescue.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum {
    watching,
    retreating,
    frightened,
    relaxing,
    standing,
    sitting,
    ready,
    informed,
};
pub const Definition = struct { room: geometry.RoomId, position: motion.Position, facing: motion.Facing, width: u8, clips: [8]motion.Clip, initial: Phase, hidden: bool, trigger_distance: i16, alert: Circuit, acknowledged: Circuit, messages: [2]@import("world_messages.zig").Id, hint: motion.VisualId, label: []const u8, priority: u16, palette_bank: u4, behind_player: bool, initially_active: bool, wake_nearby: bool, accepts_signals: bool };
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Actor = struct {
    room: geometry.RoomId,
    pose: motion.Pose,
    contact: contacts.Footprint,
    phase: Phase,
    playback: motion.Playback = .{},
    active: bool,
    hidden: bool,
    removed: bool = false,
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
    pub fn body(self: Actor, definition: Definition) ?contacts.Footprint {
        return if (self.hidden or self.removed) null else .{
            .room = self.room,
            .position = self.pose.position,
            .width = definition.width,
        };
    }
    pub fn clip(self: Actor, definition: Definition) motion.Clip {
        return definition.clips[@backingInt(self.phase)];
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    pulses: []Circuit,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    notice: ?@import("world_messages.zig").Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const visual = switch (definition.clips[@backingInt(definition.initial)].steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingRescueContactVisual,
            };
            actor.* = .{
                .room = definition.room,
                .pose = .{
                    .position = definition.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .contact = .{
                    .room = definition.room,
                    .position = definition.position,
                    .width = definition.width,
                },
                .phase = definition.initial,
                .active = definition.initially_active,
                .hidden = definition.hidden,
            };
        }
        return .{
            .allocator = allocator,
            .actors = actors,
            .pulses = try allocator.alloc(Circuit, definitions.len),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
    ) !void {
        self.pulse_count = 0;
        self.candidate = null;
        self.notice = null;
        const layout: contacts.Layout = .{};
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            actor.ready = actor.pending;
            actor.pending = false;
            actor.sound = null;
            actor.contact = .{
                .room = actor.room,
                .position = actor.pose.position,
                .width = definition.width,
            };
            if (actor.hidden or actor.removed) continue;
            const near = try @import("activation.zig").around(
                map,
                player.room,
                actor.room,
                actor.pose.position.y,
            );
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (try layout.overlaps(map, player, actor.contact)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.actors[binding.target].pending = true else self.actors[binding.target].ready = true;
        };
    }
    pub fn advanceOne(
        self: *World,
        index: usize,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
        talk: bool,
    ) !void {
        const actor = &self.actors[index];
        const definition = definitions[index];
        if (actor.removed) return;
        const speaking = talk and
            self.candidate == index and
            (actor.phase == .ready or actor.phase == .informed);
        if ((actor.ready or speaking) and definition.accepts_signals) actor.active = true;
        if (!actor.active) return;
        var clip = actor.clip(definition);
        if (speaking or
            (actor.ready and
                (actor.hidden or actor.phase == .frightened))) actor.playback.completeDisplacement(
            clip,
            &actor.pose,
        );
        if (actor.playback.exhausted(clip)) {
            const near = try @import("activation.zig").around(
                map,
                player.room,
                actor.room,
                actor.pose.position.y,
            );
            var output: ?Circuit = null;
            if (actor.hidden) {
                if (actor.ready) actor.hidden = false else actor.active = false;
            } else switch (actor.phase) {
                .watching => {
                    const awareness = try @import("actors/perception.zig").observe(
                        map,
                        .{ .room = actor.room, .pose = actor.pose },
                        player,
                        &.{},
                    );
                    if (awareness.player(true, definition.trigger_distance)) {
                        actor.phase = .retreating;
                        output = definition.alert;
                    } else if (!near.same and
                        !(definition.wake_nearby and near.near)) actor.active = false;
                },
                .retreating => {
                    actor.pose.facing = if (actor.pose.facing == .left) .right else .left;
                    actor.phase = .frightened;
                },
                .frightened => if (actor.ready) {
                    actor.phase = .relaxing;
                } else if (!near.same and !(definition.wake_nearby and near.near)) {
                    actor.active = false;
                },
                .relaxing => actor.phase = .standing,
                .standing => actor.phase = .sitting,
                .sitting => actor.phase = .ready,
                .ready, .informed => {
                    if (!near.same) {
                        if (actor.phase == .informed) {
                            actor.removed = true;
                            actor.active = false;
                        } else if (!(definition.wake_nearby and near.near)) actor.active = false;
                    } else if (speaking) {
                        self.notice = .{
                            .message = definition.messages[@intFromBool(actor.phase == .informed)],
                            .icon = definition.hint,
                            .priority = definition.priority,
                        };
                        if (actor.phase == .ready) {
                            actor.phase = .informed;
                            output = definition.acknowledged;
                        }
                    }
                },
            }
            if (output) |circuit| {
                self.pulses[self.pulse_count] = circuit;
                self.pulse_count += 1;
            }
            actor.playback = .{};
            _ = try map.handoff(&actor.room, &actor.pose.position);
            clip = actor.clip(definition);
        }
        actor.ready = false;
        if (!actor.removed) {
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| for ([_]u64{
            @backingInt(actor.phase),
            @backingInt(actor.room),
            @as(u16, @bitCast(actor.pose.position.x)),
            @as(u16, @bitCast(actor.pose.position.y)),
            @backingInt(actor.pose.facing),
            @backingInt(actor.pose.visual.id),
            @intFromBool(actor.pose.visual.mirrored),
            actor.playback.next_step,
            @intFromBool(actor.active),
            @intFromBool(actor.hidden),
            @intFromBool(actor.removed),
            @intFromBool(actor.ready),
            @intFromBool(actor.pending),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
