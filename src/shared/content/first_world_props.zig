//! Recover the holocube and its floor switch as item/visual/circuit definitions. Source
//! IDs and rule layouts stop here; the world owns ordinary objects and named effects.
const std = @import("std");
const placement = @import("placement.zig");
const animation = @import("animation.zig");
const equipment = @import("../equipment.zig");
const world = @import("../world_props.zig");
const geometry = @import("../geometry.zig");
const strings = @import("string_table.zig");

pub const Assets = struct {
    allocator: std.mem.Allocator,
    clips: [3]animation.OwnedClip,
    definitions: []world.Definition,
    item: equipment.Definition,
    hint_icon: @import("../motion.zig").VisualId,
    pub fn takeItem(self: *Assets) equipment.Definition {
        const item = self.item;
        self.item.label = &.{};
        return item;
    }
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        for (&self.clips) |*clip| clip.deinit();
        self.allocator.free(self.item.label);
        self.* = undefined;
    }
};
fn firstRule(bytes: []const u8, group: u16, state: u16) ![]const u8 {
    if (bytes.len < 2) return error.InvalidPropRules;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    const body = bytes[2..];
    if (count > 256 or group >= count or @as(usize, count) * 4 > body.len) return error.InvalidPropRules;
    const offset = std.mem.readInt(u32, body[@as(usize, group) * 4 ..][0..4], .little);
    if (offset < @as(usize, count) * 4 or offset > body.len or body.len - offset < 2) return error.InvalidPropRules;
    const records = body[offset..];
    const length = std.mem.readInt(u16, records[0..2], .little);
    if (@as(usize, length) * 18 > records.len - 2) return error.InvalidPropRules;
    for (0..length) |i| {
        const record = records[2 + i * 18 ..][0..18];
        if (std.mem.readInt(u16, record[0..2], .little) == state) return record;
    }
    return error.MissingPropRule;
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, animations: []const u8, rules: []const u8, names: []const u8, room_ids: *const [64]geometry.RoomId, item: equipment.ItemHandle, resolver: anytype) !Assets {
    const cube = try table.record(2);
    const plate = try table.record(3);
    if (cube.initial_state != 328 or cube.kind != 3 or cube.room >= 64 or cube.initially_active == 0 or cube.minimum_difficulty != 0 or cube.contact_icon != 1 or plate.initial_state != 307 or plate.kind != 7 or plate.room >= 64 or plate.initially_active == 0 or plate.parameters[0] != 4) return error.UnsupportedInitialProps;
    const pickup = try firstRule(rules, cube.rule_group, cube.initial_state);
    if (std.mem.readInt(u16, pickup[4..6], .little) != 315 or pickup[7] != 34 or pickup[6] != 90 or pickup[9] != 48 or std.mem.readInt(u16, pickup[12..14], .little) != 30 or std.mem.readInt(u16, pickup[14..16], .little) != 1 or std.mem.readInt(u16, pickup[16..18], .little) != 0) return error.UnsupportedPickupRule;
    const use = try firstRule(rules, cube.rule_group, 315);
    if (std.mem.readInt(u16, use[4..6], .little) != 315 or use[7] != 34 or use[6] != 90 or use[9] != 0 or std.mem.readInt(u16, use[12..14], .little) != 102 or std.mem.readInt(u16, use[14..16], .little) != 17) return error.UnsupportedItemUse;
    const press = try firstRule(rules, plate.rule_group, plate.initial_state);
    if (std.mem.readInt(u16, press[4..6], .little) != 306 or press[7] != 0 or press[6] != 61 or press[9] != 35 or std.mem.readInt(u16, press[16..18], .little) != 21) return error.UnsupportedFloorSwitch;
    var clips: [3]animation.OwnedClip = undefined;
    var loaded: usize = 0;
    errdefer for (clips[0..loaded]) |*clip| clip.deinit();
    for ([_]u16{ cube.initial_state, plate.initial_state, 306 }, 0..) |id, i| {
        var source = try animation.decode(allocator, animations, id);
        defer source.deinit();
        for (source.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |value| if (value.dx != 0 or value.dy != 0) return error.UnsupportedMovingProp,
        };
        clips[i] = try source.resolve(allocator, resolver);
        loaded += 1;
    }
    const icon = try resolver.icon(cube.inventory_icon);
    const hint = try resolver.icon(cube.contact_icon - 1);
    const definitions = try allocator.alloc(world.Definition, 2);
    errdefer allocator.free(definitions);
    const label = try strings.copy(allocator, names, cube.text_id);
    definitions[0..2].* = .{
        .{ .footprint = .{ .room = room_ids[cube.room], .position = cube.position, .width = cube.collision_width }, .facing = if (cube.facing_right != 0) .right else .left, .palette_bank = @intCast(cube.visual_flags & 3), .layer = if (cube.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .behavior = .{ .collectible = .{ .item = item, .idle = clips[0].clip(), .pickup_movie = .holocube_pickup } } },
        .{ .footprint = .{ .room = room_ids[plate.room], .position = plate.position, .width = plate.collision_width }, .facing = if (plate.facing_right != 0) .right else .left, .palette_bank = @intCast(plate.visual_flags & 3), .layer = if (plate.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .behavior = .{ .floor_switch = .{ .rest = clips[1].clip(), .press = clips[2].clip(), .circuit = @fromBackingInt(0) } } },
    };
    return .{ .allocator = allocator, .clips = clips, .definitions = definitions, .item = .{ .kind = .holocube, .icon = icon, .introduction_steps = null, .initial_quantity = cube.life, .label = label, .use_action = .{ .story = .holocube_recording } }, .hint_icon = hint };
}
