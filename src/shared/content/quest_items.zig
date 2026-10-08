//! Reactive item families: an offered teleporter waits for acknowledgement; a granted
//! card appears at its authored location and remains reusable after ordinary lock use.
const std = @import("std");
const rules = @import("rule_table.zig");
const first_world_props = @import("first_world_props.zig");
const placement = @import("placement.zig");
const world_props = @import("../world_props.zig");
pub const Teleporter = struct { idle: u16, carried: u16, signal: i16, acknowledgement: i16 };
pub const Card = struct {
    hidden: u16,
    idle: u16,
    using: u16,
    signal: i16,
    reveal: i16,
    room_parameter: u2,
};
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn teleporter(group: rules.Group) ?Teleporter {
    if (group.count() != 7) return null;
    const a = group.at(0);
    const carried = a.target;
    for (0..7) |i| {
        const r = group.at(i);
        if (r.dx != 0 or
            r.dy != 0 or
            r.flags != 0 or
            r.source != (if (i < 4) a.source else carried) or
            r.target != (if (i == 0 or i >= 4) carried else a.source) or
            r.next != (if (i == 0 or i >= 4) @as(
                u16,
                4,
            ) else 0)) return null;
    }
    if (!op(
        a.conditions[0],
        34,
        30,
    ) or !op(a.conditions[1], 90, 16) or !op(a.effect, 48, 0)) return null;
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    const e = group.at(4);
    const f = group.at(5);
    const g = group.at(6);
    if (!op(
        b.conditions[0],
        115,
        8,
    ) or b.conditions[1].code != 67 or b.effect.code != 0) return null;
    if (c.conditions[0].code != 0 or c.conditions[1].code != 0 or c.effect.code != 0 or !op(
        d.conditions[0],
        77,
        0,
    ) or d.conditions[1].code != 0 or d.effect.code != 67) return null;
    if (e.conditions[0].code != 34 or !op(
        e.conditions[1],
        90,
        21,
    ) or !op(e.effect, 74, 0)) return null;
    if (!op(
        f.conditions[0],
        34,
        102,
    ) or
        f.conditions[1].code != 72 or
        f.effect.code != 0 or
        g.conditions[0].code != 0 or
        g.conditions[1].code != 0 or
        g.effect.code != 67) return null;
    return .{
        .idle = a.source,
        .carried = carried,
        .signal = f.conditions[1].argument,
        .acknowledgement = e.conditions[0].argument,
    };
}
pub fn card(group: rules.Group) ?Card {
    if (group.count() != 7) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    const e = group.at(4);
    const f = group.at(5);
    const g = group.at(6);
    for (0..7) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    }
    if (a.source != b.source or
        b.target != a.source or
        a.target != c.source or
        c.target != c.source or
        d.source != c.source or
        e.source != c.source or
        e.target != c.source or
        f.source != c.source or
        f.target != c.source or
        g.source != d.target or
        g.target != c.source) return null;
    if (a.next != 2 or
        b.next != 0 or
        c.next != 2 or
        d.next != 6 or
        e.next != 2 or
        f.next != 2 or
        g.next != 2) return null;
    if (a.conditions[0].code != 34 or
        a.conditions[1].code != 0 or
        a.effect.code != 87 or
        a.effect.argument < 0 or
        a.effect.argument > 3 or
        b.conditions[0].code != 0 or
        b.conditions[1].code != 0 or
        b.effect.code != 67) return null;
    if (!op(
        c.conditions[0],
        34,
        30,
    ) or !op(c.conditions[1], 90, 18) or !op(c.effect, 48, 0)) return null;
    if (!op(
        d.conditions[0],
        34,
        102,
    ) or d.conditions[1].code != 72 or d.effect.code != 0) return null;
    if (!op(
        e.conditions[0],
        80,
        7,
    ) or
        e.conditions[1].code != 0 or
        e.effect.code != 0 or
        f.conditions[0].code != 0 or
        f.conditions[1].code != 0 or
        f.effect.code != 67) return null;
    // The use scene is explicitly unassigned in the supplied English movie directory.
    if (!op(
        g.conditions[0],
        90,
        19,
    ) or g.conditions[1].code != 0 or g.effect.code != 67) return null;
    return .{
        .hidden = a.source,
        .idle = c.source,
        .using = d.target,
        .signal = d.conditions[1].argument,
        .reveal = a.conditions[0].argument,
        .room_parameter = @intCast(a.effect.argument),
    };
}
pub fn bindings(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    objects: first_world_props.Assets,
    first_item: u16,
    routes: []const first_world_props.Connection,
) ![]world_props.ItemBinding {
    var result: std.ArrayList(world_props.ItemBinding) = .empty;
    errdefer result.deinit(allocator);
    for (objects.definitions, 0..) |definition, index| {
        if (definition.behavior != .collectible) continue;
        const source = objects.item_sources[definition.behavior.collectible.item.index - first_item];
        const record = try table.record(source);
        const group = try rules.group(rule_bytes, record.rule_group);
        const gift = card(group);
        const device = teleporter(group);
        if (gift == null and device == null) continue;
        const message = if (gift) |value| value.reveal else device.?.acknowledgement;
        for (routes) |route| if (route.recipient == source and route.message == message) {
            try result.append(
                allocator,
                .{
                    .circuit = route.circuit,
                    .target = index,
                    .response = if (gift != null) .reveal else .{ .redeem = .teleporter_delivery },
                    .next_step = route.sender >= source,
                },
            );
        };
    }
    return result.toOwnedSlice(allocator);
}
