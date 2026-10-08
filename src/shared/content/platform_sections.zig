//! Discover hidden/visible section pairs and convert their room/material writes to floor
//! definitions. The renderer and terrain system never see source instruction/state IDs.
const std = @import("std");
const runtime = @import("../platform_sections.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const collision = @import("collision.zig");
const first_world_props = @import("first_world_props.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
const Pair = struct { hidden: u16, visible: u16, message: i16, room_parameter: u2, height: i16 };
fn recognize(group: rules.Group, initial: u16) ?Pair {
    if (group.count() == 0 or group.count() % 4 != 0) return null;
    var found: ?Pair = null;
    for (0..group.count() / 4) |index| {
        const at = index * 4;
        const a = group.at(at);
        const b = group.at(at + 1);
        const c = group.at(at + 2);
        const d = group.at(at + 3);
        for ([_]rules.Rule{ a, b, c, d }) |r| if (r.dx != 0 or
            r.dy != 0 or
            r.flags != 0) return null;
        if (a.source != b.source or
            b.target != a.source or
            c.source != a.target or
            c.target != a.target or
            d.source != a.target or
            d.target != a.target or
            a.source == a.target or
            a.next != at + 2 or
            b.next != at or
            c.next != at + 2 or
            d.next != at + 2) return null;
        if (a.conditions[0].code != 34 or
            a.conditions[1].code != 0 or
            a.effect.code != 87 or
            a.effect.argument < 0 or
            a.effect.argument > 3) return null;
        if (b.conditions[0].code != 0 or
            b.conditions[1].code != 0 or
            b.effect.code != 0) return null;
        if (c.conditions[0].code != 77 or
            c.conditions[0].argument != 0 or
            c.conditions[1].code != 54 or
            c.effect.code != 67) return null;
        if (d.conditions[0].code != 0 or
            d.conditions[1].code != 54 or
            d.conditions[1].argument != c.conditions[1].argument or
            d.effect.code != 0) return null;
        if (initial == a.source or initial == a.target) found = .{
            .hidden = a.source,
            .visible = a.target,
            .message = a.conditions[0].argument,
            .room_parameter = @intCast(a.effect.argument),
            .height = c.conditions[1].argument,
        };
    }
    return found;
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    connections: []const first_world_props.Connection,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        const pair = recognize(
            try rules.group(rule_bytes, record.rule_group),
            record.initial_state,
        ) orelse continue;
        const present = record.initial_state == pair.visible;
        const destination = if (present) @as(i16, record.room) else record.parameters[pair.room_parameter];
        if (destination < 0 or
            destination >= rooms.len or
            record.collision_width == 0) return error.InvalidPlatformSectionPlacement;
        var column = @divFloor(@as(i32, record.position.x) + 8, 16);
        if (record.facing_right != 0) column -= record.collision_width - 1;
        const row = (@divTrunc(@as(i32, record.position.y), 36) & ~@as(i32, 1)) + pair.height;
        if (column < 0 or
            column + record.collision_width > 16 or
            row < 0 or
            row >= 7) return error.InvalidPlatformSectionFootprint;
        var source = try animation.decode(allocator, animations, pair.visible);
        defer source.deinit();
        for (source.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingPlatformSection,
        };
        const clip = blk: {
            var resolved = try source.resolve(allocator, resolver);
            errdefer resolved.deinit();
            try clips.append(allocator, resolved);
            break :blk resolved.clip();
        };
        for (connections) |connection| if (connection.recipient == i and
            connection.message == pair.message)
        {
            try bindings.append(
                allocator,
                .{
                    .circuit = connection.circuit,
                    .target = definitions.items.len,
                    .next_step = connection.sender >= i,
                },
            );
        };
        const room = rooms[@intCast(destination)];
        table.register(@intCast(i), .platform_sections);
        try definitions.append(
            allocator,
            .{
                .footprint = .{
                    .room = room,
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .span = .{
                    .origin = .{ .room = room, .column = @intCast(column), .row = @intCast(row) },
                    .length = record.collision_width,
                    .history_weight = collision.snapshotWeight(record.collision_width),
                    .reuse = collision.snapshotReuse(
                        record.collision_width,
                        record.facing_right != 0,
                    ),
                },
                .idle = clip,
                .initially_present = present,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
            },
        );
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .bindings = owned_bindings,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
