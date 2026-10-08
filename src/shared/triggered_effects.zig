//! Decorative animation loops activated by world circuits.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const activation = @import("activation.zig");
const world_props = @import("world_props.zig");
pub const Definition = struct {
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    waiting: motion.Clip,
    running: motion.Clip,
    loop_delta: motion.Position,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Binding = struct { circuit: world_props.CircuitId, target: usize, next_step: bool };
pub const Instance = struct {
    room: geometry.RoomId,
    pose: motion.Pose,
    playback: motion.Playback = .{},
    running: bool = false,
    active: bool,
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const visual = switch (definition.waiting.steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingEffectVisual,
            };
            instance.* = .{
                .room = definition.room,
                .pose = .{
                    .position = definition.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .active = definition.initially_active,
            };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = false;
            instance.sound = null;
        }
    }
    pub fn route(
        self: *World,
        bindings: []const Binding,
        pulses: []const world_props.CircuitId,
    ) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player_room: geometry.RoomId,
    ) !void {
        for (self.instances, definitions) |*instance, definition| {
            const near = try activation.around(
                map,
                player_room,
                instance.room,
                instance.pose.position.y,
            );
            if (definition.wake_nearby and
                near.wake or
                instance.ready and
                    definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = if (instance.running) definition.running else definition.waiting;
            if (instance.ready and
                !instance.running) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                if (instance.running) {
                    instance.pose.position.x +%= if (instance.pose.facing == .left) definition.loop_delta.x else -definition.loop_delta.x;
                    instance.pose.position.y +%= definition.loop_delta.y;
                    _ = try map.handoff(&instance.room, &instance.pose.position);
                } else if (instance.ready) instance.running = true;
                if ((!instance.running or !near.same) and
                    !(definition.wake_nearby and near.near)) instance.active = false;
                instance.playback = .{};
                clip = if (instance.running) definition.running else definition.waiting;
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
            instance.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @backingInt(instance.room),
            @as(u16, @bitCast(instance.pose.position.x)),
            @as(u16, @bitCast(instance.pose.position.y)),
            instance.playback.next_step,
            @intFromBool(instance.running),
            @intFromBool(instance.active),
            @intFromBool(instance.ready),
            @intFromBool(instance.pending),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
