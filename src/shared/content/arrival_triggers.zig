//! Recover contact-category arrival zones, their acknowledgement and outgoing connections.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../arrival_triggers.zig");
const routes = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(routes.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 7 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (group.count() != 5) continue;
        const a = group.at(0);
        const b = group.at(1);
        const c = group.at(2);
        const d = group.at(3);
        const e = group.at(4);
        if (a.conditions[0].code != 0 or a.conditions[1].code != 60 or a.effect.code < 35 or a.effect.code > 38 or a.conditions[1].argument != 0 or b.conditions[1].argument != 1 or d.conditions[0].code != 123 or e.effect.code != 75) continue;
        const next = [_]u16{ 3, 3, 0, 4, 3 };
        const from = [_]usize{ 0, 0, 0, 3, 4 };
        for (next, from, 0..) |target, source, i| {
            const row = group.at(i);
            if (row.source != group.at(source).source or row.target != group.at(target).source or row.next != target or row.dx != 0 or row.dy != 0 or row.flags != 0) return error.UnsupportedArrivalTrigger;
        }
        if (b.conditions[0].code != 0 or b.conditions[1].code != 60 or b.effect.code != a.effect.code or b.effect.argument != a.effect.argument or b.conditions[0].argument != a.conditions[0].argument or c.conditions[0].code != 0 or c.conditions[1].code != 0 or c.effect.code != 67 or d.conditions[1].code != 0 or d.effect.code != 0 or d.conditions[0].argument < 0 or e.conditions[0].code < 35 or e.conditions[0].code > 38 or e.conditions[1].code != 0) return error.UnsupportedArrivalTrigger;
        const category: @import("../contacts.zig").Kind = switch (a.conditions[0].argument) {
            1 => .player,
            3 => .interactable,
            else => return error.UnsupportedArrivalCategory,
        };
        if (record.initial_state != a.source) return error.UnsupportedArrivalStart;
        const start = record.parameters[a.effect.code - 35];
        const finish = record.parameters[e.conditions[0].code - 35];
        if (start < 0 or start >= table.count or finish < 0 or finish >= table.count) return error.InvalidArrivalConnection;
        const begin = try routes.internConnection(allocator, connections, @intCast(index), @intCast(start), a.effect.argument);
        const complete = try routes.internConnection(allocator, connections, @intCast(index), @intCast(finish), e.conditions[0].argument);
        var resolved: [3]@import("../motion.zig").Clip = undefined;
        for ([_]u16{ a.source, d.source, e.source }, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            if (source.sound != null) return error.AudibleArrivalMarker;
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingArrivalMarker,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        try sources.append(allocator, @intCast(index));
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .category = category, .clips = resolved, .notice = @fromBackingInt(@as(u16, @intCast(d.conditions[0].argument))), .begin = begin, .complete = complete, .priority = @intCast(index), .initially_active = record.initially_active != 0, .wake_on_contact = record.flags & 2 != 0 });
        table.register(@intCast(index), .arrival_triggers);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .clips = try clips.toOwnedSlice(allocator) };
}
