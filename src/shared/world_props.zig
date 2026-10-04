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
        collectible: struct { item: equipment.ItemHandle, idle: motion.Clip, pickup_movie: ?Movie = null },
        floor_switch: struct { rest: motion.Clip, press: motion.Clip, circuit: CircuitId },
    },
};
pub const Object = struct {
    pose: motion.Pose,
    playback: motion.Playback = .{},
    pressing: bool = false,
    contact_present: bool = false,
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
            object.* = .{ .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) } } };
        }
        return .{ .allocator = allocator, .definitions = definitions, .objects = objects, .pressed_circuits = try allocator.alloc(CircuitId, definitions.len) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.objects);
        self.allocator.free(self.pressed_circuits);
        self.* = undefined;
    }
    pub fn visible(self: *const World, index: usize, items: *const equipment.Loadout) !bool {
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
            object.contact_present = try self.visible(index, items);
            if (object.contact_present and definition.behavior == .collectible) {
                var footprint = definition.footprint;
                footprint.position = object.pose.position;
                if (try layout.overlaps(map, player, footprint)) self.pickup_candidate = definition.behavior.collectible.item;
            }
        }
    }
    pub fn advance(self: *World, map: geometry.Map, items: *equipment.Loadout, player_has_weight: bool, pickup: bool) !void {
        self.pressed_count = 0;
        self.acquired = null;
        self.movie = null;
        const layout: contacts.Layout = .{};
        for (self.objects, self.definitions, 0..) |*object, definition, index| switch (definition.behavior) {
            .collectible => |item| {
                if (pickup and self.pickup_candidate != null and self.pickup_candidate.?.eql(item.item) and (try items.item(item.item)).state == .available) {
                    try items.acquire(item.item);
                    self.acquired = item.item;
                    self.movie = item.pickup_movie;
                } else if (try self.visible(index, items)) {
                    if (object.playback.exhausted(item.idle)) object.playback = .{};
                    _ = object.playback.advance(item.idle, &object.pose);
                }
            },
            .floor_switch => |plate| {
                var clip = if (object.pressing) plate.press else plate.rest;
                if (object.playback.exhausted(clip)) {
                    if (object.pressing) object.pressing = false else {
                        var occupied = player_has_weight and try layout.overlaps(map, definition.footprint, self.player_contact);
                        for (self.objects, self.definitions, 0..) |other, other_definition, j| {
                            if (j == index or !other.contact_present) continue;
                            const other_clip = switch (other_definition.behavior) {
                                .collectible => |value| value.idle,
                                .floor_switch => |value| if (other.pressing) value.press else value.rest,
                            };
                            if (other_clip.presses_floor_switches and try layout.overlaps(map, definition.footprint, other_definition.footprint)) occupied = true;
                        }
                        if (!occupied) continue;
                        object.pressing = true;
                        self.pressed_circuits[self.pressed_count] = plate.circuit;
                        self.pressed_count += 1;
                    }
                    object.playback = .{};
                    clip = if (object.pressing) plate.press else plate.rest;
                }
                _ = object.playback.advance(clip, &object.pose);
            },
        };
    }
    pub fn hashInto(self: *const World, hash: *std.hash.Wyhash) void {
        for (self.objects) |object| {
            for ([_]u64{ @as(u16, @bitCast(object.pose.position.x)), @as(u16, @bitCast(object.pose.position.y)), @backingInt(object.pose.facing), @backingInt(object.pose.visual.id), @intFromBool(object.pose.visual.mirrored), object.playback.next_step, @intFromBool(object.pressing), @intFromBool(object.contact_present) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
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
