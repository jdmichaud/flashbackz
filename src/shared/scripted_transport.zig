//! Signal-driven travel waits for Conrad's acknowledgement, plays departure effects,
//! and relocates him to an authored destination without changing his possessions or health.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { dormant, awaiting_player, departing, finished };
pub const EffectPhase = enum { hidden, departure, arrival };
pub const Destination = struct { room: geometry.RoomId, position: motion.Position, facing: motion.Facing };
pub const Definition = struct {
    destination: Destination,
    cadence: [3]motion.Clip,
    effect_clips: [2]motion.Clip,
    palette_bank: u4,
    behind_player: bool,
    accepts_signals: bool,
};
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Instance = struct {
    phase: Phase = .dormant,
    playback: motion.Playback = .{},
    ready: bool = false,
    pending: bool = false,
    request_ready: bool = false,
    request_pending: bool = false,
    effect: EffectPhase = .hidden,
    effect_playback: motion.Playback = .{},
    effect_pose: motion.Pose = .{ .position = .{ .x = 0, .y = 0 }, .visual = .{ .id = @fromBackingInt(0) } },
    effect_room: ?geometry.RoomId = null,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const instances = try allocator.alloc(Instance, count);
        @memset(instances, .{});
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = false;
            instance.request_ready = instance.request_pending;
            instance.request_pending = false;
            instance.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn requesting(self: World) ?usize {
        for (self.instances, 0..) |instance, index| if (instance.request_ready and instance.phase == .awaiting_player) return index;
        return null;
    }
    pub fn advance(self: *World, definitions: []const Definition, acknowledged: ?usize, player: motion.Pose, room: geometry.RoomId) ?Destination {
        var destination: ?Destination = null;
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            if (instance.phase == .finished) continue;
            if (instance.phase == .dormant and !(instance.ready and definition.accepts_signals)) continue;
            var clip = definition.cadence[@backingInt(instance.phase)];
            // A received start/acknowledgement can interrupt a dormant cadence marker.
            if ((instance.phase == .dormant and instance.ready) or (instance.phase == .awaiting_player and acknowledged == index)) instance.playback.next_step = clip.steps.len;
            if (instance.playback.exhausted(clip)) {
                switch (instance.phase) {
                    .dormant => instance.phase = .awaiting_player,
                    .awaiting_player => if (acknowledged == index) {
                        instance.phase = .departing;
                        instance.effect = .departure;
                        instance.effect_pose = player;
                        instance.effect_room = room;
                        instance.effect_playback = .{};
                    } else {
                        instance.request_pending = true;
                    },
                    .departing => {
                        destination = definition.destination;
                        instance.phase = .finished;
                    },
                    .finished => unreachable,
                }
                instance.playback = .{};
                if (instance.phase == .finished) continue;
                clip = definition.cadence[@backingInt(instance.phase)];
            }
            instance.playback.next_step += 1;
        }
        return destination;
    }
    pub fn advanceEffects(self: *World, definitions: []const Definition, player: motion.Pose, room: geometry.RoomId) void {
        for (self.instances, definitions) |*instance, definition| {
            if (instance.effect == .hidden) continue;
            var clip = definition.effect_clips[@backingInt(instance.effect) - 1];
            if (instance.effect_playback.exhausted(clip)) {
                if (instance.effect == .arrival) {
                    instance.effect = .hidden;
                    instance.effect_room = null;
                    continue;
                }
                instance.effect = .arrival;
                instance.effect_pose = player;
                instance.effect_room = room;
                instance.effect_playback = .{};
                clip = definition.effect_clips[1];
            }
            instance.sound = instance.effect_playback.soundOnEntry(clip);
            _ = instance.effect_playback.advance(clip, &instance.effect_pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @backingInt(instance.phase), instance.playback.next_step, @intFromBool(instance.ready), @intFromBool(instance.pending), @intFromBool(instance.request_ready), @intFromBool(instance.request_pending), @backingInt(instance.effect), instance.effect_playback.next_step, if (instance.effect_room) |room| @backingInt(room) else 0, @as(u16, @bitCast(instance.effect_pose.position.x)), @as(u16, @bitCast(instance.effect_pose.position.y)), @backingInt(instance.effect_pose.facing), @backingInt(instance.effect_pose.visual.id), @intFromBool(instance.effect_pose.visual.mirrored) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};

test "transport waits for acknowledgement and repeated starts cannot shorten departure" {
    const hold = [_]motion.Step{.hold};
    const departing = [_]motion.Step{ .hold, .hold, .hold };
    const definition: Definition = .{
        .destination = .{ .room = @fromBackingInt(18), .position = .{ .x = 160, .y = 72 }, .facing = .left },
        .cadence = .{ .{ .steps = &hold }, .{ .steps = &hold }, .{ .steps = &departing } },
        .effect_clips = .{ .{ .steps = &departing }, .{ .steps = &departing } },
        .palette_bank = 0,
        .behind_player = false,
        .accepts_signals = true,
    };
    var world = try World.init(std.testing.allocator, 1);
    defer world.deinit();
    const player: motion.Pose = .{ .position = .{ .x = 80, .y = 144 }, .visual = .{ .id = @fromBackingInt(1) } };
    const room: geometry.RoomId = @fromBackingInt(7);
    const definitions = [_]Definition{definition};
    world.instances[0].ready = true;
    try std.testing.expect(world.advance(&definitions, null, player, room) == null);
    try std.testing.expectEqual(Phase.awaiting_player, world.instances[0].phase);
    for (0..5) |_| {
        world.beginStep();
        try std.testing.expect(world.advance(&definitions, null, player, room) == null);
        try std.testing.expectEqual(Phase.awaiting_player, world.instances[0].phase);
    }
    world.beginStep();
    try std.testing.expectEqual(@as(?usize, 0), world.requesting());
    try std.testing.expect(world.advance(&definitions, 0, player, room) == null);
    world.advanceEffects(&definitions, player, room);
    for (0..2) |_| {
        world.beginStep();
        world.instances[0].ready = true;
        try std.testing.expect(world.advance(&definitions, null, player, room) == null);
        world.advanceEffects(&definitions, player, room);
    }
    world.beginStep();
    try std.testing.expectEqualDeep(@as(?Destination, definition.destination), world.advance(&definitions, null, player, room));
    var arrived = player;
    arrived.position = definition.destination.position;
    arrived.facing = definition.destination.facing;
    world.advanceEffects(&definitions, arrived, definition.destination.room);
    try std.testing.expectEqual(EffectPhase.arrival, world.instances[0].effect);
    try std.testing.expectEqualDeep(arrived, world.instances[0].effect_pose);
    try std.testing.expectEqual(@as(?geometry.RoomId, definition.destination.room), world.instances[0].effect_room);
}
