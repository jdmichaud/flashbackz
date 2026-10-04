//! Consumable keys are recognized from pickup, credential check and removal paths.
const rules = @import("rule_table.zig");
pub const Spec = struct { idle: u16, using: u16, signal: i16 };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 5) return null;
    const take = group.at(0);
    const use = group.at(1);
    const contact = group.at(2);
    const sleep = group.at(3);
    const remove = group.at(4);
    for ([_]rules.Rule{ take, use, contact, sleep, remove }) |r| if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (take.source != take.target or use.source != take.source or use.target == take.source or contact.source != take.source or contact.target != take.source or sleep.source != take.source or sleep.target != take.source or remove.source != use.target or remove.target != take.source) return null;
    if (take.next != 0 or use.next != 4 or contact.next != 0 or sleep.next != 0 or remove.next != 0) return null;
    if (!op(take.conditions[0], 34, 30) or !op(take.conditions[1], 90, 2) or !op(take.effect, 48, 0)) return null;
    if (!op(use.conditions[0], 34, 102) or use.conditions[1].code != 72 or !op(use.effect, 0, 0)) return null;
    if (!op(contact.conditions[0], 80, 7) or !op(contact.conditions[1], 0, 0) or !op(contact.effect, 0, 0)) return null;
    if (!op(sleep.conditions[0], 0, 0) or !op(sleep.conditions[1], 0, 0) or !op(sleep.effect, 67, 0)) return null;
    // Scene 3 is unassigned in the English floppy movie directory.
    if (!op(remove.conditions[0], 90, 3) or !op(remove.conditions[1], 0, 0) or !op(remove.effect, 74, 0)) return null;
    return .{ .idle = take.source, .using = use.target, .signal = use.conditions[1].argument };
}
