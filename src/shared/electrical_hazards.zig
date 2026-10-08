//! Electrical hazards cycle, react to circuit signals and request a fatal interlude on
//! contact. Signal timing is content; no original object/script identifiers run here.
const std = @import("std");
const motion = @import("motion.zig");
const contacts = @import("contacts.zig");
const geometry = @import("geometry.zig");
const props = @import("world_props.zig");
pub const Phase = union(enum) { cycling: usize, contact, disabled };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: props.Layer,
    cycle: []const motion.Clip,
    contact: motion.Clip,
    disabled: motion.Clip,
    initial_phase: Phase,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Action = enum { enable, disable, wake };
pub const Binding = struct {
    circuit: props.CircuitId,
    target: usize,
    action: Action,
    next_step: bool,
};
const Requests = struct {
    wake: bool = false,
    enable: bool = false,
    disable: bool = false,
    fn add(self: *Requests, action: Action) void {
        self.wake = true;
        switch (action) {
            .enable => self.enable = true,
            .disable => self.disable = true,
            .wake => {},
        }
    }
};
pub const Instance = struct {
    pose: motion.Pose,
    phase: Phase,
    playback: motion.Playback = .{},
    active: bool,
    sound: ?motion.SoundId = null,
    requests: Requests = .{},
    pending: Requests = .{},
    fn clip(self: Instance, definition: Definition) motion.Clip {
        return switch (self.phase) {
            .cycling => |index| definition.cycle[index],
            .contact => definition.contact,
            .disabled => definition.disabled,
        };
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    defeat_requested: bool = false,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            if (definition.cycle.len == 0 or
                definition.contact.steps.len == 0 or
                definition.disabled.steps.len == 0) return error.MissingHazardAnimation;
            instance.* = .{
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{ .id = @fromBackingInt(0) },
                },
                .phase = definition.initial_phase,
                .active = definition.initially_active,
            };
            const clip = instance.clip(definition);
            if (clip.steps.len == 0) return error.MissingHazardAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingHazardVisual,
            };
            instance.pose.visual = .{
                .id = visual.id,
                .mirrored = visual.mirrored != (definition.facing == .left),
            };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        self.defeat_requested = false;
        for (self.instances) |*instance| {
            instance.requests = instance.pending;
            instance.pending = .{};
            instance.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const props.CircuitId) void {
        for (bindings) |binding| for (pulses) |pulse| if (binding.circuit == pulse) {
            const instance = &self.instances[binding.target];
            if (binding.next_step) instance.pending.add(binding.action) else instance.requests.add(binding.action);
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        room: geometry.RoomId,
        player: contacts.Footprint,
    ) !void {
        const current = try map.room(room);
        const layout: contacts.Layout = .{};
        for (self.instances, definitions) |*instance, definition| {
            const same_room = room == definition.footprint.room;
            var near = same_room;
            for ([_]geometry.Edge{
                current.edges.left,
                current.edges.right,
                current.edges.up,
                current.edges.down,
            }) |edge| if (edge == .room and edge.room == definition.footprint.room) {
                near = true;
            };
            if (definition.wake_nearby) {
                const above = current.edges.up == .room and
                    current.edges.up.room == definition.footprint.room and
                    definition.footprint.position.y >= 48;
                const below = current.edges.down == .room and
                    current.edges.down.room == definition.footprint.room and
                    definition.footprint.position.y >= 176;
                if (same_room or above or below) instance.active = true;
            }
            if (instance.requests.wake and
                (instance.active or
                    definition.accepts_signals)) instance.active = true else instance.requests = .{};
            if (!instance.active) continue;
            var clip = instance.clip(definition);
            const transitioned = instance.requests.wake or instance.playback.exhausted(clip);
            var audible_entry = transitioned;
            if (transitioned) {
                switch (instance.phase) {
                    .cycling => |index| {
                        if (instance.requests.disable) instance.phase = .disabled else if (try layout.overlaps(
                            map,
                            definition.footprint,
                            player,
                        )) instance.phase = .contact else {
                            instance.phase = .{ .cycling = (index + 1) % definition.cycle.len };
                            if (!same_room) audible_entry = false;
                            if (!same_room and
                                !(definition.wake_nearby and near)) instance.active = false;
                        }
                    },
                    .contact => {
                        self.defeat_requested = true;
                        instance.phase = .{ .cycling = 0 };
                    },
                    .disabled => {
                        // Re-enabling resumes the cycle silently; later running pulses sound.
                        audible_entry = false;
                        if (instance.requests.enable) instance.phase = .{ .cycling = 0 };
                        if (!same_room and
                            !(definition.wake_nearby and near)) instance.active = false;
                    },
                }
                instance.playback = .{};
                clip = instance.clip(definition);
            }
            instance.sound = if (audible_entry) instance.playback.soundOnEntry(clip) else null;
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        hash.update(&.{@intFromBool(self.defeat_requested)});
        for (self.instances) |instance| {
            for ([_]u64{
                @backingInt(std.meta.activeTag(instance.phase)),
                if (instance.phase == .cycling) instance.phase.cycling else 0,
                instance.playback.next_step,
                @intFromBool(instance.active),
                @backingInt(instance.pose.visual.id),
                @intFromBool(instance.pose.visual.mirrored),
            }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            for ([_]Requests{ instance.requests, instance.pending }) |request| hash.update(&.{
                @intFromBool(request.wake),
                @intFromBool(request.enable),
                @intFromBool(request.disable),
            });
        }
    }
};

test "delayed disable wins over contact, while reactivation starts a fresh cycle" {
    const allocator = std.testing.allocator;
    const room: geometry.RoomId = @fromBackingInt(1);
    const cells: [48]bool = @splat(false);
    const rooms = [_]geometry.Room{.{
        .id = room,
        .columns = 16,
        .rows = 3,
        .width = 256,
        .height = 216,
        .blocking = &cells,
        .edges = .{ .up = .blocked, .down = .blocked, .left = .blocked, .right = .blocked },
    }};
    const map: geometry.Map = .{ .rooms = &rooms };
    const frames = [_]motion.Step{
        .{ .frame = .{ .visual = .{ .id = @fromBackingInt(3) } } },
        .hold,
    };
    const cycles = [_]motion.Clip{.{ .steps = &frames, .sound = @fromBackingInt(17) }};
    const definitions = [_]Definition{.{
        .footprint = .{ .room = room, .position = .{ .x = 32, .y = 70 } },
        .facing = .right,
        .palette_bank = 1,
        .layer = .in_front_of_player,
        .cycle = &cycles,
        .contact = .{ .steps = frames[0..1] },
        .disabled = .{ .steps = frames[0..1] },
        .initial_phase = .{ .cycling = 0 },
        .initially_active = true,
        .wake_nearby = false,
        .accepts_signals = true,
    }};
    const bindings = [_]Binding{
        .{ .circuit = @fromBackingInt(1), .target = 0, .action = .disable, .next_step = true },
        .{ .circuit = @fromBackingInt(2), .target = 0, .action = .enable, .next_step = false },
    };
    const far: contacts.Footprint = .{ .room = room, .position = .{ .x = 128, .y = 70 } };
    const touching = definitions[0].footprint;
    var world = try World.init(allocator, &definitions);
    defer world.deinit();
    world.beginStep();
    try world.advance(&definitions, map, room, far);
    try std.testing.expect(world.instances[0].sound == null);
    world.beginStep();
    world.route(&bindings, &.{@fromBackingInt(1)});
    try world.advance(&definitions, map, room, far);
    try std.testing.expect(world.instances[0].phase == .cycling);
    world.beginStep();
    try world.advance(&definitions, map, room, touching);
    try std.testing.expect(world.instances[0].phase == .disabled);
    try std.testing.expect(!world.defeat_requested);
    world.beginStep();
    world.route(&bindings, &.{@fromBackingInt(2)});
    try world.advance(&definitions, map, room, touching);
    try std.testing.expect(world.instances[0].phase == .cycling);
    try std.testing.expectEqual(@as(usize, 1), world.instances[0].playback.next_step);
    try std.testing.expect(world.instances[0].sound == null);
    world.beginStep();
    try world.advance(&definitions, map, room, touching);
    world.beginStep();
    try world.advance(&definitions, map, room, touching);
    try std.testing.expect(world.instances[0].phase == .contact);
    try std.testing.expect(!world.defeat_requested);
    world.beginStep();
    try world.advance(&definitions, map, room, touching);
    try std.testing.expect(world.defeat_requested);
}
