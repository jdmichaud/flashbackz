//! Import complete inventory-gated exit families. Source object IDs become item kinds here.
const std = @import("std");
const runtime = @import("../level_exits.zig");
const rules = @import("rule_table.zig");
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, rule_bytes: []const u8, animations: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty) ![]runtime.Definition {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 0 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(rule_bytes, record.rule_group);
        if (group.count() != 4) continue;
        const a = group.at(0);
        const b = group.at(1);
        const c = group.at(2);
        const d = group.at(3);
        if (a.conditions[0].code != 80 or a.conditions[1].code != 131 or a.effect.code != 132) continue;
        if (a.conditions[0].argument != 1 or b.conditions[0].code != 77 or b.conditions[1].code != 0 or b.effect.code != 67 or c.conditions[0].code != 0 or c.conditions[1].code != 0 or c.effect.code != 0 or d.conditions[0].code != 0 or d.conditions[1].code != 0 or d.effect.code != 75) return error.UnsupportedInventoryExit;
        if (record.initial_state != a.source or b.source != a.source or c.source != a.source or b.target != a.source or c.target != a.source or d.source != a.target or d.target != a.target or a.next != 3 or b.next != 0 or c.next != 0 or d.next != 3) return error.UnsupportedInventoryExit;
        for ([_]rules.Rule{ a, b, c, d }) |rule| if (rule.dx != 0 or rule.dy != 0 or rule.flags != 0) return error.MovingInventoryExit;
        const item: @import("../equipment.zig").Kind = switch (a.conditions[1].argument) {
            10 => .anti_g_belt,
            else => return error.UnsupportedExitItem,
        };
        const destinations = [_]runtime.Destination{ .jungle, .city, .tower, .earth_city, .spaceport, .alien_surface, .alien_base };
        if (a.effect.argument < 1 or a.effect.argument > destinations.len) return error.InvalidExitDestination;
        var animation = try @import("animation.zig").decode(allocator, animations, a.source);
        defer animation.deinit();
        if (animation.frames.len == 0 or animation.sound != null) return error.UnsupportedExitAnimation;
        for (animation.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingInventoryExit,
        };
        table.register(@intCast(index), .level_exits);
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .required_item = item, .destination = destinations[@intCast(a.effect.argument - 1)], .cadence = @intCast(animation.frames.len), .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0 });
    }
    return definitions.toOwnedSlice(allocator);
}
