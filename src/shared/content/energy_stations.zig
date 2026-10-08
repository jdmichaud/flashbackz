//! Import the passive energy-generator family, independent of source group/placement IDs.
const std = @import("std");
const runtime = @import("../energy_stations.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
const string_table = @import("string_table.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
pub fn recognize(group: rules.Group) ?u16 {
    if (group.count() != 2) return null;
    const sleep = group.at(0);
    const idle = group.at(1);
    for ([_]rules.Rule{
        sleep,
        idle,
    }) |r| if (r.dx != 0 or
        r.dy != 0 or
        r.flags != 0 or
        r.next != 0 or
        r.source != sleep.source or
        r.target != sleep.source) return null;
    if (sleep.conditions[0].code != 77 or
        sleep.conditions[0].argument != 0 or
        sleep.conditions[1].code != 0 or
        sleep.effect.code != 67) return null;
    if (idle.conditions[0].code != 0 or
        idle.conditions[1].code != 0 or
        idle.effect.code != 0) return null;
    return sleep.source;
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    names: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| allocator.free(definition.label);
        definitions.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 9 or
            record.room >= rooms.len or
            record.minimum_difficulty > @backingInt(difficulty)) continue;
        const state = recognize(try rules.group(
            rule_bytes,
            record.rule_group,
        )) orelse return error.UnsupportedEnergyStationFamily;
        if (record.initial_state != state) return error.UnsupportedEnergyStationStart;
        var source = try animation.decode(allocator, animations, state);
        defer source.deinit();
        for (source.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |value| if (value.dx != 0 or value.dy != 0) return error.MovingEnergyStation,
        };
        const idle = blk: {
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            break :blk clip.clip();
        };
        const label = try string_table.copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        table.register(@intCast(i), .energy_stations);
        try definitions.append(
            allocator,
            .{
                .footprint = .{
                    .room = rooms[record.room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .palette_bank = @intCast(record.visual_flags & 3),
                .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player,
                .idle = idle,
                .initially_active = record.initially_active != 0,
                .wake_when_near = record.flags & 4 != 0,
                .hint = if (record.contact_icon != 0) try resolver.icon(record.contact_icon - 1) else null,
                .label = label,
            },
        );
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |definition| allocator.free(definition.label);
        allocator.free(owned);
    }
    return .{
        .allocator = allocator,
        .definitions = owned,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
