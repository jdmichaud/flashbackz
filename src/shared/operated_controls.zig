//! Player-operated controls own their animation and emit circuit pulses. Definitions
//! supply their destinations; no level-specific IDs or instruction stream run here.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const props = @import("world_props.zig");
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: props.Layer,
    idle: motion.Clip,
    pressed: motion.Clip,
    release_sound: ?motion.SoundId,
    circuit: props.CircuitId,
    initially_active: bool,
    wake_when_near: bool,
    hint: motion.VisualId,
    label: []const u8,
};
pub const Instance = struct {
    pose: motion.Pose,
    playback: motion.Playback = .{},
    pressed: bool = false,
    active: bool,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []props.CircuitId,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            if (definition.idle.steps.len == 0 or definition.pressed.steps.len == 0) return error.MissingControlAnimation;
            const visual = switch (definition.idle.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingControlVisual,
            };
            instance.* = .{ .active = definition.initially_active, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(props.CircuitId, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint) !void {
        self.candidate = null;
        const layout: contacts.Layout = .{};
        for (definitions, 0..) |definition, i| if (try layout.overlaps(map, player, definition.footprint)) {
            self.candidate = i;
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, map: geometry.Map, room: geometry.RoomId, operate: bool) !void {
        self.pulse_count = 0;
        const current = try map.room(room);
        for (self.instances, definitions, 0..) |*instance, definition, i| {
            instance.sound = null;
            const same_room = definition.footprint.room == room;
            if (definition.wake_when_near) {
                const above = current.edges.up == .room and current.edges.up.room == definition.footprint.room and definition.footprint.position.y >= 48;
                const below = current.edges.down == .room and current.edges.down.room == definition.footprint.room and definition.footprint.position.y >= 176;
                if (same_room or above or below) instance.active = true;
            }
            if (operate and self.candidate == i) instance.active = true;
            if (!instance.active) continue;
            var clip = if (instance.pressed) definition.pressed else definition.idle;
            if (operate and self.candidate == i and !instance.pressed) instance.playback.next_step = clip.steps.len;
            if (instance.playback.exhausted(clip)) {
                if (instance.pressed) {
                    instance.pressed = false;
                    instance.sound = definition.release_sound;
                } else if (!same_room) {
                    var nearby = false;
                    if (definition.wake_when_near) for ([_]geometry.Edge{ current.edges.left, current.edges.right, current.edges.up, current.edges.down }) |edge| {
                        if (edge == .room and edge.room == definition.footprint.room) nearby = true;
                    };
                    if (!nearby) instance.active = false;
                } else if (operate and self.candidate == i) {
                    instance.pressed = true;
                    self.pulses[self.pulse_count] = definition.circuit;
                    self.pulse_count += 1;
                }
                instance.playback = .{};
                clip = if (instance.pressed) definition.pressed else definition.idle;
            }
            // A contact message wakes the receiver and ends its current idle cycle.
            // The shared world submits it before this control's animation update.
            if (instance.sound == null) instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{ @intFromBool(instance.active), @intFromBool(instance.pressed), instance.playback.next_step, @backingInt(instance.pose.visual.id), @intFromBool(instance.pose.visual.mirrored) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        for (self.pulses[0..self.pulse_count]) |pulse| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, @backingInt(pulse))));
    }
};

test "an operated control interrupts idle, pulses its own circuit once and sounds on recovery" {
    const allocator = std.testing.allocator;
    const room: geometry.RoomId = @fromBackingInt(1);
    const cells: [48]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = room, .columns = 16, .rows = 3, .width = 256, .height = 224, .blocking = &cells, .edges = .{ .up = .blocked, .down = .blocked, .left = .blocked, .right = .blocked } }};
    const map: geometry.Map = .{ .rooms = &rooms };
    const steps = [_]motion.Step{ .{ .frame = .{ .visual = .{ .id = @fromBackingInt(1) } } }, .hold, .hold };
    var definitions: [2]Definition = undefined;
    for (&definitions, 0..) |*definition, i| definition.* = .{ .footprint = .{ .room = room, .position = .{ .x = @intCast(16 + i * 48), .y = 70 } }, .facing = .right, .palette_bank = 1, .layer = .behind_player, .idle = .{ .steps = &steps }, .pressed = .{ .steps = steps[0..1] }, .release_sound = @fromBackingInt(7), .circuit = @fromBackingInt(@as(u16, @intCast(20 + i))), .initially_active = true, .wake_when_near = true, .hint = @fromBackingInt(2), .label = "CONTROL" };
    var world = try World.init(allocator, &definitions);
    defer world.deinit();
    try world.prepare(&definitions, map, .{ .room = room, .position = .{ .x = 16, .y = 70 } });
    try world.advance(&definitions, map, room, false);
    try world.advance(&definitions, map, room, true);
    try std.testing.expect(world.instances[0].pressed and !world.instances[1].pressed);
    try std.testing.expectEqualSlices(props.CircuitId, &.{@fromBackingInt(20)}, world.pulses[0..world.pulse_count]);
    try world.advance(&definitions, map, room, false);
    try std.testing.expectEqual(@as(usize, 0), world.pulse_count);
    try std.testing.expectEqual(@as(?motion.SoundId, @fromBackingInt(7)), world.instances[0].sound);
    try std.testing.expect(!world.instances[0].pressed);
}
