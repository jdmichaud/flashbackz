//! Extract decorative gesture profiles from the same family as conversational bar patrons.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const runtime = @import("../ambient_people.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    sources: []u16,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        for (self.profiles) |profile| {
            for (profile.choices) |choices| self.allocator.free(choices);
            self.allocator.free(profile.gestures);
        }
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn resolve(
    allocator: std.mem.Allocator,
    clips: *std.ArrayList(animation.OwnedClip),
    animations: []const u8,
    state: u16,
    resolver: anytype,
) !@import("../motion.zig").Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try clips.append(allocator, clip);
    return clip.clip();
}
fn validate(group: rules.Group) bool {
    if (group.count() != 70 or @import("quest_contacts.zig").recognize(group) == null) return false;
    const sources = [_]usize{
        26,
        26,
        26,
        26,
        26,
        31,
        31,
        31,
        31,
        35,
        35,
        35,
        35,
        39,
        40,
        41,
        42,
        43,
        44,
        45,
        46,
        46,
        46,
        46,
        46,
        51,
        51,
        51,
        51,
        55,
        55,
        55,
        55,
        59,
        60,
        60,
        62,
        63,
        64,
        65,
        66,
        67,
        67,
        69,
    };
    const next = [_]u16{
        40,
        44,
        43,
        26,
        26,
        39,
        45,
        31,
        31,
        41,
        42,
        35,
        35,
        35,
        35,
        31,
        26,
        26,
        26,
        31,
        60,
        65,
        66,
        46,
        46,
        59,
        64,
        51,
        51,
        63,
        62,
        55,
        55,
        55,
        55,
        55,
        51,
        46,
        51,
        46,
        67,
        69,
        67,
        46,
    };
    const random_rows = [_]usize{ 26, 27, 28, 31, 32, 35, 36, 46, 47, 48, 51, 52, 55, 56, 67 };
    const sleeping = [_]usize{ 29, 33, 37, 49, 53, 57 };
    for (sources, next, 0..) |source, target, n| {
        const i = n + 26;
        const row = group.at(i);
        const random = std.mem.indexOfScalar(usize, &random_rows, i) != null;
        const sleep = std.mem.indexOfScalar(usize, &sleeping, i) != null;
        if (row.source != group.at(source).source or
            row.target != group.at(target).source or
            row.next != target or
            row.dy != 0 or
            row.flags != 0 or
            row.conditions[0].code != (if (random) @as(
                u8,
                97,
            ) else if (sleep) @as(
                u8,
                77,
            ) else 0) or row.conditions[1].code != 0 or row.effect.code != (if (sleep) @as(
            u8,
            67,
        ) else 0)) return false;
        if (random and row.conditions[0].argument <= 0) return false;
        if (i != 28 and i != 43 and i != 48 and i != 69 and row.dx != 0) return false;
    }
    return true;
}
pub fn load(
    allocator: std.mem.Allocator,
    table: @import("placement.zig").Table,
    bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]@import("../geometry.zig").RoomId,
    difficulty: @import("../settings.zig").Difficulty,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer {
        for (profiles.items) |profile| {
            for (profile.choices) |choices| allocator.free(choices);
            allocator.free(profile.gestures);
        }
        profiles.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var cached = std.AutoHashMap(u32, usize).init(allocator);
    defer cached.deinit();
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.kind != 0 or
            record.room >= rooms.len or
            record.minimum_difficulty > @backingInt(difficulty)) continue;
        const group = try rules.group(bytes, record.rule_group);
        if (!validate(group)) continue;
        var style: usize = 0;
        for (46..70) |i| if (group.at(i).source == record.initial_state) {
            style = 1;
            break;
        };
        const idle_rows = if (style == 0) [_]usize{ 26, 31, 35 } else [_]usize{ 46, 51, 55 };
        const starts = if (style == 0) [_]usize{
            40,
            44,
            43,
            39,
            45,
            41,
            42,
        } else [_]usize{ 60, 65, 66, 59, 64, 63, 62 };
        const choices_rows = if (style == 0) [_]usize{
            26,
            27,
            28,
            31,
            32,
            35,
            36,
        } else [_]usize{ 46, 47, 48, 51, 52, 55, 56 };
        const key = (@as(u32, record.rule_group) << 1) | @as(u32, @intCast(style));
        const profile_index = cached.get(key) orelse create: {
            var profile: runtime.Profile = undefined;
            for (idle_rows, &profile.idle) |row, *clip| clip.* = try resolve(
                allocator,
                &clips,
                animations,
                group.at(row).source,
                resolver,
            );
            const gestures = try allocator.alloc(runtime.Gesture, 7);
            errdefer allocator.free(gestures);
            const finish = if (style == 0) [_]runtime.Posture{
                .watching,
                .resting,
                .resting,
                .watching,
                .leaning,
                .leaning,
                .resting,
            } else [_]runtime.Posture{
                .watching,
                .resting,
                .resting,
                .watching,
                .leaning,
                .resting,
                .leaning,
            };
            for (
                gestures,
                starts,
                choices_rows,
                finish,
                0..,
            ) |*gesture, start, choice, destination, i| {
                const special = style == 1 and i == 2;
                gesture.* = .{
                    .beginning = try resolve(
                        allocator,
                        &clips,
                        animations,
                        group.at(start).source,
                        resolver,
                    ),
                    .finish = destination,
                    .entry_forward = -@as(i16, group.at(choice).dx),
                    .exit_forward = if (i == 2) -@as(
                        i16,
                        group.at(if (special) 69 else 43).dx,
                    ) else 0,
                };
                if (special) {
                    gesture.waiting = try resolve(
                        allocator,
                        &clips,
                        animations,
                        group.at(67).source,
                        resolver,
                    );
                    gesture.ending = try resolve(
                        allocator,
                        &clips,
                        animations,
                        group.at(69).source,
                        resolver,
                    );
                    gesture.release_denominator = group.at(67).conditions[0].argument;
                }
            }
            profile.gestures = gestures;
            var made: usize = 0;
            errdefer for (profile.choices[0..made]) |choices| allocator.free(choices);
            for (&profile.choices, 0..) |*choices, posture| {
                const count: usize = if (posture == 0) 3 else 2;
                const begin: usize = if (posture == 0) 0 else if (posture == 1) 3 else 5;
                const list = try allocator.alloc(runtime.Choice, count);
                for (list, begin..) |*choice, i| choice.* = .{
                    .gesture = i,
                    .denominator = group.at(choices_rows[i]).conditions[0].argument,
                };
                choices.* = list;
                made += 1;
            }
            const result = profiles.items.len;
            try cached.put(key, result);
            try profiles.append(allocator, profile);
            break :create result;
        };
        const initial: runtime.Activity = initial: {
            for (
                idle_rows,
                0..,
            ) |row, i| if (group.at(row).source == record.initial_state) break :initial .{ .idle = @fromBackingInt(@as(
                u2,
                @intCast(i),
            )) };
            for (
                starts,
                0..,
            ) |row, i| if (group.at(row).source == record.initial_state) break :initial .{ .gesture = .{ .index = i } };
            if (style == 1 and
                record.initial_state == group.at(67).source) break :initial .{ .gesture = .{
                .index = 2,
                .part = .waiting,
            } };
            if (style == 1 and
                record.initial_state == group.at(69).source) break :initial .{ .gesture = .{
                .index = 2,
                .part = .ending,
            } };
            return error.UnsupportedAmbientPersonStart;
        };
        try definitions.append(
            allocator,
            .{
                .width = record.collision_width,
                .profile = profile_index,
                .room = rooms[record.room],
                .position = record.position,
                .facing = if (record.facing_right == 0) .left else .right,
                .initial = initial,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
            },
        );
        try sources.append(allocator, @intCast(index));
        table.register(@intCast(index), .ambient_people);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer {
        for (owned_profiles) |profile| {
            for (profile.choices) |choices| allocator.free(choices);
            allocator.free(profile.gestures);
        }
        allocator.free(owned_profiles);
    }
    return .{
        .allocator = allocator,
        .definitions = owned,
        .sources = owned_sources,
        .profiles = owned_profiles,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
