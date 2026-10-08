//! The carried purse offers payment to a contact whose requested value it can cover.
const rules = @import("rule_table.zig");
pub fn signal(group: rules.Group) ?i16 {
    if (group.count() != 3) return null;
    const intro = group.at(0);
    const use = group.at(1);
    const idle = group.at(2);
    for ([_]rules.Rule{ intro, use, idle }) |r| if (r.dx != 0 or
        r.dy != 0 or
        r.flags != 0 or
        r.next != 1 or
        r.target != use.source) return null;
    if (intro.conditions[0].code != 0 or
        intro.conditions[1].code != 48 or
        intro.conditions[1].argument != 0 or
        intro.effect.code != 67) return null;
    if (use.conditions[0].code != 34 or
        use.conditions[0].argument != 102 or
        use.conditions[1].code != 108 or
        use.effect.code != 0) return null;
    if (idle.source != use.source or
        idle.conditions[0].code != 0 or
        idle.conditions[1].code != 0 or
        idle.effect.code != 67) return null;
    return use.conditions[1].argument;
}
