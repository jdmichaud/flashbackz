//! Credential locks own their used state and emit ordinary circuit pulses. Inventory
//! decides which key is selected; a successful match schedules its authored consumption.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const equipment = @import("equipment.zig");
const props = @import("world_props.zig");
pub const Receiver = struct {
    footprint: contacts.Footprint,
    credential: i16,
    target: union(enum) { lock: usize, manual_control },
};
pub const Binding = struct { item: equipment.ItemHandle, receiver: usize, activates: bool, next_step: bool };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: props.Layer,
    idle: motion.Clip,
    used: motion.Clip,
    credential: i16,
    interaction_priority: u16 = 0,
    unlock_forward: i16,
    unlock_down: i16,
    unlock_sound: ?motion.SoundId,
    circuits: []const props.CircuitId,
    notice: ?@import("world_messages.zig").Id = null,
    initially_used: bool,
    initially_active: bool,
    wake_when_near: bool,
    accepts_signals: bool,
    hint: motion.VisualId,
    label: []const u8,
};
pub const Instance = struct {
    pose: motion.Pose,
    playback: motion.Playback = .{},
    used: bool,
    active: bool,
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []props.CircuitId,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    use_candidate: ?usize = null,
    notice: ?@import("world_messages.zig").Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const clip = if (definition.initially_used) definition.used else definition.idle;
            if (clip.steps.len == 0) return error.MissingLockAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingLockVisual,
            };
            instance.* = .{ .used = definition.initially_used, .active = definition.initially_active, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        var capacity: usize = 0;
        for (definitions) |definition| capacity += definition.circuits.len;
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(props.CircuitId, capacity) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, receivers: []const Receiver, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        self.use_candidate = null;
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = false;
        }
        const layout: contacts.Layout = .{};
        for (receivers, 0..) |receiver, index| {
            var footprint = receiver.footprint;
            if (receiver.target == .lock) {
                const lock = receiver.target.lock;
                footprint.position = self.instances[lock].pose.position;
                const near = try @import("activation.zig").around(map, player.room, footprint.room, footprint.position.y);
                if (definitions[lock].wake_when_near and near.wake) self.instances[lock].active = true;
            }
            if (try layout.overlaps(map, player, footprint)) self.use_candidate = index;
        }
        if (self.use_candidate) |index| if (receivers[index].target == .lock) {
            self.candidate = receivers[index].target.lock;
        };
    }
    pub fn useKey(self: *World, definitions: []const Definition, receivers: []const Receiver, bindings: []const Binding, loadout: *equipment.Loadout, handle: equipment.ItemHandle, map: geometry.Map, room: geometry.RoomId) !bool {
        const index = self.use_candidate orelse return false;
        const receiver = receivers[index];
        const item = try loadout.item(handle);
        if (item.state != .carried or item.consume_in != null or item.recharge_in != null) return false;
        const action = item.definition.use_action orelse return false;
        if (action != .unlock) return false;
        const credential = switch (action.unlock.credential) {
            .fixed => |value| value,
            .item_charge => item.quantity,
        };
        if (credential != receiver.credential) return false;
        const binding = for (bindings) |entry| {
            if (entry.receiver == index and entry.item.eql(handle)) break entry;
        } else return false;
        // Matching succeeds independently of whether the control accepts the signal.
        // This also preserves consumption at a matching, already-used lock.
        if (binding.activates) {
            const lock = receiver.target.lock;
            const definition = definitions[lock];
            const near = try @import("activation.zig").around(map, room, definition.footprint.room, self.instances[lock].pose.position.y);
            if (definition.wake_when_near and near.wake) self.instances[lock].active = true;
            if (self.instances[lock].active or definition.accepts_signals) {
                if (binding.next_step) self.instances[lock].pending = true else self.instances[lock].ready = true;
            }
        }
        if (action.unlock.consume_after_steps) |steps| try loadout.consumeAfter(handle, steps);
        return true;
    }
    pub fn advance(self: *World, definitions: []const Definition, map: geometry.Map, room: geometry.RoomId, operate: bool) !void {
        self.pulse_count = 0;
        self.notice = null;
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.sound = null;
            const near = try @import("activation.zig").around(map, room, definition.footprint.room, instance.pose.position.y);
            if (definition.wake_when_near and near.wake) instance.active = true;
            if (operate and self.candidate == index and !instance.used and definition.notice != null and (instance.active or definition.accepts_signals)) {
                instance.active = true;
                instance.playback.completeDisplacement(definition.idle, &instance.pose);
                instance.playback = .{};
                self.notice = .{ .message = definition.notice.?, .icon = definition.hint, .priority = definition.interaction_priority };
            } else if (instance.ready) {
                instance.active = true;
                if (!instance.used) {
                    instance.used = true;
                    instance.playback = .{};
                    instance.pose.position.x +%= if (instance.pose.facing == .right) definition.unlock_forward else -definition.unlock_forward;
                    instance.pose.position.y +%= definition.unlock_down;
                    instance.sound = definition.unlock_sound;
                    for (definition.circuits) |circuit| {
                        self.pulses[self.pulse_count] = circuit;
                        self.pulse_count += 1;
                    }
                }
            }
            instance.ready = false;
            if (!instance.active) continue;
            const clip = if (instance.used) definition.used else definition.idle;
            if (instance.playback.exhausted(clip)) {
                if (room != definition.footprint.room and !(definition.wake_when_near and near.near)) instance.active = false;
                instance.playback = .{};
            }
            if (instance.sound == null) instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        const receiver: u64 = if (self.use_candidate) |index| index + 1 else 0;
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, receiver)));
        for (self.instances) |instance| for ([_]u64{ @as(u16, @bitCast(instance.pose.position.x)), @as(u16, @bitCast(instance.pose.position.y)), @intFromBool(instance.active), @intFromBool(instance.used), @intFromBool(instance.ready), @intFromBool(instance.pending), instance.playback.next_step, @backingInt(instance.pose.visual.id), @intFromBool(instance.pose.visual.mirrored) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
