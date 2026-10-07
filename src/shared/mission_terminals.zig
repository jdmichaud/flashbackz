//! Work-permit terminals own assignment status, briefings, rewards and successor signals.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const equipment = @import("equipment.zig");
const Circuit = @import("world_props.zig").CircuitId;
const Cue = @import("story_cue.zig").Cue;
pub const Phase = enum { locked, available, assigned, paying, completed };
pub const Action = enum { unlock, accept, complete };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    clips: [5]motion.Clip,
    initial_phase: Phase,
    briefing: Cue,
    acceptance: Cue,
    completion: Cue,
    assignment: Circuit,
    successor: Circuit,
    purse: equipment.ItemHandle,
    reward: i16,
    hint: motion.VisualId,
    label: []const u8,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Binding = struct { circuit: Circuit, target: usize, action: Action, next_step: bool };
const Requests = struct {
    unlock: bool = false,
    accept: bool = false,
    complete: bool = false,
    fn add(self: *Requests, action: Action) void {
        switch (action) {
            .unlock => self.unlock = true,
            .accept => self.accept = true,
            .complete => self.complete = true,
        }
    }
};
pub const Instance = struct { pose: motion.Pose, phase: Phase, playback: motion.Playback = .{}, active: bool, ready: Requests = .{}, pending: Requests = .{}, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    movie: ?Cue = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const visual = switch (definition.clips[@backingInt(definition.initial_phase)].steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingMissionTerminalVisual,
            };
            instance.* = .{ .phase = definition.initial_phase, .active = definition.initially_active, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(Circuit, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        self.movie = null;
        self.pulse_count = 0;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.ready = instance.pending;
            instance.pending = .{};
            instance.sound = null;
            const near = try @import("activation.zig").around(map, player.room, definition.footprint.room, instance.pose.position.y);
            if (definition.wake_nearby and near.wake) instance.active = true;
            if (try layout.overlaps(map, player, definition.footprint)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            const instance = &self.instances[binding.target];
            if (binding.next_step) instance.pending.add(binding.action) else instance.ready.add(binding.action);
        };
    }
    fn emit(self: *World, bindings: []const Binding, circuit: Circuit) void {
        self.pulses[self.pulse_count] = circuit;
        self.pulse_count += 1;
        self.route(bindings, &.{circuit});
    }
    pub fn advance(self: *World, definitions: []const Definition, bindings: []const Binding, map: geometry.Map, room: geometry.RoomId, operate: bool, items: *equipment.Loadout) !void {
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            const requested = instance.ready.unlock or instance.ready.accept or instance.ready.complete;
            const reading = operate and self.candidate == index;
            if ((requested or reading) and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = definition.clips[@backingInt(instance.phase)];
            if (requested or reading) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                const near = try @import("activation.zig").around(map, room, definition.footprint.room, instance.pose.position.y);
                switch (instance.phase) {
                    .locked => if (instance.ready.unlock) {
                        instance.phase = .available;
                    } else {
                        instance.active = false;
                    },
                    .available => if (reading) {
                        self.movie = definition.briefing;
                    } else if (instance.ready.accept) {
                        instance.phase = .assigned;
                        self.movie = definition.acceptance;
                        self.emit(bindings, definition.assignment);
                    } else if (!near.same and !(definition.wake_nearby and near.near)) {
                        instance.active = false;
                    },
                    .assigned => if (reading) {
                        self.movie = definition.briefing;
                    } else if (instance.ready.complete) {
                        instance.phase = .paying;
                        self.movie = definition.completion;
                        self.emit(bindings, definition.successor);
                    } else if (!near.same and !(definition.wake_nearby and near.near)) {
                        instance.active = false;
                    },
                    .paying => {
                        try items.credit(definition.purse, definition.reward);
                        instance.phase = .completed;
                    },
                    .completed => instance.active = false,
                }
                instance.playback = .{};
                clip = definition.clips[@backingInt(instance.phase)];
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
            instance.ready = .{};
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @backingInt(instance.phase), instance.playback.next_step, @intFromBool(instance.active), @intFromBool(instance.ready.unlock), @intFromBool(instance.ready.accept), @intFromBool(instance.ready.complete), @intFromBool(instance.pending.unlock), @intFromBool(instance.pending.accept), @intFromBool(instance.pending.complete) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
