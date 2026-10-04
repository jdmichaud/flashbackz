//! Small world-object systems with shared contacts and stable item references. Content
//! defines placement, art, pickup policy and switch circuits; no source scripts run here.
const std = @import("std");
const geometry = @import("geometry.zig");
const motion = @import("motion.zig");
const contacts = @import("contacts.zig");
const equipment = @import("equipment.zig");
pub const Movie = @import("story_cue.zig").Cue;
pub const CircuitId = enum(u16) { _ };
pub const Layer = enum { behind_player, in_front_of_player };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: Layer,
    behavior: union(enum) {
        collectible: struct { item: equipment.ItemHandle, idle: motion.Clip, pickup_movie: ?Movie = null, throw_motion: ?@import("thrown_item.zig").Definition = null, quantity_grant: ?struct { target: equipment.ItemHandle, amount: i16 } = null, initially_active: bool = true, wake_nearby: bool = false },
        floor_switch: struct { rest: motion.Clip, press: motion.Clip, circuit: CircuitId, accepts_objects: bool = true, initially_active: bool = true, wake_on_contact: bool = true, sleep_after_press: bool = false },
    },
};
pub const Object = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    contact: contacts.Footprint,
    flight: ?@import("thrown_item.zig").State = null,
    lost: bool = false,
    playback: motion.Playback = .{},
    pressing: bool = false,
    active: bool = true,
    contact_present: bool = false,
    sound_requested: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    definitions: []const Definition,
    objects: []Object,
    player_contact: contacts.Footprint = undefined,
    pickup_candidate: ?equipment.ItemHandle = null,
    pressed_circuits: []CircuitId,
    pressed_count: usize = 0,
    acquired: ?equipment.ItemHandle = null,
    movie: ?Movie = null,

    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const objects = try allocator.alloc(Object, definitions.len);
        errdefer allocator.free(objects);
        for (objects, definitions) |*object, definition| {
            const clip = switch (definition.behavior) {
                .collectible => |value| value.idle,
                .floor_switch => |value| value.rest,
            };
            if (clip.steps.len == 0) return error.MissingPropAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingPropVisual,
            };
            object.* = .{ .room = definition.footprint.room, .contact = definition.footprint, .active = switch (definition.behavior) {
                .floor_switch => |plate| plate.initially_active,
                .collectible => |item| item.initially_active,
            }, .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        return .{ .allocator = allocator, .definitions = definitions, .objects = objects, .pressed_circuits = try allocator.alloc(CircuitId, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.objects);
        self.allocator.free(self.pressed_circuits);
        self.* = undefined;
    }
    pub fn visible(self: *const World, index: usize, items: *const equipment.Loadout) !bool {
        if (self.objects[index].lost) return false;
        return switch (self.definitions[index].behavior) {
            .collectible => |value| (try items.item(value.item)).state == .available,
            .floor_switch => true,
        };
    }
    /// Contact positions are sampled before actor motion. They remain valid for this
    /// update even when an item is collected later in the same update.
    pub fn prepare(self: *World, map: geometry.Map, items: *const equipment.Loadout, player: contacts.Footprint) !void {
        self.player_contact = player;
        self.pickup_candidate = null;
        const layout: contacts.Layout = .{};
        for (self.objects, self.definitions, 0..) |*object, definition, index| {
            object.contact = definition.footprint;
            object.contact.room = object.room;
            object.contact.position = object.pose.position;
            object.contact_present = try self.visible(index, items);
            if (definition.behavior == .collectible) {
                const item = definition.behavior.collectible;
                if (!object.contact_present) object.active = false else if (item.wake_nearby) {
                    const near = try @import("activation.zig").around(map, player.room, object.room, object.pose.position.y);
                    if (near.wake) object.active = true;
                    if (!near.near and object.flight == null) object.active = false;
                }
            }
            if (object.contact_present and object.flight == null and definition.behavior == .collectible) {
                if (try layout.overlaps(map, player, object.contact)) self.pickup_candidate = definition.behavior.collectible.item;
            }
        }
        for (self.objects, self.definitions, 0..) |*object, definition, index| {
            if (definition.behavior != .floor_switch or !definition.behavior.floor_switch.wake_on_contact) continue;
            if (try layout.overlaps(map, player, definition.footprint)) object.active = true;
            for (self.objects, 0..) |other, j| {
                if (j == index or !other.active or !other.contact_present) continue;
                if (try layout.overlaps(map, definition.footprint, other.contact)) object.active = true;
            }
        }
    }
    pub fn advance(self: *World, map: geometry.Map, items: *equipment.Loadout, player_has_weight: bool, pickup: bool) !void {
        for (self.objects) |*object| object.sound_requested = null;
        self.pressed_count = 0;
        self.acquired = null;
        self.movie = null;
        const layout: contacts.Layout = .{};
        for (self.objects, self.definitions, 0..) |*object, definition, index| switch (definition.behavior) {
            .collectible => |item| {
                if (pickup and self.pickup_candidate != null and self.pickup_candidate.?.eql(item.item) and (try items.item(item.item)).state == .available) {
                    if (item.quantity_grant) |grant| {
                        try items.consumeInto(item.item, grant.target, grant.amount);
                        self.acquired = grant.target;
                    } else {
                        try items.acquire(item.item);
                        self.acquired = item.item;
                    }
                    self.movie = item.pickup_movie;
                } else if (object.active and try self.visible(index, items)) {
                    if (object.flight) |*flight| {
                        const event = try flight.advance(item.throw_motion orelse return error.MissingThrowMotion, &object.playback, &object.pose, &object.room, map);
                        object.sound_requested = event.sound;
                        object.lost = event.lost;
                        if (event.settled) object.flight = null;
                        continue;
                    }
                    if (object.playback.exhausted(item.idle)) object.playback = .{};
                    object.sound_requested = object.playback.soundOnEntry(item.idle);
                    _ = object.playback.advance(item.idle, &object.pose);
                }
            },
            .floor_switch => |plate| {
                if (!object.active) continue;
                var clip = if (object.pressing) plate.press else plate.rest;
                if (object.playback.exhausted(clip)) {
                    if (object.pressing) {
                        object.pressing = false;
                        if (plate.sleep_after_press) object.active = false;
                    } else {
                        var occupied = player_has_weight and try layout.overlaps(map, definition.footprint, self.player_contact);
                        if (plate.accepts_objects) for (self.objects, self.definitions, 0..) |other, other_definition, j| {
                            if (j == index or !other.contact_present) continue;
                            const other_clip = switch (other_definition.behavior) {
                                .collectible => |value| value.idle,
                                .floor_switch => |value| if (other.pressing) value.press else value.rest,
                            };
                            if (other_clip.presses_floor_switches and try layout.overlaps(map, object.contact, other.contact)) occupied = true;
                        };
                        if (!occupied) {
                            object.active = false;
                            continue;
                        }
                        object.pressing = true;
                        self.pressed_circuits[self.pressed_count] = plate.circuit;
                        self.pressed_count += 1;
                    }
                    object.playback = .{};
                    clip = if (object.pressing) plate.press else plate.rest;
                }
                object.sound_requested = object.playback.soundOnEntry(clip);
                _ = object.playback.advance(clip, &object.pose);
            },
        };
    }
    pub fn throwItem(self: *World, items: *equipment.Loadout, handle: equipment.ItemHandle, pose: motion.Pose, room: geometry.RoomId) !void {
        for (self.objects, self.definitions) |*object, definition| {
            if (definition.behavior != .collectible or !definition.behavior.collectible.item.eql(handle)) continue;
            if (definition.behavior.collectible.throw_motion == null) return error.MissingThrowMotion;
            try items.release(handle);
            object.pose.position = pose.position;
            object.pose.facing = pose.facing;
            object.room = room;
            object.flight = .{};
            object.active = true;
            object.playback = .{};
            object.lost = false;
            return;
        }
        return error.MissingThrownItem;
    }

    pub fn hashInto(self: *const World, hash: *std.hash.Wyhash) void {
        for (self.objects) |object| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, @backingInt(object.room))));
            hash.update(&.{ @intFromBool(object.lost), @intFromBool(object.flight != null) });
            if (object.flight) |flight| {
                hash.update(&.{@backingInt(std.meta.activeTag(flight.phase))});
                const segment: u64 = switch (flight.phase) {
                    .arc, .rebound => |i| i,
                    else => 0,
                };
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, segment)));
            }
            for ([_]u64{ @as(u16, @bitCast(object.pose.position.x)), @as(u16, @bitCast(object.pose.position.y)), @backingInt(object.pose.facing), @backingInt(object.pose.visual.id), @intFromBool(object.pose.visual.mirrored), object.playback.next_step, @intFromBool(object.pressing), @intFromBool(object.active), @intFromBool(object.contact_present) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        }
    }
};

