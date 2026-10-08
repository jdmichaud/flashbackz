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

pub const Parcel = struct { idle: u16, using: u16, received: u16, signal: i16, grant_signal: i16, followup_parameter: u2, followup_signal: i16 };
pub fn parcel(group: rules.Group) ?Parcel {
    if (group.count() != 6) return null;
    const a = group.at(0);
    const b = group.at(1);
    const operations = [_][3]u8{ .{ 34, 72, 90 }, .{ 34, 90, 48 }, .{ 80, 0, 0 }, .{ 0, 0, 67 }, .{ 0, 0, 74 }, .{ 0, 0, 37 } };
    const next = [_]u16{ 4, 5, 0, 0, 0, 0 };
    for (operations, next, 0..) |codes, target, i| {
        const r = group.at(i);
        if (r.source != (if (i < 4) a.source else if (i == 4) a.target else b.target) or r.target != group.at(target).source or r.next != target or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        if (r.conditions[0].code != codes[0] or r.conditions[1].code != codes[1] or r.effect.code != codes[2]) return null;
    }
    if (a.conditions[0].argument != 102 or a.effect.argument != 33 or b.conditions[1].argument != 32 or b.effect.argument != 0 or group.at(2).conditions[0].argument != 7) return null;
    return .{ .idle = a.source, .using = a.target, .received = b.target, .signal = a.conditions[1].argument, .grant_signal = b.conditions[0].argument, .followup_parameter = 2, .followup_signal = group.at(5).effect.argument };
}

pub const Papers = struct { idle: u16, using: u16, starting: u16, signal: i16, grant_signal: i16 };
pub fn papers(group: rules.Group) ?Papers {
    if (group.count() != 6) return null;
    const a = group.at(0);
    const b = group.at(1);
    const operations = [_][3]u8{ .{ 34, 90, 48 }, .{ 34, 72, 0 }, .{ 80, 0, 0 }, .{ 0, 0, 67 }, .{ 0, 90, 74 }, .{ 0, 0, 48 } };
    const next = [_]u16{ 0, 4, 0, 0, 0, 0 };
    for (operations, next, 0..) |ops, target, i| {
        const row = group.at(i);
        if (row.target != group.at(target).source or row.next != target or row.dx != 0 or row.dy != 0 or row.flags != 0) return null;
        if (i < 4 and row.source != a.source or i == 4 and row.source != b.target) return null;
        if (row.conditions[0].code != ops[0] or row.conditions[1].code != ops[1] or row.effect.code != ops[2]) return null;
    }
    if (a.conditions[1].argument != 35 or a.effect.argument != 0 or b.conditions[0].argument != 102 or group.at(2).conditions[0].argument != 7 or group.at(4).conditions[1].argument != 43 or group.at(4).effect.argument != 0 or group.at(5).effect.argument != 0) return null;
    return .{ .idle = a.source, .using = b.target, .starting = group.at(5).source, .signal = b.conditions[1].argument, .grant_signal = a.conditions[0].argument };
}

pub const TerminalCard = struct { idle: u16, using: u16, signal: i16, grant_signal: i16, output_parameter: u2, granted: i16, consumed: i16 };
pub fn terminal(group: rules.Group) ?TerminalCard {
    if (group.count() != 4) return null;
    const codes = [_][3]u8{ .{ 34, 72, 90 }, .{ 34, 36, 48 }, .{ 0, 0, 67 }, .{ 0, 36, 74 } };
    for (codes, 0..) |ops, i| {
        const r = group.at(i);
        const next: u16 = if (i == 0) 3 else 0;
        if (r.source != group.at(if (i == 3) 3 else 0).source or r.target != group.at(next).source or r.next != next or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        for ([_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect }, ops) |op, code| if (op.code != code) return null;
    }
    if (group.at(0).conditions[0].argument != 102 or group.at(0).effect.argument != 46 or group.at(1).effect.argument != 0 or group.at(3).effect.argument != 0) return null;
    return .{ .idle = group.at(0).source, .using = group.at(3).source, .signal = group.at(0).conditions[1].argument, .grant_signal = group.at(1).conditions[0].argument, .output_parameter = 1, .granted = group.at(1).conditions[1].argument, .consumed = group.at(3).conditions[1].argument };
}

pub const Issued = struct { idle: u16, signal: i16, grant_signal: i16 };
pub fn issued(group: rules.Group) ?Issued {
    if (group.count() != 3) return null;
    const codes = [_][3]u8{ .{ 34, 48, 0 }, .{ 34, 72, 0 }, .{ 0, 0, 67 } };
    for (codes, 0..) |ops, i| {
        const row = group.at(i);
        if (row.source != group.at(0).source or row.target != row.source or row.next != 0 or row.dx != 0 or row.dy != 0 or row.flags != 0) return null;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, ops) |op, code| if (op.code != code) return null;
    }
    if (group.at(0).conditions[1].argument != 0 or group.at(1).conditions[0].argument != 102) return null;
    return .{ .idle = group.at(0).source, .grant_signal = group.at(0).conditions[0].argument, .signal = group.at(1).conditions[1].argument };
}
