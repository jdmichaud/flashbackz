//! Signal-driven travel waits for Conrad's acknowledgement, plays departure effects,
//! and relocates him to an authored destination without changing his possessions or health.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { dormant, awaiting_player, departing, finished };
pub const EffectPhase = enum { hidden, departure, arrival };
pub const Destination = struct {
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
};
pub const Definition = struct {
    destination: Destination,
    cadence: [3]motion.Clip,
    effect: usize,
    effect_next_step: bool = false,
    contact: ?contacts.Footprint = null,
    wake_on_contact: bool = false,
    completion: ?Circuit = null,
    accepts_signals: bool,
};
pub const EffectDefinition = struct {
    clips: [2]motion.Clip,
    palette_bank: u4,
    behind_player: bool,
};
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Instance = struct {
    phase: Phase = .dormant,
    playback: motion.Playback = .{},
    ready: bool = false,
    pending: bool = false,
    request_ready: bool = false,
    request_pending: bool = false,
    active: bool = false,
};
pub const Effect = struct {
    ready: bool = false,
    pending: bool = false,
    effect: EffectPhase = .hidden,
    effect_playback: motion.Playback = .{},
    effect_pose: motion.Pose = .{
        .position = .{ .x = 0, .y = 0 },
        .visual = .{ .id = @fromBackingInt(0) },
    },
    effect_room: ?geometry.RoomId = null,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    effects: []Effect,
    pulses: []Circuit,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, count: usize, effect_count: usize) !World {
        const instances = try allocator.alloc(Instance, count);
        errdefer allocator.free(instances);
        @memset(instances, .{});
        const effects = try allocator.alloc(Effect, effect_count);
        errdefer allocator.free(effects);
        @memset(effects, .{});
        return .{
            .allocator = allocator,
            .instances = instances,
            .effects = effects,
            .pulses = try allocator.alloc(Circuit, count),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.effects);
        self.allocator.free(self.pulses);
    }
    pub fn beginStep(self: *World) void {
        self.pulse_count = 0;
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = false;
            instance.request_ready = instance.request_pending;
            instance.request_pending = false;
        }
        for (self.effects) |*effect| {
            effect.ready = effect.pending;
            effect.pending = false;
            effect.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn requesting(self: World) ?usize {
        for (
            self.instances,
            0..,
        ) |instance, index| if (instance.request_ready and
            instance.phase == .awaiting_player) return index;
        return null;
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        acknowledged: ?usize,
        player: contacts.Footprint,
        map: geometry.Map,
    ) !?Destination {
        var destination: ?Destination = null;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            if (instance.phase == .finished) continue;
            const touching = if (definition.contact) |body| try layout.overlaps(
                map,
                body,
                player,
            ) else true;
            if (instance.ready and
                definition.accepts_signals or
                definition.wake_on_contact and
                    touching) instance.active = true;
            if (!instance.active) continue;
            const clip = definition.cadence[@backingInt(instance.phase)];
            if ((instance.phase == .dormant and instance.ready) or
                (instance.phase == .awaiting_player and
                    acknowledged == index)) instance.playback.next_step = clip.steps.len;
            if (instance.playback.exhausted(clip)) {
                switch (instance.phase) {
                    .dormant => if (instance.ready) {
                        instance.phase = .awaiting_player;
                        if (definition.contact != null) instance.active = false;
                    } else {
                        instance.active = false;
                    },
                    .awaiting_player => if (acknowledged == index) {
                        instance.phase = .departing;
                        if (definition.effect_next_step) self.effects[definition.effect].pending = true else self.effects[definition.effect].ready = true;
                    } else if (definition.contact != null and
                        definition.contact.?.room != player.room)
                    {
                        instance.active = false;
                    } else if (touching) {
                        instance.request_pending = true;
                    },
                    .departing => {
                        destination = definition.destination;
                        instance.phase = .finished;
                        instance.active = false;
                        if (definition.completion) |circuit| {
                            self.pulses[self.pulse_count] = circuit;
                            self.pulse_count += 1;
                        }
                    },
                    .finished => unreachable,
                }
                instance.playback = .{};
                if (instance.phase == .finished) continue;
            }
            instance.playback.next_step += 1;
        }
        return destination;
    }
    pub fn advanceEffects(
        self: *World,
        definitions: []const EffectDefinition,
        player: motion.Pose,
        room: geometry.RoomId,
    ) void {
        for (self.effects, definitions) |*instance, definition| {
            if (instance.ready and instance.effect == .hidden) {
                instance.effect = .departure;
                instance.effect_pose = player;
                instance.effect_room = room;
                instance.effect_playback = .{};
            }
            if (instance.effect == .hidden) continue;
            var clip = definition.clips[@backingInt(instance.effect) - 1];
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
                clip = definition.clips[1];
            }
            instance.sound = instance.effect_playback.soundOnEntry(clip);
            _ = instance.effect_playback.advance(clip, &instance.effect_pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @backingInt(instance.phase),
            instance.playback.next_step,
            @intFromBool(instance.active),
            @intFromBool(instance.ready),
            @intFromBool(instance.pending),
            @intFromBool(instance.request_ready),
            @intFromBool(instance.request_pending),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        for (self.effects) |instance| for ([_]u64{
            @intFromBool(instance.ready),
            @intFromBool(instance.pending),
            @backingInt(instance.effect),
            instance.effect_playback.next_step,
            if (instance.effect_room) |room| @backingInt(room) else 0,
            @as(u16, @bitCast(instance.effect_pose.position.x)),
            @as(u16, @bitCast(instance.effect_pose.position.y)),
            @backingInt(instance.effect_pose.facing),
            @backingInt(instance.effect_pose.visual.id),
            @intFromBool(instance.effect_pose.visual.mirrored),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};

test "transport waits for acknowledgement and repeated starts cannot shorten departure" {
    const hold = [_]motion.Step{.hold};
    const departing = [_]motion.Step{ .hold, .hold, .hold };
    const definition: Definition = .{
        .destination = .{
            .room = @fromBackingInt(18),
            .position = .{ .x = 160, .y = 72 },
            .facing = .left,
        },
        .cadence = .{ .{ .steps = &hold }, .{ .steps = &hold }, .{ .steps = &departing } },
        .effect = 0,
        .accepts_signals = true,
    };
    var world = try World.init(std.testing.allocator, 1, 1);
    defer world.deinit();
    const player: motion.Pose = .{
        .position = .{ .x = 80, .y = 144 },
        .visual = .{ .id = @fromBackingInt(1) },
    };
    const room: geometry.RoomId = @fromBackingInt(7);
    const definitions = [_]Definition{definition};
    const effects = [_]EffectDefinition{.{
        .clips = .{ .{ .steps = &departing }, .{ .steps = &departing } },
        .palette_bank = 0,
        .behind_player = false,
    }};
    const contact: contacts.Footprint = .{ .room = room, .position = player.position };
    const map: geometry.Map = .{ .rooms = &.{} };
    world.instances[0].ready = true;
    try std.testing.expect(try world.advance(&definitions, null, contact, map) == null);
    try std.testing.expectEqual(Phase.awaiting_player, world.instances[0].phase);
    for (0..5) |_| {
        world.beginStep();
        try std.testing.expect(try world.advance(&definitions, null, contact, map) == null);
        try std.testing.expectEqual(Phase.awaiting_player, world.instances[0].phase);
    }
    world.beginStep();
    try std.testing.expectEqual(@as(?usize, 0), world.requesting());
    try std.testing.expect(try world.advance(&definitions, 0, contact, map) == null);
    world.advanceEffects(&effects, player, room);
    for (0..2) |_| {
        world.beginStep();
        world.instances[0].ready = true;
        try std.testing.expect(try world.advance(&definitions, null, contact, map) == null);
        world.advanceEffects(&effects, player, room);
    }
    world.beginStep();
    try std.testing.expectEqualDeep(
        @as(?Destination, definition.destination),
        try world.advance(&definitions, null, contact, map),
    );
    var arrived = player;
    arrived.position = definition.destination.position;
    arrived.facing = definition.destination.facing;
    world.advanceEffects(&effects, arrived, definition.destination.room);
    try std.testing.expectEqual(EffectPhase.arrival, world.effects[0].effect);
    try std.testing.expectEqualDeep(arrived, world.effects[0].effect_pose);
    try std.testing.expectEqual(
        @as(?geometry.RoomId, definition.destination.room),
        world.effects[0].effect_room,
    );
}
