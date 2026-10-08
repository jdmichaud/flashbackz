//! Recover conversational quest actors into idle presentations and explicit exchanges.
const std = @import("std");
const rules = @import("rule_table.zig");
const runtime = @import("../quest_contacts.zig");
const animation = @import("animation.zig");
const routes = @import("first_world_props.zig");
const credit_wallet = @import("credit_wallet.zig");
const equipment = @import("../equipment.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
const string_table = @import("string_table.zig");
const world_props = @import("../world_props.zig");
const Output = struct { parameter: u2, signal: i16 };
pub const Spec = struct {
    speech: ?[3]u16 = null,
    reply_notice: ?i16 = null,
    after_chances: ?[4]i16 = null,
    release_unless_chance: bool = false,
    talking_forward: [4]i16 = @splat(0),
    disappear_after_leaving: bool = false,
    finish_gestures_offscreen: bool = false,
    dismiss_when_acknowledged: bool = false,
    reveal_outputs: [2]?Output = @splat(null),
    role: runtime.Role,
    kind: u8,
    cycle: @FieldType(runtime.Definition, "cycle"),
    idle: [4]u16,
    after: [4]u16,
    hidden: ?struct { state: u16, parameter: u2, signal: i16 } = null,
    receive: ?i16 = null,
    notice: i16,
    chances: [4]i16,
    offscreen_choice_first: [4]bool = @splat(false),
    outputs: [2]?Output = @splat(null),
    departure_outputs: [2]?Output = @splat(null),
    sale: ?struct { signal: i16, purse_parameter: u2 } = null,
};
fn codes(r: rules.Rule, expected: [3]u8) bool {
    return r.conditions[0].code == expected[0] and
        r.conditions[1].code == expected[1] and
        r.effect.code == expected[2];
}
fn simple(group: rules.Group) bool {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.dx != 0 or
            r.dy != 0 or
            r.flags != 0 or
            r.next >= group.count() or
            r.target != group.at(r.next).source) return false;
    }
    return true;
}
fn seatedGuest(group: rules.Group) ?Spec {
    if (group.count() != 70) return null;
    const sources = [_]usize{
        0,
        0,
        0,
        0,
        0,
        5,
        6,
        7,
        8,
        8,
        10,
        10,
        10,
        13,
        13,
        15,
        15,
        15,
        15,
        19,
        19,
        21,
        21,
        21,
        24,
        24,
    };
    const next = [_]u16{
        5,
        0,
        0,
        8,
        0,
        7,
        7,
        15,
        5,
        10,
        5,
        10,
        13,
        5,
        0,
        15,
        6,
        19,
        15,
        6,
        21,
        6,
        21,
        24,
        6,
        15,
    };
    const ops = [_][3]u8{
        .{ 34, 0, 35 },
        .{ 34, 37, 87 },
        .{ 77, 0, 67 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 123 },
        .{ 0, 0, 123 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 0, 0, 0 },
        .{ 77, 0, 75 },
        .{ 34, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 0 },
        .{ 0, 0, 0 },
    };
    for (sources, next, ops, 0..) |source, target, operations, i| {
        const row = group.at(i);
        if (row.source != group.at(source).source or
            row.target != group.at(target).source or
            row.next != target or
            row.dy != 0 or
            row.flags != 0 or
            !codes(
                row,
                operations,
            )) return null;
        const shifts = i == 8 or i == 10 or i == 19 or i == 21;
        if (row.dx != (if (shifts) group.at(8).dx else 0)) return null;
        if (row.conditions[0].code == 34 and
            i != 1 and
            row.conditions[0].argument != 30) return null;
    }
    // This conversation subgraph cannot reach the family's decorative civilian variants.
    // Ambient-person import handles those placements independently; the audit records both.
    for (26..group.count()) |i| for (sources) |source| if (group.at(i).source == group.at(source).source) return null;
    if (group.at(5).effect.argument < 0 or
        group.at(6).effect.argument < 0 or
        group.at(1).effect.argument < 0 or
        group.at(1).effect.argument > 3 or
        group.at(11).conditions[0].argument != group.at(22).conditions[0].argument) return null;
    return .{
        .role = .giver,
        .kind = 3,
        .cycle = .alternating,
        .idle = .{
            group.at(0).source,
            group.at(8).source,
            group.at(10).source,
            group.at(13).source,
        },
        .after = .{
            group.at(15).source,
            group.at(19).source,
            group.at(21).source,
            group.at(24).source,
        },
        .hidden = .{
            .state = group.at(1).source,
            .parameter = @intCast(group.at(1).effect.argument),
            .signal = group.at(1).conditions[0].argument,
        },
        .notice = group.at(5).effect.argument,
        .reply_notice = group.at(6).effect.argument,
        .speech = .{ group.at(5).source, group.at(6).source, group.at(7).source },
        .chances = .{
            group.at(3).conditions[0].argument,
            0,
            0,
            group.at(11).conditions[0].argument,
        },
        .after_chances = .{
            group.at(17).conditions[0].argument,
            0,
            0,
            group.at(22).conditions[0].argument,
        },
        .release_unless_chance = true,
        .talking_forward = .{ 0, -@as(i16, group.at(8).dx), -@as(i16, group.at(10).dx), 0 },
        .disappear_after_leaving = true,
        .finish_gestures_offscreen = true,
        .outputs = .{ .{ .parameter = 0, .signal = group.at(0).effect.argument }, null },
        .reveal_outputs = .{
            .{ .parameter = 2, .signal = group.at(1).conditions[1].argument },
            null,
        },
    };
}
pub fn recognize(group: rules.Group) ?Spec {
    if (seatedGuest(group)) |spec| return spec;
    if (!simple(group)) return null;
    if (group.count() == 8) {
        const reveal = group.at(0);
        const talk = group.at(1);
        const done = group.at(4);
        const reply = group.at(5);
        const sources = [_]usize{ 0, 0, 0, 0, 4, 4, 4, 4 };
        const next = [_]u16{ 0, 4, 0, 0, 4, 4, 4, 4 };
        const ops = [_][3]u8{
            .{ 34, 0, 87 },
            .{ 34, 123, 35 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 34, 36, 75 },
            .{ 34, 123, 0 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
        };
        for (sources, next, ops, 0..) |source, target, operations, i| {
            const row = group.at(i);
            if (row.source != group.at(source).source or row.next != target or !codes(
                row,
                operations,
            )) return null;
        }
        if (talk.conditions[0].argument != 30 or
            reply.conditions[0].argument != 30 or
            talk.conditions[1].argument < 0 or
            reply.conditions[1].argument < 0 or
            reveal.effect.argument < 0 or
            reveal.effect.argument > 3) return null;
        return .{
            .role = .giver,
            .kind = 3,
            .cycle = .stationary,
            .idle = @splat(reveal.source),
            .after = @splat(done.source),
            .hidden = .{
                .state = reveal.source,
                .parameter = @intCast(reveal.effect.argument),
                .signal = reveal.conditions[0].argument,
            },
            .receive = done.conditions[0].argument,
            .notice = talk.conditions[1].argument,
            .reply_notice = reply.conditions[1].argument,
            .chances = @splat(0),
            .outputs = .{ .{ .parameter = 0, .signal = talk.effect.argument }, null },
            .departure_outputs = .{
                .{ .parameter = 1, .signal = done.conditions[1].argument },
                null,
            },
            .dismiss_when_acknowledged = true,
        };
    }
    if (group.count() == 5) {
        const reveal = group.at(0);
        const talk = group.at(1);
        const sleep = group.at(2);
        const idle = group.at(3);
        const leave = group.at(4);
        if (!codes(
            reveal,
            .{ 34, 0, 87 },
        ) or !codes(
            talk,
            .{ 34, 123, 36 },
        ) or !codes(
            sleep,
            .{ 77, 0, 67 },
        ) or !codes(idle, .{ 0, 0, 0 }) or !codes(leave, .{ 35, 0, 75 })) return null;
        if (reveal.source != reveal.target or
            talk.source != reveal.source or
            sleep.source != reveal.source or
            idle.source != reveal.source or
            leave.source != talk.target or
            reveal.next != 0 or
            talk.next != 4 or
            sleep.next != 0 or
            idle.next != 0 or
            leave.next != 0) return null;
        if (reveal.effect.argument < 0 or
            reveal.effect.argument > 3 or
            talk.conditions[0].argument != 30 or
            talk.conditions[1].argument < 0 or
            sleep.conditions[0].argument != 0) return null;
        return .{
            .role = .introducer,
            .kind = 3,
            .cycle = .stationary,
            .idle = @splat(reveal.source),
            .after = @splat(talk.target),
            .hidden = .{
                .state = reveal.source,
                .parameter = @intCast(reveal.effect.argument),
                .signal = reveal.conditions[0].argument,
            },
            .notice = talk.conditions[1].argument,
            .chances = @splat(0),
            .outputs = .{ .{ .parameter = 1, .signal = talk.effect.argument }, null },
            .departure_outputs = .{
                .{ .parameter = 0, .signal = leave.conditions[0].argument },
                null,
            },
        };
    }
    if (group.count() == 7) {
        const reveal = group.at(0);
        const payment = group.at(3);
        const talk = group.at(4);
        const operations = [_][3]u8{
            .{ 34, 0, 87 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 34, 102, 38 },
            .{ 34, 0, 123 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
        };
        for (operations, 0..) |ops, i| {
            const row = group.at(i);
            const state = if (i < 3) reveal.source else reveal.target;
            if (row.source != state or row.next != (if (i == 0 or i >= 3) @as(
                u16,
                3,
            ) else 0) or !codes(
                row,
                ops,
            )) return null;
        }
        if (reveal.effect.argument < 0 or
            reveal.effect.argument > 3 or
            payment.conditions[1].argument < 0 or
            payment.conditions[1].argument > 2 or
            talk.conditions[0].argument != 30 or
            talk.effect.argument < 0) return null;
        return .{
            .role = .seller,
            .kind = 3,
            .cycle = .stationary,
            .idle = @splat(reveal.target),
            .after = @splat(reveal.target),
            .hidden = .{
                .state = reveal.source,
                .parameter = @intCast(reveal.effect.argument),
                .signal = reveal.conditions[0].argument,
            },
            .notice = talk.effect.argument,
            .chances = @splat(0),
            .outputs = .{ .{ .parameter = 3, .signal = payment.effect.argument }, null },
            .sale = .{
                .signal = payment.conditions[0].argument,
                .purse_parameter = @intCast(payment.conditions[1].argument),
            },
        };
    }
    if (group.count() == 26) {
        const sources = [_]usize{
            0,
            0,
            0,
            0,
            4,
            4,
            4,
            7,
            7,
            7,
            7,
            11,
            11,
            11,
            14,
            14,
            14,
            17,
            17,
            19,
            19,
            19,
            22,
            22,
            24,
            24,
        };
        const next = [_]u16{
            14,
            0,
            4,
            0,
            17,
            4,
            7,
            19,
            7,
            11,
            7,
            22,
            11,
            0,
            14,
            17,
            14,
            17,
            19,
            19,
            22,
            19,
            22,
            14,
            0,
            24,
        };
        const operations = [_][3]u8{
            .{ 34, 123, 35 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 34, 123, 35 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 34, 123, 35 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 34, 123, 35 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 34, 87, 0 },
            .{ 0, 0, 0 },
        };
        for (sources, next, operations, 0..) |source, target, ops, i| {
            const r = group.at(i);
            if (r.source != group.at(source).source or r.next != target or !codes(
                r,
                ops,
            )) return null;
        }
        const talk = group.at(0);
        const reveal = group.at(24);
        for ([_]usize{ 0, 4, 7, 11 }) |i| {
            const r = group.at(i);
            if (r.conditions[0].argument != 30 or
                r.conditions[1].argument != talk.conditions[1].argument or
                r.effect.argument != talk.effect.argument) return null;
        }
        if (reveal.conditions[1].argument < 0 or
            reveal.conditions[1].argument > 3 or
            talk.conditions[1].argument < 0) return null;
        if (group.at(2).conditions[0].argument != group.at(15).conditions[0].argument or
            group.at(9).conditions[0].argument != group.at(20).conditions[0].argument) return null;
        return .{
            .role = .giver,
            .kind = 3,
            .cycle = .alternating,
            .idle = .{
                group.at(0).source,
                group.at(4).source,
                group.at(7).source,
                group.at(11).source,
            },
            .after = .{
                group.at(14).source,
                group.at(17).source,
                group.at(19).source,
                group.at(22).source,
            },
            .hidden = .{
                .state = reveal.source,
                .parameter = @intCast(reveal.conditions[1].argument),
                .signal = reveal.conditions[0].argument,
            },
            .notice = talk.conditions[1].argument,
            .chances = .{
                group.at(2).conditions[0].argument,
                0,
                0,
                group.at(9).conditions[0].argument,
            },
            .outputs = .{ .{ .parameter = 0, .signal = talk.effect.argument }, null },
        };
    }
    if (group.count() == 19) {
        const sources = [_]usize{ 0, 0, 0, 0, 0, 5, 5, 5, 5, 5, 5, 11, 11, 11, 11, 11, 16, 17, 18 };
        const next = [_]u16{ 16, 0, 5, 0, 0, 17, 5, 5, 11, 0, 5, 18, 11, 11, 5, 11, 16, 17, 18 };
        const operations = [_][3]u8{
            .{ 34, 35, 36 },
            .{ 34, 0, 123 },
            .{ 97, 0, 0 },
            .{ 77, 0, 67 },
            .{ 0, 0, 0 },
            .{ 34, 35, 36 },
            .{ 34, 0, 123 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 34, 35, 36 },
            .{ 34, 0, 123 },
            .{ 77, 0, 67 },
            .{ 97, 0, 0 },
            .{ 0, 0, 0 },
            .{ 0, 0, 75 },
            .{ 0, 0, 75 },
            .{ 0, 0, 75 },
        };
        for (sources, next, operations, 0..) |source, target, ops, i| {
            const r = group.at(i);
            if (r.source != group.at(source).source or r.next != target or !codes(
                r,
                ops,
            )) return null;
        }
        const accept = group.at(0);
        const talk = group.at(1);
        for ([_]usize{ 0, 5, 11 }) |i| {
            const r = group.at(i);
            if (r.conditions[0].argument != accept.conditions[0].argument or
                r.conditions[1].argument != accept.conditions[1].argument or
                r.effect.argument != accept.effect.argument) return null;
        }
        for ([_]usize{
            1,
            6,
            12,
        }) |i| if (group.at(i).conditions[0].argument != 30 or
            group.at(i).effect.argument != talk.effect.argument) return null;
        if (talk.effect.argument < 0) return null;
        return .{
            .role = .recipient,
            .kind = 5,
            .cycle = .three_poses,
            .idle = .{
                group.at(0).source,
                group.at(5).source,
                group.at(11).source,
                group.at(0).source,
            },
            .after = .{
                group.at(16).source,
                group.at(17).source,
                group.at(18).source,
                group.at(16).source,
            },
            .receive = accept.conditions[0].argument,
            .notice = talk.effect.argument,
            .chances = .{
                group.at(2).conditions[0].argument,
                group.at(8).conditions[0].argument,
                group.at(9).conditions[0].argument,
                group.at(14).conditions[0].argument,
            },
            .offscreen_choice_first = .{ true, false, false, false },
            .outputs = .{
                .{ .parameter = 0, .signal = accept.conditions[1].argument },
                .{ .parameter = 1, .signal = accept.effect.argument },
            },
        };
    }
    const hidden = group.count() == 16;
    if (group.count() != 13 and !hidden) return null;
    const conditional_notice = group.at(0).conditions[1].code == 123;
    const notice = if (conditional_notice) group.at(0).conditions[1].argument else group.at(0).effect.argument;
    if (notice < 0) return null;
    const starts = [_]usize{ 0, 4, 9 };
    for (starts, 0..) |start, phase| {
        const count: usize = if (phase == 1) 5 else 4;
        for (0..count) |slot| {
            const r = group.at(start + slot);
            const random_first = hidden and phase == 0;
            const sleep_slot: usize = if (random_first) 2 else 1;
            const random_slot: usize = if (random_first) 1 else 2;
            const chance = slot == random_slot or phase == 1 and slot == 3;
            const target: usize = if (chance) (if (phase == 1) (if (slot == 2) 9 else 0) else 4) else start;
            const expected: [3]u8 = if (slot == 0) (if (conditional_notice) [3]u8{
                34,
                123,
                0,
            } else [3]u8{
                34,
                0,
                123,
            }) else if (slot == sleep_slot) .{
                77,
                0,
                67,
            } else if (chance) .{ 97, 0, 0 } else .{ 0, 0, 0 };
            if (r.source != group.at(start).source or r.next != target or !codes(
                r,
                expected,
            )) return null;
        }
        if (group.at(start).conditions[0].argument != 30 or
            (if (conditional_notice) group.at(start).conditions[1].argument else group.at(start).effect.argument) != notice) return null;
    }
    var reveal: @FieldType(Spec, "hidden") = null;
    if (hidden) {
        const a = group.at(13);
        const b = group.at(14);
        const c = group.at(15);
        if (!codes(
            a,
            .{ 34, 87, 0 },
        ) or !codes(
            b,
            .{ 77, 0, 67 },
        ) or !codes(
            c,
            .{ 0, 0, 0 },
        ) or
            a.next != 0 or
            b.next != 13 or
            c.next != 13 or
            b.source != a.source or
            c.source != a.source or
            a.conditions[1].argument < 0 or
            a.conditions[1].argument > 3) return null;
        reveal = .{
            .state = a.source,
            .parameter = @intCast(a.conditions[1].argument),
            .signal = a.conditions[0].argument,
        };
    }
    const poses = [4]u16{
        group.at(0).source,
        group.at(4).source,
        group.at(9).source,
        group.at(0).source,
    };
    return .{
        .role = .conversation,
        .kind = 3,
        .cycle = .three_poses,
        .idle = poses,
        .after = poses,
        .hidden = reveal,
        .notice = notice,
        .chances = .{
            group.at(if (hidden) 1 else 2).conditions[0].argument,
            group.at(6).conditions[0].argument,
            group.at(7).conditions[0].argument,
            group.at(11).conditions[0].argument,
        },
        .offscreen_choice_first = .{ hidden, false, false, false },
    };
}
const Inputs = struct { reveal: ?i16, deliver: ?i16 };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    inputs: []Inputs,
    clips: []animation.OwnedClip,
    payments: []runtime.Payment,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |d| {
            self.allocator.free(d.label);
            self.allocator.free(d.outputs);
            self.allocator.free(d.departure_outputs);
            self.allocator.free(d.reveal_outputs);
        }
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.inputs);
        self.allocator.free(self.payments);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
    pub fn bind(self: Assets, connections: []const routes.Connection) ![]runtime.Binding {
        var result: std.ArrayList(runtime.Binding) = .empty;
        errdefer result.deinit(self.allocator);
        for (
            self.sources,
            self.inputs,
            0..,
        ) |source, inputs, index| for (connections) |connection| if (connection.recipient == source) {
            const action: runtime.Action = if (inputs.reveal == connection.message) .reveal else if (inputs.deliver == connection.message) .deliver else continue;
            try result.append(
                self.allocator,
                .{
                    .circuit = connection.circuit,
                    .target = index,
                    .action = action,
                    .next_step = connection.sender >= source,
                },
            );
        };
        return result.toOwnedSlice(self.allocator);
    }
};
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    bytes: []const u8,
    animations: []const u8,
    names: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    connections: *std.ArrayList(routes.Connection),
    supplies: []const equipment.Definition,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| {
            allocator.free(d.label);
            allocator.free(d.outputs);
            allocator.free(d.departure_outputs);
            allocator.free(d.reveal_outputs);
        }
        definitions.deinit(allocator);
    }
    var payments: std.ArrayList(runtime.Payment) = .empty;
    errdefer payments.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var inputs: std.ArrayList(Inputs) = .empty;
    errdefer inputs.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if (record.kind != spec.kind and
            !(spec.role == .conversation and record.kind == 5)) continue;
        const hidden = if (spec.hidden) |h| record.room >= rooms.len and
            record.initial_state == h.state else false;
        if (!hidden and
            record.initial_state != spec.idle[0]) return error.UnsupportedQuestContactStart;
        const room = if (hidden) record.parameters[spec.hidden.?.parameter] else @as(
            i16,
            record.room,
        );
        if (room < 0 or
            room >= rooms.len or
            record.contact_icon == 0) return error.InvalidQuestContactPlacement;
        var resolved: [9]motion.Clip = undefined;
        const states = spec.idle ++ spec.after ++ [1]u16{if (spec.hidden) |h| h.state else spec.idle[0]};
        for (states, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        var speech: ?runtime.Speech = null;
        if (spec.speech) |speech_states| {
            var speech_clips: [3]motion.Clip = undefined;
            for (speech_states, &speech_clips) |state, *destination| {
                var source = try animation.decode(allocator, animations, state);
                defer source.deinit();
                var clip = try source.resolve(allocator, resolver);
                errdefer clip.deinit();
                try clips.append(allocator, clip);
                destination.* = clip.clip();
            }
            speech = .{
                .introduction = speech_clips[0],
                .reply = speech_clips[1],
                .recovery = speech_clips[2],
            };
        }
        var reveal_outputs: std.ArrayList(world_props.CircuitId) = .empty;
        defer reveal_outputs.deinit(allocator);
        for (spec.reveal_outputs) |optional| if (optional) |output| {
            const recipient = record.parameters[output.parameter];
            if (recipient < 0 or recipient >= table.count) return error.InvalidQuestRevealOutput;
            try reveal_outputs.append(
                allocator,
                try routes.internConnection(
                    allocator,
                    connections,
                    @intCast(index),
                    @intCast(recipient),
                    output.signal,
                ),
            );
        };
        var outputs: std.ArrayList(world_props.CircuitId) = .empty;
        defer outputs.deinit(allocator);
        for (spec.outputs) |optional| if (optional) |output| {
            const recipient = record.parameters[output.parameter];
            if (recipient < 0 or recipient >= table.count) return error.InvalidQuestContactOutput;
            try outputs.append(
                allocator,
                try routes.internConnection(
                    allocator,
                    connections,
                    @intCast(index),
                    @intCast(recipient),
                    output.signal,
                ),
            );
        };
        var departure: std.ArrayList(world_props.CircuitId) = .empty;
        defer departure.deinit(allocator);
        for (spec.departure_outputs) |optional| if (optional) |output| {
            const recipient = record.parameters[output.parameter];
            if (recipient < 0 or recipient >= table.count) return error.InvalidQuestContactOutput;
            try departure.append(
                allocator,
                try routes.internConnection(
                    allocator,
                    connections,
                    @intCast(index),
                    @intCast(recipient),
                    output.signal,
                ),
            );
        };
        var sale: @FieldType(runtime.Definition, "sale") = null;
        if (spec.sale) |offer| {
            const purse_source = record.parameters[offer.purse_parameter];
            if (purse_source < 0 or purse_source >= table.count) return error.InvalidSellerPurse;
            const wallet = try table.record(@intCast(purse_source));
            const signal = credit_wallet.signal(try rules.group(
                bytes,
                wallet.rule_group,
            )) orelse return error.UnsupportedSellerPurse;
            if (signal != offer.signal or
                wallet.parameters[0] != record.kind) return error.UnsupportedSellerPayment;
            const purse: equipment.ItemHandle = for (supplies, 0..) |item, i| {
                if (item.kind == .credits) break .{ .index = @intCast(i), .generation = 1 };
            } else return error.MissingSellerPurse;
            sale = .{
                .purse = purse,
                .price = record.life,
                .debit = record.parameters[@as(usize, offer.purse_parameter) + 1],
            };
            try payments.append(
                allocator,
                .{
                    .item = purse,
                    .contact = definitions.items.len,
                    .next_step = purse_source >= index,
                },
            );
        }
        try sources.append(allocator, @intCast(index));
        try inputs.append(
            allocator,
            .{ .reveal = if (spec.hidden) |h| h.signal else null, .deliver = spec.receive },
        );
        const owned_reveal = try reveal_outputs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_reveal);
        const owned = try outputs.toOwnedSlice(allocator);
        errdefer allocator.free(owned);
        const owned_departure = try departure.toOwnedSlice(allocator);
        errdefer allocator.free(owned_departure);
        const label = try string_table.copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(
            allocator,
            .{
                .speech = speech,
                .reply_notice = if (spec.reply_notice) |id| @fromBackingInt(@as(
                    u16,
                    @intCast(id),
                )) else null,
                .after_chances = spec.after_chances,
                .release_unless_chance = spec.release_unless_chance,
                .talking_forward = spec.talking_forward,
                .disappear_after_leaving = spec.disappear_after_leaving,
                .finish_gestures_offscreen = spec.finish_gestures_offscreen,
                .dismiss_when_acknowledged = spec.dismiss_when_acknowledged,
                .reveal_outputs = owned_reveal,
                .contact_kind = if (record.kind == 3) .interactable else .mechanism,
                .footprint = .{
                    .room = rooms[@intCast(room)],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .hidden = hidden,
                .role = spec.role,
                .cycle = spec.cycle,
                .idle = resolved[0..4].*,
                .after = resolved[4..8].*,
                .hidden_clip = resolved[8],
                .chances = spec.chances,
                .offscreen_choice_first = spec.offscreen_choice_first,
                .notice = @fromBackingInt(@as(u16, @intCast(spec.notice))),
                .outputs = owned,
                .departure_outputs = owned_departure,
                .sale = sale,
                .hint = try resolver.icon(record.contact_icon - 1),
                .label = label,
                .priority = @intCast(index),
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
            },
        );
        table.register(@intCast(index), .quest_contacts);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| {
            allocator.free(d.label);
            allocator.free(d.outputs);
            allocator.free(d.departure_outputs);
            allocator.free(d.reveal_outputs);
        }
        allocator.free(owned);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_inputs = try inputs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_inputs);
    const owned_payments = try payments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_payments);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .inputs = owned_inputs,
        .payments = owned_payments,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
