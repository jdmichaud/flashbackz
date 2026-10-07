//! Inventory credentials introduced directly at level start, or issued by a service.
const rules = @import("rule_table.zig");
pub const Card = struct { signal: i16, using: u16 };
pub fn starting(group: rules.Group) ?Card {
    if (group.count() != 4) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    for (0..4) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    }
    if (a.target != b.source or c.source != b.source or c.target != b.source or d.source != b.target or d.target != b.target or a.next != 1 or b.next != 3 or c.next != 1 or d.next != 3) return null;
    if (a.conditions[0].code != 48 or a.conditions[0].argument != 0 or a.conditions[1].code != 0 or a.effect.code != 67) return null;
    if (b.conditions[0].code != 34 or b.conditions[0].argument != 102 or b.conditions[1].code != 72 or b.effect.code != 90 or b.effect.argument != 43) return null;
    if (c.conditions[0].code != 0 or c.conditions[1].code != 0 or c.effect.code != 67 or d.conditions[0].code != 0 or d.conditions[1].code != 0 or d.effect.code != 74 or d.effect.argument != 0) return null;
    return .{ .signal = b.conditions[1].argument, .using = b.target };
}
pub fn permit(group: rules.Group) ?Card {
    if (group.count() != 7) return null;
    const a = group.at(0);
    const b = group.at(1);
    if (a.source != a.target or b.source != a.source or b.target == a.source or a.next != 0 or b.next != 4) return null;
    if (a.conditions[0].code != 34 or a.conditions[0].argument != 20 or a.conditions[1].code != 90 or a.conditions[1].argument != 34 or a.effect.code != 48 or a.effect.argument != 0) return null;
    if (b.conditions[0].code != 34 or b.conditions[0].argument != 102 or b.conditions[1].code != 72 or b.effect.code != 0) return null;
    for (0..7) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    }
    const contact = group.at(2);
    const sleep = group.at(3);
    const finish = group.at(4);
    if (contact.source != a.source or contact.target != a.source or contact.next != 0 or contact.conditions[0].code != 80 or contact.conditions[0].argument != 7 or contact.conditions[1].code != 0 or contact.effect.code != 0) return null;
    if (sleep.source != a.source or sleep.target != a.source or sleep.next != 0 or sleep.conditions[0].code != 0 or sleep.conditions[1].code != 0 or sleep.effect.code != 67) return null;
    if (finish.source != b.target or finish.target != a.source or finish.next != 0 or finish.conditions[0].code != 0 or finish.conditions[1].code != 0 or finish.effect.code != 0) return null;
    for (5..7) |i| {
        const r = group.at(i);
        if (r.target != a.source or r.next != 0 or r.conditions[0].code != 0 or r.effect.code != 48 or r.effect.argument != 0) return null;
        if (i == 5 and r.conditions[1].code != 0 or i == 6 and (r.conditions[1].code != 90 or r.conditions[1].argument != 34)) return null;
    }
    return .{ .signal = b.conditions[1].argument, .using = b.target };
}
