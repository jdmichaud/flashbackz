//! Carried countdowns advance on their authored cadence, including while offscreen.
//! Pause menus and films suspend the world, so they naturally suspend this clock too.
const std = @import("std");
const motion = @import("motion.zig");
const equipment = @import("equipment.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { dormant, counting, finishing, removed };
pub const Definition = struct { item: equipment.ItemHandle, clips: [3]motion.Clip, started: Circuit, completed: Circuit, cleanup: Circuit, failure: @import("story_cue.zig").Cue };
pub const Action = enum { start, complete };
pub const Binding = struct { circuit: Circuit, target: usize, action: Action, next_step: bool };
const Requests = struct {
    start: bool = false,
    complete: bool = false,
    fn add(self: *Requests, action: Action) void {
        switch (action) {
            .start => self.start = true,
            .complete => self.complete = true,
        }
    }
};
pub const Instance = struct { phase: Phase = .dormant, playback: motion.Playback = .{}, ready: Requests = .{}, pending: Requests = .{}, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    failure: ?@import("story_cue.zig").Cue = null,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const instances = try allocator.alloc(Instance, count);
        errdefer allocator.free(instances);
        @memset(instances, .{});
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(Circuit, count) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn beginStep(self: *World) void {
        self.pulse_count = 0;
        self.failure = null;
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = .{};
            instance.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (pulse == binding.circuit) {
            if (binding.next_step) self.instances[binding.target].pending.add(binding.action) else self.instances[binding.target].ready.add(binding.action);
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, items: *equipment.Loadout) !void {
        for (self.instances, definitions) |*instance, definition| {
            if (instance.phase == .removed or (instance.phase == .dormant and !instance.ready.start)) continue;
            var clip = definition.clips[@backingInt(instance.phase)];
            if ((instance.phase == .dormant and instance.ready.start) or (instance.phase == .counting and instance.ready.complete)) instance.playback.next_step = clip.steps.len;
            if (instance.playback.exhausted(clip)) {
                var outgoing: ?Circuit = null;
                switch (instance.phase) {
                    .dormant => {
                        try items.grant(definition.item);
                        instance.phase = .counting;
                        outgoing = definition.started;
                    },
                    .counting => if (instance.ready.complete) {
                        instance.phase = .finishing;
                        outgoing = definition.completed;
                    } else if ((try items.item(definition.item)).quantity <= 0) {
                        instance.phase = .finishing;
                        self.failure = definition.failure;
                    } else {
                        try items.debit(definition.item, 1);
                    },
                    .finishing => {
                        try items.consume(definition.item);
                        outgoing = definition.cleanup;
                        instance.phase = .removed;
                    },
                    .removed => unreachable,
                }
                if (outgoing) |circuit| {
                    self.pulses[self.pulse_count] = circuit;
                    self.pulse_count += 1;
                }
                instance.playback = .{};
                if (instance.phase == .removed) continue;
                clip = definition.clips[@backingInt(instance.phase)];
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            instance.playback.next_step += 1;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @backingInt(instance.phase), instance.playback.next_step, @intFromBool(instance.ready.start), @intFromBool(instance.ready.complete), @intFromBool(instance.pending.start), @intFromBool(instance.pending.complete) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};

test "completion wins over expiry and removes the carried timer after cleanup cadence" {
    const hold = [_]motion.Step{.hold};
    const cycle = [_]motion.Step{ .hold, .hold };
    const item: equipment.ItemHandle = .{ .index = 0, .generation = 1 };
    var items = try equipment.Loadout.init(std.testing.allocator, &.{.{ .kind = .mission_time, .icon = @fromBackingInt(0), .introduction_steps = null, .initial_quantity = 1 }});
    defer items.deinit();
    const definitions = [_]Definition{.{ .item = item, .clips = .{ .{ .steps = &hold }, .{ .steps = &cycle }, .{ .steps = &hold } }, .started = @fromBackingInt(1), .completed = @fromBackingInt(2), .cleanup = @fromBackingInt(3), .failure = .reactor_failure }};
    var world = try World.init(std.testing.allocator, 1);
    defer world.deinit();
    world.instances[0].ready.start = true;
    try world.advance(&definitions, &items);
    try std.testing.expect(items.carries(.mission_time));
    for (0..2) |_| {
        world.beginStep();
        try world.advance(&definitions, &items);
    }
    try std.testing.expectEqual(@as(i16, 0), (try items.item(item)).quantity);
    world.beginStep();
    world.instances[0].ready.complete = true;
    try world.advance(&definitions, &items);
    try std.testing.expect(world.failure == null);
    try std.testing.expectEqual(Phase.finishing, world.instances[0].phase);
    try std.testing.expectEqualSlices(Circuit, &.{@fromBackingInt(2)}, world.pulses[0..world.pulse_count]);
    world.beginStep();
    try world.advance(&definitions, &items);
    try std.testing.expect(!items.carries(.mission_time));
    try std.testing.expectEqual(Phase.removed, world.instances[0].phase);
    try std.testing.expectEqualSlices(Circuit, &.{@fromBackingInt(3)}, world.pulses[0..world.pulse_count]);
}
