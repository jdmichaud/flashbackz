//! Import a complete attention/conversation family into host postures and dialogue topics.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../attentive_contacts.zig");
const routes = @import("first_world_props.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
const string_table = @import("string_table.zig");
const Spec = struct {
    states: [2][7]u16,
    speech: [2]u16,
    messages: [2]i16,
    chances: [2][4]i16,
    distance: i16,
    parameter: u2,
    signal: i16,
};
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 60) return null;
    const sources = [_]usize{
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        8,
        8,
        8,
        8,
        8,
        8,
        14,
        14,
        14,
        14,
        14,
        14,
        20,
        20,
        20,
        23,
        23,
        23,
        26,
        26,
        26,
        29,
        29,
        29,
        32,
        33,
        34,
        34,
        34,
        34,
        34,
        34,
        34,
        34,
        42,
        42,
        42,
        42,
        42,
        47,
        47,
        47,
        47,
        47,
        52,
        52,
        54,
        54,
        56,
        56,
        58,
        58,
    };
    const next = [_]u16{
        32,
        0,
        0,
        20,
        23,
        23,
        20,
        0,
        32,
        8,
        26,
        8,
        8,
        26,
        32,
        14,
        29,
        14,
        14,
        29,
        32,
        8,
        8,
        32,
        14,
        14,
        32,
        0,
        0,
        32,
        0,
        0,
        34,
        34,
        33,
        34,
        34,
        52,
        54,
        54,
        52,
        34,
        42,
        56,
        42,
        42,
        56,
        47,
        58,
        47,
        47,
        58,
        52,
        42,
        54,
        47,
        56,
        34,
        58,
        34,
    };
    const operations = [_][3]u8{
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 121, 0, 0 },
        .{ 120, 0, 0 },
        .{ 97, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 121, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 120, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 34, 0, 35 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 0, 0, 123 },
        .{ 0, 0, 123 },
        .{ 34, 0, 0 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 121, 0, 0 },
        .{ 120, 0, 0 },
        .{ 97, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 121, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 69, 0, 0 },
        .{ 120, 0, 0 },
        .{ 97, 0, 0 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
        .{ 77, 0, 67 },
        .{ 0, 0, 0 },
    };
    const distance = group.at(3).conditions[0].argument;
    if (distance <= 0 or distance > 16) return null;
    for (sources, next, operations, 0..) |source, target, ops, index| {
        const row = group.at(index);
        if (row.source != group.at(source).source or
            row.target != group.at(target).source or
            row.next != target or
            row.dx != 0 or
            row.dy != 0 or
            row.flags != 0) return null;
        for (
            [_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect },
            ops,
        ) |value, code| if (value.code != code) return null;
        switch (row.conditions[0].code) {
            34 => if (row.conditions[0].argument != 30) return null,
            77 => if (row.conditions[0].argument != 0) return null,
            69 => if (row.conditions[0].argument != 1) return null,
            120, 121 => if (row.conditions[0].argument != distance) return null,
            97 => if (row.conditions[0].argument <= 0) return null,
            else => {},
        }
        if (row.effect.code == 35 and
            row.effect.argument != group.at(0).effect.argument) return null;
    }
    if (group.at(32).effect.argument < 0 or group.at(33).effect.argument < 0) return null;
    return .{
        .states = .{
            .{
                group.at(0).source,
                group.at(8).source,
                group.at(14).source,
                group.at(20).source,
                group.at(23).source,
                group.at(26).source,
                group.at(29).source,
            },
            .{
                group.at(34).source,
                group.at(42).source,
                group.at(47).source,
                group.at(52).source,
                group.at(54).source,
                group.at(56).source,
                group.at(58).source,
            },
        },
        .speech = .{ group.at(32).source, group.at(33).source },
        .messages = .{ group.at(32).effect.argument, group.at(33).effect.argument },
        .chances = .{
            .{
                group.at(5).conditions[0].argument,
                group.at(6).conditions[0].argument,
                group.at(12).conditions[0].argument,
                group.at(18).conditions[0].argument,
            },
            .{
                group.at(39).conditions[0].argument,
                group.at(40).conditions[0].argument,
                group.at(45).conditions[0].argument,
                group.at(50).conditions[0].argument,
            },
        },
        .distance = distance * 16,
        .parameter = 0,
        .signal = group.at(0).effect.argument,
    };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |d| self.allocator.free(d.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
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
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 3 or
            record.room >= rooms.len or
            record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if ((record.initial_state != spec.states[0][0] and
            record.initial_state != spec.states[1][0]) or
            record.contact_icon == 0) return error.UnsupportedHostStart;
        const target = record.parameters[spec.parameter];
        if (target < 0 or target >= table.count) return error.InvalidHostOutput;
        var idle: [2][7]motion.Clip = undefined;
        var speech: [2]motion.Clip = undefined;
        for (spec.states, &idle) |states, *stage| for (states, stage) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        };
        for (spec.speech, &speech) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const output = try routes.internConnection(
            allocator,
            connections,
            @intCast(index),
            @intCast(target),
            spec.signal,
        );
        try sources.append(allocator, @intCast(index));
        const label = try string_table.copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(
            allocator,
            .{
                .footprint = .{
                    .room = rooms[record.room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .idle = idle,
                .speech = speech,
                .messages = .{
                    @fromBackingInt(@as(u16, @intCast(spec.messages[0]))),
                    @fromBackingInt(@as(u16, @intCast(spec.messages[1]))),
                },
                .chances = spec.chances,
                .attention_distance = spec.distance,
                .output = output,
                .initially_acquainted = record.initial_state == spec.states[1][0],
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
        table.register(@intCast(index), .attentive_contacts);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
