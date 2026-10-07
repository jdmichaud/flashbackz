//! Import activated story interactions and their completion links.
const std = @import("std");
const runtime = @import("../story_stations.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const routes_mod = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    clips: []animation.OwnedClip,
    sources: []u16,
    signals: []i16,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
    }
    pub fn bind(self: Assets, routes: []const routes_mod.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signal, index| for (routes) |route| {
            if (route.recipient == source and route.message == signal) try bindings.append(self.allocator, .{ .circuit = route.circuit, .target = index, .next_step = route.sender >= source });
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
const Spec = struct { hidden: u16, ready: u16, using: u16, room_parameter: u2, enable: i16, reply: i16, movie: @import("../story_cue.zig").Cue };
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 5) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    const e = group.at(4);
    if (a.source != b.source or b.target != a.source or c.source != a.target or d.source != a.target or d.target != a.target or e.source != c.target or e.target != c.target or a.next != 2 or b.next != 0 or c.next != 4 or d.next != 2 or e.next != 4) return null;
    for ([_]rules.Rule{ a, b, c, d, e }) |r| if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (a.conditions[0].code != 34 or a.conditions[1].code != 87 or a.conditions[1].argument < 0 or a.conditions[1].argument > 3 or a.effect.code != 0) return null;
    if (b.conditions[0].code != 0 or b.conditions[1].code != 0 or b.effect.code != 67 or d.conditions[0].code != 0 or d.conditions[1].code != 0 or d.effect.code != 67) return null;
    if (c.conditions[0].code != 34 or c.conditions[0].argument != 30 or c.conditions[1].code != 90 or c.conditions[1].argument != 48 or c.effect.code != 0) return null;
    if (e.conditions[0].code != 0 or e.conditions[1].code != 35 or e.effect.code != 75) return null;
    return .{ .hidden = a.source, .ready = a.target, .using = c.target, .room_parameter = @intCast(a.conditions[1].argument), .enable = a.conditions[0].argument, .reply = e.conditions[1].argument, .movie = .memory_restoration };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]@import("../geometry.zig").RoomId, difficulty: @import("../settings.zig").Difficulty, routes: *std.ArrayList(routes_mod.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList(i16) = .empty;
    errdefer signals.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 3 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        const present = record.initial_state == spec.ready;
        if (!present and record.initial_state != spec.hidden) return error.UnsupportedStoryStationStart;
        const room = if (present) @as(i16, record.room) else record.parameters[spec.room_parameter];
        if (room < 0 or room >= rooms.len or record.contact_icon == 0 or record.collision_width == 0) return error.InvalidStoryStation;
        var resolved: [2]@import("../motion.zig").Clip = undefined;
        for ([_]u16{ spec.ready, spec.using }, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingStoryStation,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const recipient = record.parameters[0];
        if (recipient < 0 or recipient >= table.count) return error.InvalidStationReply;
        const reply = try routes_mod.internConnection(allocator, routes, @intCast(index), @intCast(recipient), spec.reply);
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.enable);
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        table.register(@intCast(index), .story_stations);
        try definitions.append(allocator, .{ .footprint = .{ .room = rooms[@intCast(room)], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .idle = resolved[0], .use = resolved[1], .initially_available = present, .initially_active = record.initially_active != 0, .accepts_signals = record.flags & 1 != 0, .interaction_priority = @intCast(index), .hint = try resolver.icon(record.contact_icon - 1), .label = label, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .movie = spec.movie, .reply = reply });
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{ .allocator = allocator, .definitions = owned, .clips = owned_clips, .sources = owned_sources, .signals = try signals.toOwnedSlice(allocator) };
}
