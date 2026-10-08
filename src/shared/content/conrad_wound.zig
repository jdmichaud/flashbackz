//! Bind injury artwork and posture-sensitive hit entries. Only semantic recovery phases,
//! geometric overrides and opaque profile IDs survive the content boundary.
const std = @import("std");
const runtime = @import("../actors/conrad_wound.zig");
const animation = @import("animation.zig");
const rules = @import("rule_table.zig");
const motion = @import("../motion.zig");
const sources = [_]u16{
    78,
    75,
    94,
    96,
    229,
    85,
    84,
    83,
    111,
    74,
    103,
    171,
    80,
    79,
    81,
    97,
    98,
    113,
    110,
    99,
    172,
    106,
    227,
    228,
    82,
    118,
    114,
    116,
    117,
    119,
    120,
    86,
    108,
    109,
    73,
};
comptime {
    if (sources.len != runtime.phase_count) @compileError("injury motion catalog mismatch");
}

pub const Assets = struct {
    allocator: std.mem.Allocator,
    motions: []animation.OwnedClip,
    policies: []runtime.Policy,
    death_wait: u16,
    pub fn deinit(self: *Assets) void {
        for (self.motions) |*clip| clip.deinit();
        self.allocator.free(self.motions);
        self.allocator.free(self.policies);
    }
    pub fn definition(self: Assets) runtime.Definition {
        var clips: [runtime.phase_count]motion.Clip = undefined;
        for (self.motions, &clips) |*source, *destination| destination.* = source.clip();
        return .{ .clips = clips, .policies = self.policies, .death_wait_steps = self.death_wait };
    }
};
fn entry(rule: rules.Rule) !runtime.Entry {
    const phase: runtime.Phase = switch (rule.target) {
        78 => .front_impact,
        75 => .rear_impact,
        85 => .backward_confined,
        98 => .forward_confined,
        96 => .backward_airborne,
        229 => .backward_ceiling,
        118 => .forward_airborne,
        117 => .forward_low_confined,
        else => return error.UnsupportedPlayerHitEntry,
    };
    if (rule.effect.code != 0 or rule.flags & ~@as(
        u8,
        3,
    ) != 0) return error.UnsupportedPlayerHitEffect;
    return .{
        .phase = phase,
        .forward = -@as(i16, rule.dx),
        .down = rule.dy,
        .turn = rule.flags & 1 != 0,
        .damage = rule.flags & 2 != 0,
    };
}
fn policy(group: rules.Group, state: u16) !runtime.Policy {
    var result: runtime.Policy = .{};
    for (&result.responses, 0..) |*response, impact| {
        const message: i16 = @intCast(impact + 1);
        for (0..group.count()) |i| {
            const rule = group.at(i);
            if (rule.source != state) continue;
            const predicate = rule.conditions[0];
            if (!(predicate.code == 34 and
                predicate.argument == message or
                predicate.code == 107 and
                    (if (predicate.argument == 0) message <= 2 else message >= 3))) continue;
            const secondary = rule.conditions[1];
            if (secondary.code == 0) {
                if (response.normal != null) return error.AmbiguousPlayerHit;
                response.normal = try entry(rule);
            } else {
                if (response.obstructed != null or
                    response.normal != null) return error.UnsupportedPlayerHitPriority;
                response.obstructed = try entry(rule);
                response.obstruction = switch (secondary.code) {
                    14 => .{ .wall_ahead = secondary.argument },
                    18 => .supported,
                    41, 42 => .{ .wall_edge = .{
                        .ahead = -secondary.argument,
                        .blocked_forward = secondary.code == 41,
                    } },
                    else => return error.UnsupportedPlayerHitCondition,
                };
            }
        }
    }
    var used: [4]bool = @splat(false);
    var next: usize = 0;
    for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source != state) continue;
        const predicate = rule.conditions[0];
        for (0..4) |impact| {
            const message: i16 = @intCast(impact + 1);
            if (!used[impact] and
                (predicate.code == 34 and
                    predicate.argument == message or
                    predicate.code == 107 and
                        (if (predicate.argument == 0) message <= 2 else message >= 3)))
            {
                result.priority[next] = @fromBackingInt(@as(u2, @intCast(impact)));
                used[impact] = true;
                next += 1;
            }
        }
    }
    for (used, 0..) |seen, impact| if (!seen) {
        result.priority[next] = @fromBackingInt(@as(u2, @intCast(impact)));
        next += 1;
    };
    return result;
}
pub fn load(
    allocator: std.mem.Allocator,
    rule_bytes: []const u8,
    group_id: u16,
    animations: []const u8,
    motion_sources: []const u16,
    resolver: anytype,
) !Assets {
    const group = try rules.group(rule_bytes, group_id);
    const policies = try allocator.alloc(runtime.Policy, motion_sources.len);
    errdefer allocator.free(policies);
    for (motion_sources, policies) |state, *destination| destination.* = try policy(group, state);
    const clips = try allocator.alloc(animation.OwnedClip, sources.len);
    var loaded: usize = 0;
    errdefer {
        for (clips[0..loaded]) |*clip| clip.deinit();
        allocator.free(clips);
    }
    for (sources, clips) |state, *destination| {
        var source = try animation.decode(allocator, animations, state);
        defer source.deinit();
        destination.* = try source.resolve(allocator, resolver);
        loaded += 1;
    }
    const death_wait: u16 = for (0..group.count()) |i| {
        const rule = group.at(i);
        if (rule.source == 74 and rule.conditions[0].code == 39 and rule.effect.code == 79) {
            if (rule.effect.argument <= 0) return error.InvalidPlayerDeathWait;
            break @intCast(rule.effect.argument);
        }
    } else return error.MissingPlayerDeathWait;
    return .{
        .allocator = allocator,
        .motions = clips,
        .policies = policies,
        .death_wait = death_wait,
    };
}
