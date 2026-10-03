//! Recover the jungle's starting supplies into named definitions. Source states and
//! instruction numbers are checked here and never dispatched by the equipment system.
const std = @import("std");
const equipment = @import("../equipment.zig");
const placement = @import("placement.zig");
const animation = @import("animation.zig");

pub fn recover(allocator: std.mem.Allocator, placements: placement.Table, animations: []const u8, rules: []const u8, resolver: anytype) ![]equipment.Definition {
    const Spec = struct { kind: equipment.Kind, index: u16, state: u16, target: u16, operations: [3]u8 };
    // Ascending source activation order determines simultaneous item-arrival order. The
    // result contains semantic kinds, resolved icons and durations, not source entity IDs.
    const specs = [_]Spec{
        .{ .kind = .gun, .index = 1, .state = 327, .target = 314, .operations = .{ 0, 0, 48 } },
        .{ .kind = .shield, .index = 48, .state = 322, .target = 321, .operations = .{ 89, 0, 48 } },
        .{ .kind = .credits, .index = 65, .state = 329, .target = 330, .operations = .{ 0, 48, 67 } },
    };
    const definitions = try allocator.alloc(equipment.Definition, specs.len);
    errdefer allocator.free(definitions);
    for (specs, definitions) |spec, *definition| {
        const source = try placements.record(spec.index);
        if (source.initial_state != spec.state or source.kind != 3 or source.minimum_difficulty != 0 or source.initially_active == 0)
            return error.UnsupportedStartingEquipment;
        const rule = try firstRule(rules, source.rule_group, source.initial_state);
        if (rule[2] != 0 or rule[3] != 0 or rule[8] != 0 or word(rule, 4) != spec.target or
            !std.mem.eql(u8, &.{ rule[7], rule[6], rule[9] }, &spec.operations) or
            word(rule, 12) != 0 or word(rule, 14) != 0 or word(rule, 16) != 0)
            return error.UnsupportedStartingEquipmentRule;
        var introduction = try animation.decode(allocator, animations, source.initial_state);
        defer introduction.deinit();
        if (introduction.sound != null or introduction.header_metadata != 0) return error.UnsupportedEquipmentIntroduction;
        for (introduction.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |value| if (value.dx != 0 or value.dy != 0) return error.UnsupportedEquipmentIntroduction,
        };
        definition.* = .{
            .kind = spec.kind,
            .icon = try resolver.icon(source.inventory_icon),
            .introduction_steps = @intCast(introduction.frames.len),
            .initial_quantity = source.life,
        };
    }
    return definitions;
}

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn firstRule(bytes: []const u8, group: u16, state: u16) ![]const u8 {
    if (bytes.len < 2) return error.InvalidEquipmentRules;
    const count = word(bytes, 0);
    const body = bytes[2..];
    if (count > 256 or @as(usize, count) * 4 > body.len or group >= count) return error.InvalidEquipmentRules;
    const offset = std.mem.readInt(u32, body[@as(usize, group) * 4 ..][0..4], .little);
    if (offset < @as(usize, count) * 4 or offset > body.len or body.len - offset < 2) return error.InvalidEquipmentRules;
    const records = body[offset..];
    const length = word(records, 0);
    if (@as(usize, length) * 18 > records.len - 2) return error.InvalidEquipmentRules;
    for (0..length) |i| {
        const record = records[2 + i * 18 ..][0..18];
        if (word(record, 0) == state) return record;
    }
    return error.MissingEquipmentRule;
}

test "rule recovery checks the directory and searches the requested initial state" {
    var bytes: [44]u8 = @splat(0);
    bytes[0..8].* = .{ 1, 0, 4, 0, 0, 0, 2, 0 };
    bytes[8] = 7;
    bytes[26] = 9;
    try std.testing.expectEqual(@as(u8, 9), (try firstRule(&bytes, 0, 9))[0]);
    try std.testing.expectError(error.MissingEquipmentRule, firstRule(&bytes, 0, 8));
    try std.testing.expectError(error.InvalidEquipmentRules, firstRule(bytes[0..43], 0, 9));
    bytes[2] = 1;
    try std.testing.expectError(error.InvalidEquipmentRules, firstRule(&bytes, 0, 9));
}
