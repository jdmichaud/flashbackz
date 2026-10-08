//! Intermittent environmental rumble, driven by circuits and the shared random stream.
const std = @import("std");
const motion = @import("motion.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { dormant, waiting, burst };
pub const Definition = struct {
    room: ?@import("geometry.zig").RoomId,
    clips: [3]motion.Clip,
    chance_denominator: i16,
    burst_cycles: i16,
    burst_sound: motion.SoundId,
    initially_active: bool,
    accepts_signals: bool,
};
pub const Action = enum { start, stop };
pub const Binding = struct { circuit: Circuit, target: usize, action: Action, next_step: bool };
const Requests = struct {
    start: bool = false,
    stop: bool = false,
    fn add(self: *Requests, action: Action) void {
        switch (action) {
            .start => self.start = true,
            .stop => self.stop = true,
        }
    }
};
pub const Instance = struct {
    phase: Phase = .dormant,
    playback: motion.Playback = .{},
    remaining: i16 = 0,
    active: bool,
    ready: Requests = .{},
    pending: Requests = .{},
    sound: ?motion.SoundId = null,
    animation_sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    shake_rows: u2 = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        for (
            instances,
            definitions,
        ) |*instance, definition| instance.* = .{ .active = definition.initially_active };
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        for (self.instances) |*instance| {
            instance.ready = instance.pending;
            instance.pending = .{};
            instance.sound = null;
            instance.animation_sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (pulse == binding.circuit) {
            if (binding.next_step) self.instances[binding.target].pending.add(binding.action) else self.instances[binding.target].ready.add(binding.action);
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        random: *@import("random.zig").Stream,
    ) void {
        for (self.instances, definitions) |*instance, definition| {
            if ((instance.ready.start or instance.ready.stop) and
                definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = definition.clips[@backingInt(instance.phase)];
            if ((instance.phase == .dormant and instance.ready.start) or
                (instance.phase != .dormant and
                    instance.ready.stop)) instance.playback.next_step = clip.steps.len;
            if (instance.playback.exhausted(clip)) {
                switch (instance.phase) {
                    .dormant => if (instance.ready.start) {
                        instance.phase = .waiting;
                    } else {
                        instance.active = false;
                    },
                    .waiting => if (instance.ready.stop) {
                        instance.phase = .dormant;
                        instance.active = false;
                    } else if (@rem(
                        @as(i16, @bitCast(random.next())),
                        definition.chance_denominator,
                    ) == 0) {
                        instance.phase = .burst;
                        instance.remaining = definition.burst_cycles;
                    },
                    .burst => if (instance.ready.stop) {
                        instance.phase = .dormant;
                        instance.active = false;
                    } else {
                        instance.remaining -%= 1;
                        if (instance.remaining == 0) instance.phase = .waiting else {
                            instance.sound = definition.burst_sound;
                            self.shake_rows = @truncate(random.next() -% 1);
                        }
                    },
                }
                instance.playback = .{};
                clip = definition.clips[@backingInt(instance.phase)];
            }
            instance.animation_sound = instance.playback.soundOnEntry(clip);
            instance.playback.next_step += 1;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        hash.update(&.{self.shake_rows});
        for (self.instances) |instance| for ([_]u64{
            @backingInt(instance.phase),
            instance.playback.next_step,
            @as(u16, @bitCast(instance.remaining)),
            @intFromBool(instance.active),
            @intFromBool(instance.ready.start),
            @intFromBool(instance.ready.stop),
            @intFromBool(instance.pending.start),
            @intFromBool(instance.pending.stop),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
