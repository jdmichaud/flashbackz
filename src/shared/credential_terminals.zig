//! A terminal explains its required card and relays an accepted credential to its circuits.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = world_props.CircuitId;
const world_messages = @import("world_messages.zig");
const world_props = @import("world_props.zig");
pub const Definition = struct { footprint: contacts.Footprint, clip: motion.Clip, outputs: [2]Circuit, notice: world_messages.Id, hint: motion.VisualId, label: []const u8, priority: u16, initially_active: bool, accepts_signals: bool };
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const Instance = struct {
    active: bool,
    playback: motion.Playback = .{},
    ready: bool = false,
    pending: bool = false,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    notice: ?world_messages.Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (
            instances,
            definitions,
        ) |*instance, definition| instance.* = .{ .active = definition.initially_active };
        return .{
            .allocator = allocator,
            .instances = instances,
            .pulses = try allocator.alloc(Circuit, definitions.len * 2),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
    ) !void {
        self.pulse_count = 0;
        self.notice = null;
        self.candidate = null;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.ready = instance.pending;
            instance.pending = false;
            if (try layout.overlaps(map, definition.footprint, player)) self.candidate = index;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| if (binding.circuit == pulse) {
            if (binding.next_step) self.instances[binding.target].pending = true else self.instances[binding.target].ready = true;
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        bindings: []const Binding,
        talk: bool,
    ) void {
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            const speaking = talk and self.candidate == index;
            if ((instance.ready or speaking) and definition.accepts_signals) {
                instance.active = true;
                instance.playback.next_step = definition.clip.steps.len;
            }
            if (!instance.active) continue;
            if (instance.playback.exhausted(definition.clip)) {
                if (instance.ready) {
                    for (definition.outputs) |circuit| {
                        self.pulses[self.pulse_count] = circuit;
                        self.pulse_count += 1;
                        self.route(bindings, &.{circuit});
                    }
                } else if (speaking) {
                    self.notice = .{
                        .message = definition.notice,
                        .icon = definition.hint,
                        .priority = definition.priority,
                    };
                } else instance.active = false;
                instance.playback = .{};
            }
            instance.playback.next_step += 1;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @intFromBool(instance.active),
            instance.playback.next_step,
            @intFromBool(instance.ready),
            @intFromBool(instance.pending),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
