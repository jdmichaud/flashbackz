//! Recover civilian following and lift invitation/release semantics from a complete family.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../escort_followers.zig");
const Spec = struct { states: [6]u16, gap: i16, advance: i16, message: i16 };
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 44) return null;
    const sources = [_]usize{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 18, 18, 18, 18, 18, 18, 18, 18, 18, 27, 27, 27, 27, 27, 27, 27, 27, 35, 35, 37, 37, 39, 40, 40, 42, 43 };
    const next = [_]u16{ 0, 39, 35, 35, 35, 35, 35, 0, 0, 0, 18, 18, 37, 18, 18, 0, 0, 42, 0, 0, 0, 27, 27, 27, 27, 0, 0, 0, 0, 0, 18, 18, 18, 0, 0, 0, 0, 0, 37, 37, 43, 40, 40, 0 };
    const codes = [_][3]u8{ .{ 34, 123, 0 }, .{ 120, 110, 0 }, .{ 118, 26, 0 }, .{ 118, 14, 0 }, .{ 119, 26, 0 }, .{ 119, 14, 0 }, .{ 121, 0, 0 }, .{ 120, 26, 0 }, .{ 120, 14, 0 }, .{ 120, 0, 0 }, .{ 120, 17, 0 }, .{ 120, 23, 0 }, .{ 110, 0, 67 }, .{ 118, 23, 0 }, .{ 119, 23, 0 }, .{ 77, 0, 67 }, .{ 0, 0, 0 }, .{ 120, 0, 0 }, .{ 120, 0, 0 }, .{ 26, 0, 0 }, .{ 14, 0, 0 }, .{ 120, 17, 0 }, .{ 120, 23, 0 }, .{ 118, 23, 0 }, .{ 119, 23, 0 }, .{ 121, 0, 0 }, .{ 0, 0, 0 }, .{ 120, 0, 0 }, .{ 0, 26, 0 }, .{ 0, 14, 0 }, .{ 120, 17, 0 }, .{ 118, 23, 0 }, .{ 119, 23, 0 }, .{ 121, 0, 0 }, .{ 0, 0, 0 }, .{ 34, 123, 0 }, .{ 0, 0, 0 }, .{ 113, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 63, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 62 }, .{ 0, 0, 62 } };
    for (sources, next, codes, 0..) |source, target, operations, index| {
        const row = group.at(index);
        if (row.source != group.at(source).source or row.target != group.at(target).source or row.next != target or row.dy != 0 or row.flags != (if (index == 35 or index == 36) @as(u8, 1) else 0)) return null;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, operations) |operation, code| if (operation.code != code) return null;
    }
    const stride = group.at(10).dx;
    for (0..44) |i| {
        const row = group.at(i);
        const walking = std.mem.indexOfScalar(usize, &.{ 10, 11, 13, 14, 21, 22, 23, 24, 30, 31, 32 }, i) != null;
        if (row.dx != (if (walking) stride else 0)) return null;
    }
    if (stride >= 0 or group.at(0).conditions[0].argument != 30 or group.at(35).conditions[0].argument != 30 or group.at(0).conditions[1].argument != group.at(35).conditions[1].argument) return null;
    if (group.at(1).conditions[1].argument != 132 or group.at(12).conditions[0].argument != 132 or group.at(37).conditions[0].argument != 130) return null;
    const gap = group.at(9).conditions[0].argument;
    if (gap <= 0 or gap > 16 or group.at(18).conditions[0].argument != gap or group.at(27).conditions[0].argument != gap) return null;
    // Row17 and its hesitation suffix have no incoming path from the authored start:
    // the unconditional row16 ends the waiting decision before row17 can be visited.
    return .{ .states = .{ group.at(0).source, group.at(18).source, group.at(27).source, group.at(35).source, group.at(39).source, group.at(37).source }, .gap = gap * 16, .advance = -@as(i16, stride), .message = group.at(0).conditions[1].argument };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    clips: []animation.OwnedClip,
    lift_bindings: []runtime.LiftBinding,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |d| self.allocator.free(d.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.lift_bindings);
    }
};
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, lifts: @import("lifts.zig").Assets, resolver: anytype) !Assets {
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
    var bindings: std.ArrayList(runtime.LiftBinding) = .empty;
    errdefer bindings.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 3 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0] or record.contact_icon == 0 or spec.message < 0) return error.UnsupportedEscortStart;
        var resolved: [6]@import("../motion.zig").Clip = undefined;
        for (spec.states, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        for (lifts.source_indices, 0..) |source, platform| try bindings.append(allocator, .{ .actor = definitions.items.len, .platform = platform, .next_step = source >= index });
        try sources.append(allocator, @intCast(index));
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .clips = resolved, .gap = spec.gap, .stride_advance = spec.advance, .hint = try resolver.icon(record.contact_icon - 1), .label = label, .notice = @fromBackingInt(@as(u16, @intCast(spec.message))), .priority = @intCast(index), .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0 });
        table.register(@intCast(index), .escort_followers);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .clips = owned_clips, .lift_bindings = try bindings.toOwnedSlice(allocator) };
}
