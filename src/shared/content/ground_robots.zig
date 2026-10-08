//! Import the deployable robot family by its motion/interaction topology, independent of
//! placement and group numbers. The runtime receives shared clips and measured distances.
const std = @import("std");
const runtime = @import("../actors/ground_robot.zig");
const animation = @import("animation.zig");
const rules = @import("rule_table.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const Phase = runtime.Phase;
const motion = @import("../motion.zig");
const settings = @import("../settings.zig");
const Sources = [runtime.phase_count]u16;
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn find(group: rules.Group, state: u16, code: u8, argument: ?i16) !rules.Rule {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source != state) continue;
        if (code == 0) {
            if (r.conditions[0].code == 0 and r.conditions[1].code == 0) return r;
        } else for (r.conditions) |condition| if (condition.code == code and
            (argument == null or argument.? == condition.argument)) return r;
    }
    return error.UnsupportedRobotBehavior;
}
fn source(sources: Sources, phase: Phase) u16 {
    return sources[@backingInt(phase)];
}
fn put(sources: *Sources, phase: Phase, value: u16) void {
    sources[@backingInt(phase)] = value;
}
fn distance(rule: rules.Rule) !i16 {
    if (rule.conditions[0].code != 120 and
        rule.conditions[0].code != 121) return error.UnsupportedRobotPerception;
    const cells = rule.conditions[0].argument;
    if (cells < 0 or cells > 64) return error.InvalidRobotRange;
    return cells * 16;
}
fn discover(group: rules.Group) !?Sources {
    if (group.count() != 48) return null;
    const first = group.at(0);
    if (first.conditions[0].code != 120 or
        first.conditions[1].code != 0 or
        first.source == first.target) return null;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        for (rule.conditions) |op| switch (op.code) {
            0, 14, 17, 34, 75, 100, 120, 121 => {},
            else => return null,
        };
        if (rule.effect.code != 0 and rule.effect.code != 67) return null;
    }
    var sources: Sources = undefined;
    put(&sources, .closed_idle, first.source);
    put(&sources, .deploying, first.target);
    put(&sources, .closed_walk, (try find(group, first.source, 17, null)).target);
    put(&sources, .closed_turn, (try find(group, first.source, 121, null)).target);
    const open = (try find(group, first.target, 0, null)).target;
    put(&sources, .open_idle_a, open);
    put(&sources, .open_idle_b, (try find(group, open, 100, null)).target);
    put(&sources, .open_turn, (try find(group, open, 121, null)).target);
    put(&sources, .open_walk_a, (try find(group, open, 17, null)).target);
    put(&sources, .open_walk_b, (try find(group, source(sources, .open_walk_a), 0, null)).target);
    put(&sources, .retracting, (try find(group, open, 0, null)).target);
    put(&sources, .collapsing_front, (try find(group, open, 34, 4)).target);
    put(&sources, .collapsing_rear, (try find(group, open, 34, 2)).target);
    put(
        &sources,
        .overloading,
        (try find(group, source(sources, .collapsing_front), 0, null)).target,
    );
    put(&sources, .exploding, (try find(group, source(sources, .overloading), 0, null)).target);
    const removal = try find(group, source(sources, .exploding), 75, null);
    if (removal.target != removal.source) return error.UnsupportedRobotRemoval;
    for (sources, 0..) |state, i| for (sources[0..i]) |previous| if (state == previous) return error.AmbiguousRobotMotion;
    return sources;
}
fn profile(
    group: rules.Group,
    sources: Sources,
    clips: [runtime.phase_count]motion.Clip,
) !runtime.Profile {
    const closed = source(sources, .closed_idle);
    const idle = source(sources, .open_idle_a);
    const alternate = source(sources, .open_idle_b);
    const walking = source(sources, .open_walk_b);
    const blast = source(sources, .overloading);
    const closed_step = (try find(group, source(sources, .closed_walk), 0, null)).dx;
    const open_step = (try find(group, source(sources, .open_walk_a), 0, null)).dx;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        const expected_dx: i8 = if (rule.source == source(sources, .closed_walk)) closed_step else if (rule.source == source(sources, .open_walk_a) or rule.source == walking) open_step else 0;
        if (rule.dx != expected_dx or
            rule.dy != 0 or
            rule.flags & ~@as(u8, 1) != 0) return error.UnsupportedRobotMotionEntry;
    }
    const wall = try find(group, closed, 14, null);
    const floor = try find(group, closed, 17, null);
    return .{
        .clips = clips,
        .deployment_distance = try distance(group.at(0)),
        .strike_distance = try distance(try find(group, idle, 100, null)),
        .obstacle_distance = try distance(try find(group, idle, 14, null)),
        .pursuit_distance = .{
            try distance(try find(group, idle, 17, null)),
            try distance(try find(group, alternate, 17, null)),
        },
        .walking_pursuit_distance = try distance(try find(group, walking, 17, null)),
        .explosion_distance = try distance(try find(group, blast, 120, null)),
        .closed_step = -@as(i16, closed_step),
        .open_step = -@as(i16, open_step),
        .wall_ahead = wall.conditions[1].argument,
        .floor_ahead = floor.conditions[1].argument,
    };
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var imported: [256]?struct { index: usize, initial: u16 } = @splat(null);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 10 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.rule_group >= imported.len) return error.InvalidRobotRuleGroup;
        if (imported[record.rule_group] == null) {
            const group = try rules.group(rule_bytes, record.rule_group);
            const sources = try discover(group) orelse continue;
            var resolved: [runtime.phase_count]motion.Clip = undefined;
            for (sources, &resolved) |state, *destination| {
                var raw = try animation.decode(allocator, animations, state);
                defer raw.deinit();
                if (raw.kind != .composition) return error.UnsupportedRobotArt;
                var clip = try raw.resolve(allocator, resolver);
                errdefer clip.deinit();
                try clips.append(allocator, clip);
                destination.* = clip.clip();
            }
            const index = profiles.items.len;
            try profiles.append(allocator, try profile(group, sources, resolved));
            imported[record.rule_group] = .{
                .index = index,
                .initial = source(sources, .closed_idle),
            };
        }
        const family = imported[record.rule_group].?;
        if (record.initial_state != family.initial or
            record.room >= rooms.len or
            record.parameters[0] < 1 or
            record.parameters[0] > 64) return error.UnsupportedRobotPlacement;
        table.register(@intCast(i), .ground_robots);
        try definitions.append(
            allocator,
            .{
                .profile = family.index,
                .footprint = .{
                    .room = rooms[record.room],
                    .position = record.position,
                    .width = record.collision_width,
                },
                .facing = if (record.facing_right == 0) .left else .right,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .strike_cells = @intCast(record.parameters[0]),
            },
        );
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned_definitions);
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    return .{
        .allocator = allocator,
        .definitions = owned_definitions,
        .profiles = owned_profiles,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
