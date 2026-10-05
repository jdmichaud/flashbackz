//! An injured civilian's attention, conversation and item-aid sequence. Original scripts
//! become authored clips, notices and circuit links; no source instructions run here.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const contacts = @import("../contacts.zig");
const equipment = @import("../equipment.zig");
const messages = @import("../world_messages.zig");
const Circuit = @import("../world_props.zig").CircuitId;
pub const Phase = enum { idle, calling, watching, attention_entry, attentive, waiting_entry, waiting, rest_entry, resting, attention_return, requesting, thanking, farewell, departing, gone };
pub const Profile = struct { clips: [14]motion.Clip, attention_cells: u8, look_behind: bool, wait_steps: i16, wait_end: i16, call_message: messages.Id, request_message: messages.Id, thanks_message: messages.Id };
pub const Definition = struct { profile: usize, footprint: contacts.Footprint, facing: motion.Facing, palette_bank: u4, behind_player: bool, initially_active: bool, wake_nearby: bool, accepts_signals: bool, credential: i16, interaction_priority: u16, hint: motion.VisualId, label: []const u8, return_item: Circuit, reward: Circuit };
pub const Binding = struct { item: equipment.ItemHandle, actor: usize, next_step: bool };
pub const Actor = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    contact: contacts.Footprint,
    phase: Phase = .idle,
    playback: motion.Playback = .{},
    active: bool,
    remaining: i16 = 0,
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
    pub fn clip(self: Actor, profile: Profile) motion.Clip {
        return profile.clips[@backingInt(if (self.phase == .gone) Phase.idle else self.phase)];
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    candidate: ?usize = null,
    notice: ?messages.Id = null,
    notice_priority: u16 = 0,
    pulses: []Circuit,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, profiles: []const Profile) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            const clip = profiles[definition.profile].clips[0];
            if (clip.steps.len == 0) return error.MissingCivilianAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingCivilianVisual,
            };
            actor.* = .{ .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } }, .room = definition.footprint.room, .contact = definition.footprint, .active = definition.initially_active };
        }
        return .{ .allocator = allocator, .actors = actors, .pulses = try allocator.alloc(Circuit, definitions.len * 2) };
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
            actor.contact = definition.footprint;
            actor.contact.room = actor.room;
            actor.contact.position = actor.pose.position;
            if (actor.phase == .gone) continue;
            const near = try @import("../activation.zig").around(map, player.room, actor.room, actor.pose.position.y);
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (try layout.overlaps(map, player, actor.contact)) self.candidate = index;
        }
    }
    pub fn offer(self: *World, definitions: []const Definition, bindings: []const Binding, item: equipment.ItemHandle, credential: i16) !bool {
        const index = self.candidate orelse return false;
        if (definitions[index].credential != credential) return false;
        const binding = for (bindings) |value| {
            if (value.actor == index and value.item.eql(item)) break value;
        } else return false;
        if (self.actors[index].active or definitions[index].accepts_signals) {
            if (binding.next_step) self.actors[index].pending = true else self.actors[index].ready = true;
        }
        return true;
    }
    pub fn offerPayment(self: *World, definitions: []const Definition, bindings: []const Binding, item: equipment.ItemHandle, amount: i16) !bool {
        const index = self.candidate orelse return false;
        if (amount < definitions[index].credential) return false;
        return self.offer(definitions, bindings, item, definitions[index].credential);
    }
    fn emit(self: *World, circuit: Circuit) void {
        self.pulses[self.pulse_count] = circuit;
        self.pulse_count += 1;
    }
    fn accept(self: *World, actor: *Actor, definition: Definition, reward_now: bool) void {
        self.emit(definition.return_item);
        if (reward_now) self.emit(definition.reward);
        actor.phase = .thanking;
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, map: geometry.Map, player: contacts.Footprint, talk: bool) !void {
        const layout: contacts.Layout = .{};
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            if (actor.phase == .gone) continue;
            const near = try @import("../activation.zig").around(map, player.room, actor.room, actor.pose.position.y);
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (actor.ready and definition.accepts_signals) actor.active = true;
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = actor.clip(profile);
            const interacting = talk and self.candidate == index;
            const interrupt = actor.phase == .attentive and (interacting or actor.ready) or actor.phase == .requesting and actor.ready;
            if (interrupt) actor.playback.completeDisplacement(clip, &actor.pose);
            if (actor.playback.exhausted(clip)) {
                const seen = if (try @import("perception.zig").scanObjects(map, player.room, .{ .room = actor.room, .pose = actor.pose }, &.{player}, profile.look_behind)) |distance| distance <= profile.attention_cells else false;
                switch (actor.phase) {
                    .idle => {
                        if (near.same) actor.phase = .calling else if (!(definition.wake_nearby and near.near)) actor.active = false;
                    },
                    .calling => {
                        actor.phase = .watching;
                        self.notice = profile.call_message;
                        self.notice_priority = definition.interaction_priority;
                    },
                    .watching => {
                        if (seen) actor.phase = .attention_entry else if (!near.same) actor.phase = .idle;
                    },
                    .attention_entry, .attention_return => actor.phase = .attentive,
                    .attentive => {
                        if (interacting) {
                            actor.phase = .requesting;
                            self.notice = profile.request_message;
                            self.notice_priority = definition.interaction_priority;
                        } else if (actor.ready) self.accept(actor, definition, true) else if (!(try layout.overlaps(map, actor.contact, player)) and !seen) {
                            actor.remaining = profile.wait_steps;
                            actor.phase = .waiting_entry;
                        }
                    },
                    .waiting_entry => actor.phase = .waiting,
                    .waiting => {
                        if (seen) actor.phase = .attention_entry else {
                            actor.remaining -%= 1;
                            if (actor.remaining == profile.wait_end) actor.phase = .rest_entry;
                        }
                    },
                    .rest_entry => actor.phase = .resting,
                    .resting => {
                        if (seen) actor.phase = .attention_return else if (!near.same) actor.phase = .idle;
                    },
                    .requesting => {
                        if (actor.ready) self.accept(actor, definition, false) else actor.phase = .attentive;
                    },
                    .thanking => {
                        self.notice = profile.thanks_message;
                        self.notice_priority = definition.interaction_priority;
                        self.emit(definition.reward);
                        actor.phase = .farewell;
                    },
                    .farewell => actor.phase = .departing,
                    .departing => {
                        actor.phase = .gone;
                        actor.active = false;
                    },
                    .gone => unreachable,
                }
                actor.playback = .{};
                if (actor.phase == .gone) continue;
                _ = try map.handoff(&actor.room, &actor.pose.position);
                clip = actor.clip(profile);
            }
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
            actor.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| for ([_]u64{ @backingInt(actor.phase), @backingInt(actor.room), @as(u16, @bitCast(actor.pose.position.x)), @as(u16, @bitCast(actor.pose.position.y)), actor.playback.next_step, @as(u16, @bitCast(actor.remaining)), @intFromBool(actor.active), @intFromBool(actor.ready), @intFromBool(actor.pending) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
