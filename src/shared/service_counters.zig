//! Stationary service staff with an idle gesture cycle and credential-triggered outputs.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { neutral, turning, turned, returning };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    clips: [4]motion.Clip,
    gesture_chance: i16,
    return_chance: i16,
    output: Circuit,
    notice: @import("world_messages.zig").Id,
    hint: motion.VisualId,
    label: []const u8,
    priority: u16,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Instance = struct { pose: motion.Pose, phase: Phase = .neutral, playback: motion.Playback = .{}, active: bool, ready: bool = false, pending: bool = false, sound: ?motion.SoundId = null };
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
        for (instances, definitions) |*instance, definition| {
            const visual = switch (definition.clips[0].steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingCounterVisual,
            };
            instance.* = .{ .active = definition.initially_active, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(Circuit, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        self.notice = null;
        self.pulse_count = 0;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.ready = instance.pending;
            instance.pending = false;
            instance.sound = null;
            const near = try @import("activation.zig").around(map, player.room, definition.footprint.room, instance.pose.position.y);
            if (definition.wake_nearby and near.wake) instance.active = true;
            if (try layout.overlaps(map, player, definition.footprint)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, map: geometry.Map, room: geometry.RoomId, operate: bool, random: anytype) !void {
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            const speaking = operate and self.candidate == index;
            if ((instance.ready or speaking) and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = definition.clips[@backingInt(instance.phase)];
            if (speaking or instance.ready) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                if (instance.ready or speaking) {
                    if (instance.ready) {
                        self.pulses[self.pulse_count] = definition.output;
                        self.pulse_count += 1;
                    } else self.notice = .{ .message = definition.notice, .icon = definition.hint, .priority = definition.priority };
                    if (instance.phase == .turning) instance.phase = .turned else if (instance.phase == .returning) instance.phase = .neutral;
                } else {
                    const near = try @import("activation.zig").around(map, room, definition.footprint.room, instance.pose.position.y);
                    if (!near.same) {
                        if (!(definition.wake_nearby and near.near)) instance.active = false;
                    } else switch (instance.phase) {
                        .neutral => {
                            if (@rem(@as(i16, @bitCast(random.next())), definition.gesture_chance) == 0) instance.phase = .turning;
                        },
                        .turned => {
                            if (@rem(@as(i16, @bitCast(random.next())), definition.return_chance) == 0) instance.phase = .returning;
                        },
                        .turning => instance.phase = .turned,
                        .returning => instance.phase = .neutral,
                    }
                }
                instance.playback = .{};
                clip = definition.clips[@backingInt(instance.phase)];
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
            instance.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @backingInt(instance.phase), instance.playback.next_step, @intFromBool(instance.active), @intFromBool(instance.ready), @intFromBool(instance.pending) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
