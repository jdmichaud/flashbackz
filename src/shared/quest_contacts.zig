//! Revealed quest contacts, one-time conversations and delivery acknowledgements.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Pose = enum { resting, fidgeting, leaning, recovering };
pub const Stage = enum { hidden, available, conversation_finished, departing, removed };
pub const Action = enum { reveal, deliver };
pub const Role = enum { giver, recipient, conversation, introducer, seller };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    hidden: bool,
    role: Role,
    cycle: enum { alternating, three_poses, stationary },
    idle: [4]motion.Clip,
    after: [4]motion.Clip,
    hidden_clip: motion.Clip,
    chances: [4]i16,
    offscreen_choice_first: [4]bool = @splat(false),
    notice: @import("world_messages.zig").Id,
    outputs: []const Circuit,
    departure_outputs: []const Circuit = &.{},
    sale: ?struct { purse: @import("equipment.zig").ItemHandle, price: i16, debit: i16 } = null,
    hint: motion.VisualId,
    label: []const u8,
    priority: u16,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Payment = struct { item: @import("equipment.zig").ItemHandle, contact: usize, next_step: bool };
pub const Binding = struct { circuit: Circuit, target: usize, action: Action, next_step: bool };
pub const Instance = struct {
    pose: motion.Pose,
    stage: Stage,
    idle_pose: Pose = .resting,
    playback: motion.Playback = .{},
    active: bool,
    reveal: bool = false,
    delivery: bool = false,
    pending_reveal: bool = false,
    pending_delivery: bool = false,
    payment: bool = false,
    pending_payment: bool = false,
    sound: ?motion.SoundId = null,
    pub fn body(self: Instance, definition: Definition) ?contacts.Footprint {
        if (self.stage == .hidden or self.stage == .removed) return null;
        var result = definition.footprint;
        result.position = self.pose.position;
        return result;
    }
    fn clip(self: Instance, definition: Definition) motion.Clip {
        return if (self.stage == .hidden) definition.hidden_clip else if (self.stage == .conversation_finished or self.stage == .departing) definition.after[@backingInt(self.idle_pose)] else definition.idle[@backingInt(self.idle_pose)];
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    notice: ?@import("world_messages.zig").Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        var capacity: usize = 0;
        for (instances, definitions) |*instance, definition| {
            const visual = switch (definition.idle[0].steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingQuestContactVisual,
            };
            instance.* = .{ .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } }, .stage = if (definition.hidden) .hidden else .available, .active = definition.initially_active };
            capacity += definition.outputs.len + definition.departure_outputs.len;
        }
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(Circuit, capacity) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.pulse_count = 0;
        self.candidate = null;
        self.notice = null;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.reveal = instance.pending_reveal;
            instance.pending_reveal = false;
            instance.delivery = instance.pending_delivery;
            instance.pending_delivery = false;
            instance.sound = null;
            instance.payment = instance.pending_payment;
            instance.pending_payment = false;
            if (instance.body(definition)) |body| {
                const near = try @import("activation.zig").around(map, player.room, body.room, body.position.y);
                if (definition.wake_nearby and near.wake) instance.active = true;
                if (try layout.overlaps(map, player, body)) self.candidate = index;
            }
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            const instance = &self.instances[binding.target];
            switch (binding.action) {
                .reveal => {
                    if (binding.next_step) instance.pending_reveal = true else instance.reveal = true;
                },
                .deliver => {
                    if (binding.next_step) instance.pending_delivery = true else instance.delivery = true;
                },
            }
        };
    }
    pub fn offerPayment(self: *World, definitions: []const Definition, payments: []const Payment, item: @import("equipment.zig").ItemHandle, amount: i16) bool {
        const index = self.candidate orelse return false;
        const sale = definitions[index].sale orelse return false;
        if (self.instances[index].stage != .available or amount < sale.price) return false;
        for (payments) |binding| if (binding.contact == index and binding.item.eql(item)) {
            if (binding.next_step) self.instances[index].pending_payment = true else self.instances[index].payment = true;
            return true;
        };
        return false;
    }
    fn chance(random: anytype, denominator: i16) bool {
        return denominator != 0 and @rem(@as(i16, @bitCast(random.next())), denominator) == 0;
    }
    fn choosePose(instance: *Instance, definition: Definition, random: anytype) void {
        if (definition.cycle == .stationary) return;
        switch (instance.idle_pose) {
            .resting => if (chance(random, definition.chances[0])) {
                instance.idle_pose = .fidgeting;
            },
            .fidgeting => if (definition.cycle == .alternating) {
                instance.idle_pose = .leaning;
            } else if (chance(random, definition.chances[1])) {
                instance.idle_pose = .leaning;
            } else if (chance(random, definition.chances[2])) {
                instance.idle_pose = .resting;
            },
            .leaning => if (chance(random, definition.chances[3])) {
                instance.idle_pose = if (definition.cycle == .alternating) .recovering else .fidgeting;
            },
            .recovering => instance.idle_pose = .resting,
        }
    }
    fn emit(self: *World, bindings: []const Binding, outputs: []const Circuit) void {
        for (outputs) |output| {
            self.pulses[self.pulse_count] = output;
            self.pulse_count += 1;
            self.route(bindings, &.{output});
        }
    }
    pub fn advance(self: *World, definitions: []const Definition, bindings: []const Binding, map: geometry.Map, room: geometry.RoomId, talk: bool, items: *@import("equipment.zig").Loadout, random: anytype) !void {
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            if (instance.stage == .removed) continue;
            const speaking = talk and self.candidate == index and instance.stage == .available;
            const receiving = instance.stage == .available and ((instance.delivery and definition.role == .recipient) or (instance.payment and definition.role == .seller));
            const revealing = instance.reveal and instance.stage == .hidden;
            if ((speaking or receiving or revealing) and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = instance.clip(definition);
            if (speaking or receiving or revealing) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                const near = try @import("activation.zig").around(map, room, definition.footprint.room, instance.pose.position.y);
                if (revealing) {
                    instance.stage = .available;
                } else if (instance.stage == .hidden) {
                    instance.active = false;
                } else if (instance.stage == .departing) {
                    self.emit(bindings, definition.departure_outputs);
                    instance.stage = .removed;
                    instance.active = false;
                } else if (receiving) {
                    if (definition.sale) |sale| try items.debit(sale.purse, sale.debit) else instance.stage = .departing;
                    self.emit(bindings, definition.outputs);
                } else if (speaking) {
                    self.notice = .{ .message = definition.notice, .icon = definition.hint, .priority = definition.priority };
                    if (definition.role == .giver or definition.role == .introducer) {
                        instance.stage = if (definition.role == .introducer) .departing else .conversation_finished;
                        self.emit(bindings, definition.outputs);
                    }
                } else if (!near.same) {
                    const before = instance.idle_pose;
                    if (definition.offscreen_choice_first[@backingInt(before)]) choosePose(instance, definition, random);
                    if (instance.idle_pose == before and !(definition.wake_nearby and near.near)) instance.active = false;
                } else choosePose(instance, definition, random);
                instance.playback = .{};
                clip = instance.clip(definition);
            }
            instance.reveal = false;
            instance.delivery = false;
            instance.payment = false;
            if (instance.stage != .removed) {
                instance.sound = instance.playback.soundOnEntry(clip);
                _ = instance.playback.advance(clip, &instance.pose);
            }
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @backingInt(instance.stage), @backingInt(instance.idle_pose), instance.playback.next_step, @intFromBool(instance.active), @intFromBool(instance.reveal), @intFromBool(instance.delivery), @intFromBool(instance.pending_reveal), @intFromBool(instance.pending_delivery), @intFromBool(instance.payment), @intFromBool(instance.pending_payment), @as(u16, @bitCast(instance.pose.position.x)), @as(u16, @bitCast(instance.pose.position.y)) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