test "pickup transfers once and preserves contacts for the rest of the update" {
    const allocator = std.testing.allocator;
    const room: geometry.RoomId = @fromBackingInt(1);
    const solid: [16]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = room, .width = 256, .height = 224, .columns = 4, .rows = 4, .blocking = &solid, .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked } }};
    const map: geometry.Map = .{ .rooms = &rooms };
    const steps = [_]motion.Step{.{ .frame = .{ .visual = .{ .id = @fromBackingInt(1) } } }};
    const clip: motion.Clip = .{ .steps = &steps, .presses_floor_switches = true };
    const handle: equipment.ItemHandle = .{ .index = 0, .generation = 1 };
    const definitions = [_]Definition{
        .{ .footprint = .{ .room = room, .position = .{ .x = 32, .y = 70 } }, .facing = .right, .palette_bank = 2, .layer = .in_front_of_player, .behavior = .{ .collectible = .{ .item = handle, .idle = clip, .pickup_movie = .holocube_pickup } } },
        .{ .footprint = .{ .room = room, .position = .{ .x = 32, .y = 70 } }, .facing = .right, .palette_bank = 2, .layer = .behind_player, .behavior = .{ .floor_switch = .{ .rest = clip, .press = clip, .circuit = @fromBackingInt(3) } } },
    };
    const items = [_]equipment.Definition{.{ .kind = .holocube, .icon = @fromBackingInt(4), .introduction_steps = null, .initial_quantity = 1 }};
    var loadout = try equipment.Loadout.init(allocator, &items);
    defer loadout.deinit();
    var world = try World.init(allocator, &definitions);
    defer world.deinit();
    const player: contacts.Footprint = .{ .room = room, .position = .{ .x = 32, .y = 70 } };
    try world.prepare(map, &loadout, player);
    try world.advance(map, &loadout, false, false);
    try world.prepare(map, &loadout, player);
    try world.advance(map, &loadout, false, true);
    try std.testing.expectEqual(@as(usize, 1), loadout.inventory.items().len);
    try std.testing.expectEqual(Movie.holocube_pickup, world.movie.?);
    try std.testing.expectEqual(@as(usize, 1), world.pressed_count);
    try std.testing.expect(!try world.visible(0, &loadout));
    try world.prepare(map, &loadout, player);
    try world.advance(map, &loadout, false, true);
    try std.testing.expectEqual(@as(usize, 1), loadout.inventory.items().len);
    try std.testing.expect(world.acquired == null and world.movie == null);
    try std.testing.expect(world.pickup_candidate == null);
}
