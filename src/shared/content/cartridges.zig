//! Recover rechargeable, consumable cartridges from their complete item rule family.
const rules = @import("rule_table.zig");
pub const Spec = struct { idle: u16, using: u16, charging: u16, signal: i16, charge: i16 };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 7) return null;
    var r: [7]rules.Rule = undefined;
    const next = [_]u16{ 0, 5, 6, 0, 0, 0, 0 };
    for (&r, next, 0..) |*row, destination, i| {
        row.* = group.at(i);
        if (row.dx != 0 or row.dy != 0 or row.flags != 0 or row.next != destination or row.target != group.at(destination).source) return null;
    }
    for (1..5) |i| if (r[i].source != r[0].source) return null;
    if (!op(r[0].conditions[0], 34, 30) or !op(r[0].conditions[1], 90, 15) or !op(r[0].effect, 48, 0)) return null;
    if (!op(r[1].conditions[0], 34, 102) or r[1].conditions[1].code != 72 or !op(r[1].effect, 90, 20)) return null;
    if (!op(r[2].conditions[0], 34, 102) or !op(r[2].conditions[1], 84, 9) or !op(r[2].effect, 90, 14)) return null;
    if (!op(r[3].conditions[0], 80, 7) or r[3].conditions[1].code != 0 or r[3].effect.code != 0) return null;
    if (r[4].conditions[0].code != 0 or r[4].conditions[1].code != 0 or r[4].effect.code != 67) return null;
    if (r[5].conditions[0].code != 0 or r[5].conditions[1].code != 0 or !op(r[5].effect, 74, 0)) return null;
    if (r[6].conditions[0].code != 0 or r[6].conditions[1].code != 0 or r[6].effect.code != 85) return null;
    return .{ .idle = r[0].source, .using = r[5].source, .charging = r[6].source, .signal = r[1].conditions[1].argument, .charge = r[6].effect.argument };
}
