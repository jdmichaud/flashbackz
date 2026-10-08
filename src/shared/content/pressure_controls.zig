//! Recognize pressure controls by their full contact/press/recovery rule topology.
const rules = @import("rule_table.zig");
const std = @import("std");
pub const Spec = struct {
    rest: u16,
    pressed: u16,
    player_only: bool,
    target_parameter: u2,
    message: i16,
    sleep_after_press: bool,
};
fn noop(operation: rules.Operation) bool {
    return operation.code == 0;
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 5) return null;
    const first = group.at(0);
    const sensor = first.conditions[1].code;
    if (sensor != 60 and sensor != 61) return null;
    if (first.effect.code < 35 or
        first.effect.code > 38 or
        first.target == first.source) return null;
    for ([_]i16{ 0, 1, 5 }, 0..) |weight, i| {
        const row = group.at(i);
        if (row.source != first.source or
            row.target != first.target or
            row.next != 4 or
            !noop(row.conditions[0]) or
            row.conditions[1].code != sensor or
            row.conditions[1].argument != weight or
            row.effect.code != first.effect.code or
            row.effect.argument != first.effect.argument) return null;
        // The second predicate reads the first argument as a contact-kind filter.
        if (sensor == 60 and row.conditions[0].argument != 1) return null;
    }
    const empty = group.at(3);
    const recovery = group.at(4);
    if (empty.source != first.source or
        empty.target != first.source or
        empty.next != 0 or
        !noop(empty.conditions[0]) or
        !noop(empty.conditions[1]) or
        empty.effect.code != 67) return null;
    if (recovery.source != first.target or
        recovery.target != first.source or
        recovery.next != 0 or
        !noop(recovery.conditions[0]) or
        !noop(recovery.conditions[1]) or
        (recovery.effect.code != 0 and recovery.effect.code != 67)) return null;
    for (0..5) |i| {
        const row = group.at(i);
        if (row.dx != 0 or row.dy != 0 or row.flags != 0) return null;
    }
    return .{
        .rest = first.source,
        .pressed = first.target,
        .player_only = sensor == 60,
        .target_parameter = @intCast(first.effect.code - 35),
        .message = first.effect.argument,
        .sleep_after_press = recovery.effect.code == 67,
    };
}

test "pressure recognition preserves player-only filtering and parameter-selected outputs" {
    var records: [90]u8 = @splat(0);
    for (0..5) |i| {
        const at = i * 18;
        std.mem.writeInt(u16, records[at..][0..2], if (i == 4) 80 else 50, .little);
        std.mem.writeInt(u16, records[at + 4 ..][0..2], if (i < 3) 80 else 50, .little);
        if (i < 3) {
            records[at + 6] = 60;
            records[at + 12] = 1;
            records[at + 14] = ([_]u8{ 0, 1, 5 })[i];
            records[at + 9] = 37;
            records[at + 16] = 23;
            records[at + 10] = 4;
        } else records[at + 9] = 67;
    }
    const group: rules.Group = .{ .records = &records };
    const spec = recognize(group).?;
    try std.testing.expect(spec.player_only and spec.sleep_after_press);
    try std.testing.expectEqual(@as(u2, 2), spec.target_parameter);
    records[12] = 5;
    try std.testing.expect(recognize(group) == null);
    for (0..3) |i| records[i * 18 + 6] = 61;
    try std.testing.expect(!recognize(group).?.player_only);
}
