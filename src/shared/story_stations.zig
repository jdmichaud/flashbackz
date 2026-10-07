//! Activated, single-use story stations. A completed interaction replies through a circuit.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { dormant, ready, using, spent };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    idle: motion.Clip,
    use: motion.Clip,
    initially_available: bool,
    initially_active: bool,
    accepts_signals: bool,
    interaction_priority: u16,
    hint: motion.VisualId,
    label: []const u8,
    palette_bank: u4,
    behind_player: bool,
    movie: @import("story_cue.zig").Cue,
    reply: Circuit,
};
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Instance = struct { phase: Phase, pose: motion.Pose, playback: motion.Playback = .{}, active: bool, ready: bool = false, pending: bool = false, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    candidate: ?usize = null,
    movie: ?@import("story_cue.zig").Cue = null,
    pulses: []Circuit,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const first = switch (definition.idle.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingStationVisual,
            };
            instance.* = .{ .phase = if (definition.initially_available) .ready else .dormant, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = first.id, .mirrored = first.mirrored != (definition.facing == .left) } }, .active = definition.initially_active };
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
            instance.pending = false;
            instance.sound = null;
            if (instance.phase == .ready and try layout.overlaps(map, player, definition.footprint)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, operate: bool) void {
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            if (instance.phase == .spent) continue;
            const use = operate and self.candidate == index;
            if ((instance.ready or use) and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = if (instance.phase == .using) definition.use else definition.idle;
            if ((instance.phase == .dormant and instance.ready) or (instance.phase == .ready and use)) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                switch (instance.phase) {
                    .dormant => if (instance.ready) {
                        instance.phase = .ready;
                    } else {
                        instance.active = false;
                    },
                    .ready => if (use) {
                        instance.phase = .using;
                        self.movie = definition.movie;
                    } else {
                        instance.active = false;
                    },
                    .using => {
                        instance.phase = .spent;
                        instance.active = false;
                        self.pulses[self.pulse_count] = definition.reply;
                        self.pulse_count += 1;
                    },
                    .spent => unreachable,
                }
                instance.playback = .{};
                clip = if (instance.phase == .using) definition.use else definition.idle;
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
            instance.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            hash.update(&.{ @backingInt(instance.phase), @intFromBool(instance.active), @intFromBool(instance.ready), @intFromBool(instance.pending) });
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, instance.playback.next_step)));
        }
    }
};
