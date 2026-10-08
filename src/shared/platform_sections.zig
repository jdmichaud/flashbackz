//! Circuit-revealed floor sections. Appearance and solid support are separate authored
//! boundaries, so a cinematic can expose a bridge before its next collision update.
const std = @import("std");
const geometry = @import("geometry.zig");
const motion = @import("motion.zig");
const terrain = @import("terrain.zig");
pub const Definition = struct {
    footprint: @import("contacts.zig").Footprint,
    facing: motion.Facing,
    span: terrain.Span,
    idle: motion.Clip,
    initially_present: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    palette_bank: u4,
    behind_player: bool,
};
pub const Binding = struct {
    circuit: @import("world_props.zig").CircuitId,
    target: usize,
    next_step: bool,
};
pub const Instance = struct {
    pose: motion.Pose,
    playback: motion.Playback = .{},
    present: bool,
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
            if (definition.idle.steps.len == 0) return error.MissingPlatformSectionAnimation;
            const visual = switch (definition.idle.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingPlatformSectionVisual,
            };
            instance.* = .{
                .present = definition.initially_present,
                .active = definition.initially_active,
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
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
        pulses: []const @import("world_props.zig").CircuitId,
    ) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        world: *terrain.State,
        room: geometry.RoomId,
    ) !void {
        for (self.instances, definitions) |*instance, definition| {
            const near = try @import("activation.zig").around(
                world.map(),
                room,
                definition.footprint.room,
                definition.footprint.position.y,
            );
            if (instance.present and definition.wake_nearby and near.wake) instance.active = true;
            var appeared = false;
            if (instance.ready and (instance.active or definition.accepts_signals)) {
                instance.active = true;
                if (!instance.present) {
                    instance.present = true;
                    instance.playback = .{};
                    appeared = true;
                }
            }
            if (!instance.active or !instance.present) continue;
            if (!appeared and instance.playback.exhausted(definition.idle)) {
                _ = try world.replace(definition.span, .solid);
                if (!near.same and !(definition.wake_nearby and near.near)) instance.active = false;
                instance.playback = .{};
            }
            instance.sound = instance.playback.soundOnEntry(definition.idle);
            _ = instance.playback.advance(definition.idle, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            hash.update(&.{
                @intFromBool(instance.present),
                @intFromBool(instance.active),
                @intFromBool(instance.ready),
                @intFromBool(instance.pending),
            });
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, instance.playback.next_step)));
        }
    }
};
