//! Compile the throwable family into named trajectory stages and terrain responses.
//! Source states are followed only here; the simulation owns no rule interpreter.
const std = @import("std");
const table = @import("rule_table.zig");
const animation = @import("animation.zig");
const motion = @import("../motion.zig");
const thrown = @import("../thrown_item.zig");
const Branches = struct {
    group: table.Group,
    start: usize,
    count: usize,
    fn at(self: Branches, index: usize) table.Rule {
        return self.group.at(self.start + index);
    }
};
fn branches(group: table.Group, state: u16) !Branches {
    for (0..group.count()) |i| if (group.at(i).source == state) {
        var end = i + 1;
        while (end < group.count() and group.at(end).source == state) : (end += 1) {}
        return .{ .group = group, .start = i, .count = end - i };
    };
    return error.MissingThrowState;
}
fn plain(rule: table.Rule, operation: u8, argument: i16) bool {
    return rule.conditions[0].code == operation and
        (operation == 0 or rule.conditions[0].argument == argument) and
        rule.conditions[1].code == 0 and
        rule.effect.code == 0 and
        rule.flags == 0 and
        rule.dx == 0;
}
fn resolve(
    allocator: std.mem.Allocator,
    owned: *std.ArrayList(animation.OwnedClip),
    data: []const u8,
    state: u16,
    resolver: anytype,
) !motion.Clip {
    var source = try animation.decode(allocator, data, state);
    defer source.deinit();
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try owned.append(allocator, clip);
    return clip.clip();
}
pub fn load(
    allocator: std.mem.Allocator,
    group: table.Group,
    ground: u16,
    carried: u16,
    data: []const u8,
    owned: *std.ArrayList(animation.OwnedClip),
    resolver: anytype,
) !thrown.Definition {
    const held = try branches(group, carried);
    var launch: ?u16 = null;
    for (0..held.count) |i| {
        const rule = held.at(i);
        if (rule.conditions[0].code == 34 and
            rule.conditions[0].argument == 100 and
            rule.effect.code == 49) launch = rule.target;
    }
    var stages: std.ArrayList(thrown.Stage) = .empty;
    errdefer stages.deinit(allocator);
    var current = launch orelse return error.MissingThrowEntry;
    var drop_start: ?u16 = null;
    var edge_drop: ?u16 = null;
    var falling: ?u16 = null;
    var fall_down: i16 = 0;
    while (current != ground) {
        if (stages.items.len == 32) return error.ThrowArcCycle;
        const state = try branches(group, current);
        const fallback = state.at(state.count - 1);
        if (!plain(fallback, 0, 0) or fallback.dy != 0) return error.UnsupportedThrowContinuation;
        var stage: thrown.Stage = .{
            .clip = try resolve(allocator, owned, data, current, resolver),
            .finish = if (fallback.target == ground) .settle else .next,
        };
        for (0..state.count - 1) |i| {
            const condition = state.at(i);
            if (condition.dy != 0) return error.UnsupportedThrowBranch;
            if (plain(condition, 15, 0)) {
                const bounce = try branches(group, condition.target);
                const settle = bounce.at(bounce.count - 1);
                if (!plain(
                    settle,
                    0,
                    0,
                ) or
                    settle.dy != 0 or
                    settle.target != ground or
                    bounce.count > 2) return error.UnsupportedThrowRebound;
                if (bounce.count == 2) {
                    const drop = bounce.at(0);
                    if (!plain(drop, 27, 0)) return error.UnsupportedThrowRebound;
                    if (falling != null and
                        (falling.? != drop.target or
                            fall_down != drop.dy)) return error.InconsistentThrowFall;
                    falling = drop.target;
                    fall_down = drop.dy;
                }
                stage.rebound = .{
                    .clip = try resolve(allocator, owned, data, condition.target, resolver),
                    .may_fall = bounce.count == 2,
                };
            } else if (plain(condition, 27, 0)) {
                drop_start = condition.target;
                stage.finish = .drop_or_next;
            } else if (plain(condition, 26, 1)) {
                edge_drop = condition.target;
                stage.finish = .edge_or_next;
            } else return error.UnsupportedThrowBranch;
        }
        try stages.append(allocator, stage);
        current = fallback.target;
    }
    const dropping = try branches(group, drop_start orelse return error.MissingThrowDrop);
    if (dropping.count != 2 or !plain(
        dropping.at(0),
        15,
        0,
    ) or !plain(dropping.at(1), 0, 0)) return error.UnsupportedThrowDrop;
    const continuing = dropping.at(1).target;
    const rebound = dropping.at(0).target;
    const fall_state = falling orelse return error.MissingThrowFall;
    const fall = try branches(group, fall_state);
    if (fall.count != 2 or !plain(
        fall.at(0),
        27,
        0,
    ) or fall.at(0).target != fall_state or fall.at(0).dy != fall_down or !plain(
        fall.at(1),
        0,
        0,
    )) return error.UnsupportedThrowFall;
    const landing = fall.at(1).target;
    const land = try branches(group, landing);
    if (land.count != 1 or !plain(
        land.at(0),
        0,
        0,
    ) or land.at(0).target != ground) return error.UnsupportedThrowLanding;
    for (
        [_]u16{ continuing, rebound, edge_drop orelse return error.MissingThrowEdge },
        0..,
    ) |state, i| {
        const end = try branches(group, state);
        if (end.count != 2 or !plain(
            end.at(0),
            27,
            0,
        ) or end.at(0).target != fall_state or end.at(0).dy != fall_down or !plain(
            end.at(1),
            0,
            0,
        ) or
            end.at(1).target != (if (i == 2) ground else landing)) return error.UnsupportedThrowDescent;
    }
    // Resolve before transferring the arc allocation so failures retain simple ownership.
    const drop_clip = try resolve(allocator, owned, data, drop_start.?, resolver);
    const continuing_clip = try resolve(allocator, owned, data, continuing, resolver);
    const rebound_clip = try resolve(allocator, owned, data, rebound, resolver);
    const edge_clip = try resolve(allocator, owned, data, edge_drop.?, resolver);
    const falling_clip = try resolve(allocator, owned, data, fall_state, resolver);
    const landing_clip = try resolve(allocator, owned, data, landing, resolver);
    const resting_clip = try resolve(allocator, owned, data, ground, resolver);
    return .{
        .arc = try stages.toOwnedSlice(allocator),
        .drop_start = drop_clip,
        .drop_continue = continuing_clip,
        .drop_rebound = rebound_clip,
        .edge_descent = edge_clip,
        .falling = falling_clip,
        .landing = landing_clip,
        .rest = resting_clip,
        .fall_entry_down = fall_down,
    };
}
