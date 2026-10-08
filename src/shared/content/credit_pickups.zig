//! A loose quantity grant: accumulate into the referenced purse, play its pickup movie,
//! and remove the ground item. Source identifiers stop at this compatibility boundary.
const rules = @import("rule_table.zig");
pub const Spec = struct { idle: u16, target_parameter: u2, amount_parameter: u2 };
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 4) return null;
    const sleep = group.at(0);
    const take = group.at(1);
    const idle = group.at(2);
    const remove = group.at(3);
    for ([_]rules.Rule{
        sleep,
        take,
        idle,
        remove,
    }) |r| if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (sleep.source != sleep.target or
        idle.source != sleep.source or
        idle.target != sleep.source or
        take.source != sleep.source or
        take.target != remove.source or
        remove.target != remove.source) return null;
    if (sleep.conditions[0].code != 77 or
        sleep.conditions[1].code != 0 or
        sleep.effect.code != 67) return null;
    if (take.conditions[0].code != 34 or
        take.conditions[0].argument != 30 or
        take.conditions[1].code != 101 or
        take.effect.code != 90 or
        take.effect.argument != 10) return null;
    if (idle.conditions[0].code != 0 or
        idle.conditions[1].code != 0 or
        idle.effect.code != 0 or
        remove.conditions[0].code != 0 or
        remove.conditions[1].code != 0 or
        remove.effect.code != 75) return null;
    if (sleep.next != 0 or idle.next != 0 or take.next != 3 or remove.next != 3) return null;
    const parameter = take.conditions[1].argument;
    if (parameter < 0 or parameter > 2) return null;
    return .{
        .idle = sleep.source,
        .target_parameter = @intCast(parameter),
        .amount_parameter = @intCast(parameter + 1),
    };
}
