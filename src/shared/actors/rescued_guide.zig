//! A civilian's retreat, release, invitation and guided walk to a story interaction.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const contacts = @import("../contacts.zig");
const Circuit = @import("../world_props.zig").CircuitId;
const Message = @import("../world_messages.zig").Id;
pub const Phase = enum { watching, retreating, captive, recovering, settling, turning_to_player, ready, briefing, inviting, turning_to_seat, walk_first, walk_second, sitting, awaiting_recording };
pub const Profile = struct { clips: [14]motion.Clip, attention_distance: i16, walking_cycles: i16, walking_end: i16, invitation: Message, briefing: Message };
pub const Definition = struct { profile: usize, initial_phase: Phase, footprint: contacts.Footprint, facing: motion.Facing, palette_bank: u4, behind_player: bool, initially_active: bool, wake_nearby: bool, accepts_signals: bool, interaction_priority: u16, hint: motion.VisualId, label: []const u8, offer_threshold: i16, path: Circuit, station: Circuit, reward: Circuit };
pub const Binding = struct { circuit: Circuit, actor: usize, next_step: bool };
pub const Payment = struct { item: @import("../equipment.zig").ItemHandle, actor: usize, next_step: bool };
pub const Actor = struct { pose: motion.Pose, room: geometry.RoomId, contact: contacts.Footprint, phase: Phase, playback: motion.Playback = .{}, active: bool, remaining: i16 = 0, ready: bool = false, pending: bool = false, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    candidate: ?usize = null,
    notice: ?Message = null,
    notice_priority: u16 = 0,
    pulses: []Circuit,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, profiles: []const Profile) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const first = switch (profiles[definition.profile].clips[@backingInt(definition.initial_phase)].steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingGuideVisual,
            };
            actor.* = .{ .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = first.id, .mirrored = first.mirrored != (definition.facing == .left) } }, .room = definition.footprint.room, .contact = definition.footprint, .phase = definition.initial_phase, .active = definition.initially_active };
        }
        return .{ .allocator = allocator, .actors = actors, .pulses = try allocator.alloc(Circuit, definitions.len * 3) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        self.notice = null;
        self.pulse_count = 0;
        const layout: contacts.Layout = .{};
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            actor.ready = actor.pending;
            actor.pending = false;
            actor.sound = null;
            actor.contact = .{ .room = actor.room, .position = actor.pose.position, .width = definition.footprint.width };
            const near = try @import("../activation.zig").around(map, player.room, actor.room, actor.pose.position.y);
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (try layout.overlaps(map, player, actor.contact)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.actors[binding.actor].pending = true else self.actors[binding.actor].ready = true;
        };
    }
    pub fn offerPayment(self: *World, definitions: []const Definition, payments: []const Payment, item: @import("../equipment.zig").ItemHandle, amount: i16) bool {
        const index = self.candidate orelse return false;
        if (amount < definitions[index].offer_threshold) return false;
        for (payments) |payment| if (payment.actor == index and payment.item.eql(item)) {
            if (payment.next_step) self.actors[index].pending = true else self.actors[index].ready = true;
            return true;
        };
        return false;
    }
    fn emit(self: *World, circuit: Circuit) void {
        self.pulses[self.pulse_count] = circuit;
        self.pulse_count += 1;
    }
    fn say(self: *World, id: Message, priority: u16) void {
        self.notice = id;
        self.notice_priority = priority;
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: contacts.Footprint, talk: bool) !void {
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            if (actor.ready and definition.accepts_signals) actor.active = true;
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clips[@backingInt(actor.phase)];
            const speaking = talk and self.candidate == index;
            const accepts = actor.phase == .captive or actor.phase == .awaiting_recording;
            const converses = actor.phase == .ready or actor.phase == .briefing or actor.phase == .awaiting_recording;
            if ((actor.ready and accepts) or (speaking and converses)) actor.playback.completeDisplacement(clip, &actor.pose);
            if (actor.playback.exhausted(clip)) {
                const near = try @import("../activation.zig").around(map, player.room, actor.room, actor.pose.position.y);
                switch (actor.phase) {
                    .watching => {
                        const awareness = try @import("perception.zig").observe(map, .{ .room = actor.room, .pose = actor.pose }, player, &.{});
                        if (awareness.player(false, profile.attention_distance)) actor.phase = .retreating else if (!near.same and !(definition.wake_nearby and near.near)) actor.active = false;
                    },
                    .retreating => {
                        actor.pose.facing = if (actor.pose.facing == .left) .right else .left;
                        actor.phase = .captive;
                    },
                    .captive => if (actor.ready) {
                        actor.phase = .recovering;
                    } else if (!near.same and !(definition.wake_nearby and near.near)) {
                        actor.active = false;
                    },
                    .recovering => actor.phase = .settling,
                    .settling => actor.phase = .turning_to_player,
                    .turning_to_player => actor.phase = .ready,
                    .ready => if (!near.same) {
                        if (!(definition.wake_nearby and near.near)) actor.active = false;
                    } else if (speaking) {
                        self.say(profile.invitation, definition.interaction_priority);
                        actor.phase = .inviting;
                    },
                    .inviting => {
                        self.emit(definition.reward);
                        actor.pose.facing = if (actor.pose.facing == .left) .right else .left;
                        actor.phase = .turning_to_seat;
                    },
                    .turning_to_seat => {
                        actor.remaining = profile.walking_cycles;
                        actor.phase = .walk_first;
                    },
                    .walk_first => actor.phase = .walk_second,
                    .walk_second => {
                        actor.remaining -%= 1;
                        actor.phase = if (actor.remaining == profile.walking_end) .sitting else .walk_first;
                    },
                    .sitting => {
                        self.emit(definition.station);
                        actor.phase = .awaiting_recording;
                    },
                    .awaiting_recording => if (actor.ready) {
                        actor.phase = .briefing;
                    } else if (speaking) {
                        self.say(profile.invitation, definition.interaction_priority);
                    },
                    .briefing => if (!near.same) {
                        if (!(definition.wake_nearby and near.near)) actor.active = false;
                    } else if (speaking) {
                        self.say(profile.briefing, definition.interaction_priority);
                        self.emit(definition.path);
                    },
                }
                actor.playback = .{};
                _ = try map.handoff(&actor.room, &actor.pose.position);
                clip = profile.clips[@backingInt(actor.phase)];
            }
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
            actor.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| for ([_]u64{ @backingInt(actor.phase), @backingInt(actor.room), @as(u16, @bitCast(actor.pose.position.x)), @as(u16, @bitCast(actor.pose.position.y)), @backingInt(actor.pose.facing), actor.playback.next_step, @as(u16, @bitCast(actor.remaining)), @intFromBool(actor.active), @intFromBool(actor.ready), @intFromBool(actor.pending) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
