//! Recover the portable force-field emitter families, independently of their placements.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../force_fields.zig");
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
fn ops(rule: rules.Rule, expected: [3]rules.Operation) bool {
    return std.meta.eql(rule.conditions[0], expected[0]) and std.meta.eql(rule.conditions[1], expected[1]) and std.meta.eql(rule.effect, expected[2]);
}
const nop: rules.Operation = .{ .code = 0, .argument = 0 };
fn op(code: u8, argument: i16) rules.Operation {
    return .{ .code = code, .argument = argument };
}
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, animations: []const u8, difficulty: @import("../settings.zig").Difficulty, resolver: anytype) !Assets {
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
        if (record.kind != 12 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (group.count() != 7 and group.count() != 12) continue;
        const a = group.at(0);
        if (!ops(a, .{ op(10, 1), op(50, 6), op(49, 0) })) continue;
        const rear = group.count() == 12;
        // The rear emitter also has an authored dormant display override. Its external
        // story signals remain separate from the portable equipment activation path.
        if (rear) {
            const display = group.at(7);
            if (!ops(display, .{ op(34, 11), nop, nop }) or display.source != a.source or
                !ops(group.at(8), .{ nop, nop, nop }) or group.at(8).target != a.source or
                !ops(group.at(10), .{ op(34, 10), nop, nop }) or group.at(10).source != display.target or group.at(10).target != a.source or
                !ops(group.at(11), .{ nop, nop, op(67, 0) }) or group.at(11).source != display.target or group.at(11).target != display.target)
                return error.UnsupportedForceFieldDisplayOverride;
        }
        const idle = a.source;
        const active = group.at(2).source;
        const absorbed = group.at(2).target;
        const recovered = group.at(4).target;
        if (record.initial_state != idle or record.room < 64 or record.initially_active == 0 or record.collision_width != 1) return error.UnsupportedForceFieldStart;
        for (0..group.count()) |i| if (group.at(i).flags != 0) return error.UnsupportedForceFieldFlags;
        if (!ops(group.at(1), .{ nop, nop, nop }) or group.at(1).source != idle or group.at(1).target != idle or group.at(1).next != 0) return error.UnsupportedForceFieldRules;
        for (2..4) |i| {
            const r = group.at(i);
            if (!ops(r, .{ op(107, if (i == 2) 1 else 0), nop, op(49, 0) }) or r.source != active or r.target != absorbed or r.next != (if (rear) @as(u16, 9) else 6)) return error.UnsupportedForceFieldImpact;
        }
        if (!ops(group.at(4), .{ nop, nop, op(87, 0) }) or group.at(4).source != active or group.at(4).next != (if (rear) @as(u16, 0) else 5)) return error.UnsupportedForceFieldExpiry;
        const end = group.at(if (rear) 9 else 6);
        if (!ops(end, .{ nop, nop, op(87, 0) }) or end.source != absorbed or end.target != idle or end.next != 0) return error.UnsupportedForceFieldImpactEnd;
        if (rear) {
            const check = group.at(5);
            if (!ops(check, .{ nop, op(106, -16), nop }) or a.next != 5 or check.source != a.target or check.target != active or check.next != 2 or recovered != idle) return error.UnsupportedRearForceField;
            if (!ops(group.at(6), .{ nop, nop, op(87, 0) }) or group.at(6).source != check.source or group.at(6).target != idle) return error.UnsupportedRearForceField;
        } else if (a.target != active or a.next != 2 or !ops(group.at(5), .{ nop, nop, nop }) or group.at(5).source != recovered or group.at(5).target != idle) return error.UnsupportedForceFieldRecovery;
        var resolved: [5]@import("../motion.zig").Clip = undefined;
        for ([_]u16{ idle, if (rear) a.target else idle, active, recovered, absorbed }, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        table.register(@intCast(index), .force_fields);
        try definitions.append(allocator, .{ .rear = rear, .deploy = .{ .x = a.dx, .y = a.dy }, .impact = .{ .x = group.at(2).dx, .y = group.at(2).dy }, .idle = resolved[0], .checking = resolved[1], .shielding = resolved[2], .recovery = resolved[3], .absorption = resolved[4], .rear_range = if (rear) @intCast(-group.at(5).conditions[1].argument) else 0, .width = record.collision_width, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0 });
        try sources.append(allocator, @intCast(index));
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .clips = try clips.toOwnedSlice(allocator) };
}
