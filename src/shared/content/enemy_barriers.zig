//! Recover defensive emitter motion and bind requesting gunmen to shared field instances.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../enemy_barriers.zig");
const first_world_props = @import("first_world_props.zig");
const gunmen_mod = @import("gunmen.zig");
const motion = @import("../motion.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.bindings);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn recognize(group: rules.Group) bool {
    if (group.count() != 8) return false;
    const sources = [_]usize{ 0, 0, 2, 2, 2, 5, 6, 6 };
    const next = [_]u16{ 2, 0, 6, 6, 5, 0, 2, 0 };
    const codes = [_][3]u8{
        .{ 34, 0, 96 },
        .{ 0, 0, 75 },
        .{ 34, 0, 0 },
        .{ 34, 0, 0 },
        .{ 0, 0, 87 },
        .{ 0, 0, 0 },
        .{ 34, 0, 96 },
        .{ 0, 0, 87 },
    };
    for (sources, next, codes, 0..) |source, target, ops, i| {
        const r = group.at(i);
        if (r.source != group.at(source).source or
            r.target != group.at(target).source or
            r.next != target or
            r.flags != (if (i == 2 or i == 3 or i == 6 or i == 7) @as(u8, 1) else 0)) return false;
        for (
            [_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect },
            ops,
        ) |op, code| if (op.code != code) return false;
    }
    return group.at(0).conditions[0].argument == group.at(0).effect.argument and
        group.at(6).conditions[0].argument == group.at(0).effect.argument and
        group.at(6).effect.argument == group.at(0).effect.argument and
        group.at(0).dx == group.at(6).dx and
        group.at(0).dy == group.at(6).dy and
        group.at(2).conditions[0].argument == 3 and
        group.at(3).conditions[0].argument == 4 and
        group.at(2).dx == 0 and
        group.at(3).dx == 0 and
        group.at(4).effect.argument == 0 and
        group.at(7).effect.argument == 0;
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    bytes: []const u8,
    animations: []const u8,
    difficulty: settings.Difficulty,
    connections: []const first_world_props.Connection,
    gunmen: gunmen_mod.Assets,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 10 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (!recognize(group)) continue;
        if (record.initial_state != group.at(0).source or
            record.room < 64 or
            record.parameters[0] != 64 or
            record.flags & 1 == 0) return error.UnsupportedEnemyBarrierStart;
        var resolved: [4]motion.Clip = undefined;
        for ([_]usize{ 0, 2, 5, 6 }, &resolved) |row, *destination| {
            var source = try animation.decode(allocator, animations, group.at(row).source);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        for (connections) |connection| if (connection.recipient == index and
            connection.message == group.at(0).conditions[0].argument)
        {
            const owner = std.mem.indexOfScalar(u16, gunmen.sources, connection.sender) orelse return error.UnsupportedBarrierOwner;
            try bindings.append(
                allocator,
                .{
                    .circuit = connection.circuit,
                    .emitter = definitions.items.len,
                    .owner = owner,
                    .next_step = connection.sender >= index,
                },
            );
        };
        try sources.append(allocator, @intCast(index));
        try definitions.append(
            allocator,
            .{
                .initial_position = record.position,
                .initial_facing = if (record.facing_right == 0) .left else .right,
                .initially_active = record.initially_active != 0,
                .clips = resolved,
                .deploy = .{ .x = group.at(0).dx, .y = group.at(0).dy },
                .impact_down = .{ group.at(2).dy, group.at(3).dy },
                .width = record.collision_width,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
            },
        );
        table.register(@intCast(index), .enemy_barriers);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .bindings = owned_bindings,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
