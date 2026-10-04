//! Credential locks own their used state and emit ordinary circuit pulses. Inventory
//! decides which key is selected; a successful match schedules its authored consumption.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const equipment = @import("equipment.zig");
const props = @import("world_props.zig");
pub const Binding = struct { item: equipment.ItemHandle, lock: usize, next_step: bool };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: props.Layer,
    idle: motion.Clip,
    used: motion.Clip,
    credential: i16,
    unlock_forward: i16,
    unlock_down: i16,
    unlock_sound: ?motion.SoundId,
    circuit: props.CircuitId,
    initially_used: bool,
    initially_active: bool,
    wake_when_near: bool,
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
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(props.CircuitId, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, i| {
            instance.ready = instance.pending;
            instance.pending = false;
            var footprint = definition.footprint;
            footprint.position = instance.pose.position;
            if (try layout.overlaps(map, player, footprint)) self.candidate = i;
        }
    }
    pub fn useKey(self: *World, definitions: []const Definition, bindings: []const Binding, loadout: *equipment.Loadout, handle: equipment.ItemHandle) !bool {
        const index = self.candidate orelse return false;
        const item = try loadout.item(handle);
        if (item.state != .carried or item.consume_in != null) return false;
        const action = item.definition.use_action orelse return false;
        if (action != .unlock or action.unlock.credential != definitions[index].credential) return false;
        const binding = for (bindings) |entry| {
            if (entry.lock == index and entry.item.eql(handle)) break entry;
        } else return false;
        // Even a used matching lock accepts the credential check. The lock itself
        // ignores repeat activation, while the consumable item still completes use.
        if (binding.next_step) self.instances[index].pending = true else self.instances[index].ready = true;
        try loadout.consumeAfter(handle, action.unlock.consume_after_steps);
        return true;
    }
    pub fn advance(self: *World, definitions: []const Definition, map: geometry.Map, room: geometry.RoomId) !void {
        self.pulse_count = 0;
        for (self.instances, definitions) |*instance, definition| {
            instance.sound = null;
            const near = try @import("activation.zig").around(map, room, definition.footprint.room, instance.pose.position.y);
            if (definition.wake_when_near and near.wake) instance.active = true;
            if (instance.ready) {
                instance.active = true;
                if (!instance.used) {
                    instance.used = true;
                    instance.playback = .{};
                    instance.pose.position.x +%= if (instance.pose.facing == .right) definition.unlock_forward else -definition.unlock_forward;
                    instance.pose.position.y +%= definition.unlock_down;
                    instance.sound = definition.unlock_sound;
                    self.pulses[self.pulse_count] = definition.circuit;
                    self.pulse_count += 1;
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
        for (self.instances) |instance| for ([_]u64{ @as(u16, @bitCast(instance.pose.position.x)), @as(u16, @bitCast(instance.pose.position.y)), @intFromBool(instance.active), @intFromBool(instance.used), @intFromBool(instance.ready), @intFromBool(instance.pending), instance.playback.next_step, @backingInt(instance.pose.visual.id), @intFromBool(instance.pose.visual.mirrored) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
