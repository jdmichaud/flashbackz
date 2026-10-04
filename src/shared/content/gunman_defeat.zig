//! Identify directional defeat trajectories from the recovered gunman family.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const motion = @import("../motion.zig");
const runtime = @import("../actors/gunman_defeat.zig");

fn find(group: rules.Group, state: u16, code: u8, ordinal: usize) !rules.Rule {
    var seen: usize = 0;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source != state) continue;
        const matches = if (code == 0) r.conditions[0].code == 0 and r.conditions[1].code == 0 else r.conditions[0].code == code or r.conditions[1].code == code;
        if (!matches) continue;
        if (seen == ordinal) return r;
        seen += 1;
    }
    return error.UnsupportedGunmanDefeat;
}
fn clip(allocator: std.mem.Allocator, animations: []const u8, state: u16, owned: *std.ArrayList(animation.OwnedClip), resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    var resolved = try source.resolve(allocator, resolver);
    errdefer resolved.deinit();
    try owned.append(allocator, resolved);
    return resolved.clip();
}
fn move(allocator: std.mem.Allocator, animations: []const u8, rule: rules.Rule, owned: *std.ArrayList(animation.OwnedClip), resolver: anytype) !runtime.Move {
    return .{ .clip = try clip(allocator, animations, rule.target, owned, resolver), .forward = -@as(i16, rule.dx), .down = rule.dy };
}
pub fn track(allocator: std.mem.Allocator, group: rules.Group, animations: []const u8, impact: u16, backward: bool, owned: *std.ArrayList(animation.OwnedClip), resolver: anytype) !runtime.Track {
    var result: runtime.Track = undefined;
    result.impact = try clip(allocator, animations, impact, owned, resolver);
    var fall: ?u16 = null;
    var free_flight: u16 = undefined;
    for (&result.paths, 0..) |*path, i| {
        const launch = try find(group, impact, if (i == 4) 0 else if (backward) 16 else 14, if (i == 4) 0 else i);
        const flight = launch.target;
        if (i == 4) free_flight = flight;
        const landing = try find(group, flight, 0, 0);
        const drop = try find(group, flight, if (backward) 26 else 27, 0);
        if (fall != null and fall.? != drop.target) return error.UnsupportedGunmanFall;
        fall = drop.target;
        path.* = .{ .launch = try move(allocator, animations, launch, owned, resolver), .landing = try move(allocator, animations, landing, owned, resolver), .drop = try move(allocator, animations, drop, owned, resolver) };
    }
    result.ledge_launch = if (backward) null else try move(allocator, animations, try find(group, impact, 32, 0), owned, resolver);
    result.ledge_landing = if (backward) try move(allocator, animations, try find(group, free_flight, 32, 0), owned, resolver) else null;
    result.fall = try move(allocator, animations, try find(group, fall.?, if (backward) 27 else 0, 0), owned, resolver);
    result.ledge_fall = if (backward) null else try move(allocator, animations, try find(group, fall.?, 32, 0), owned, resolver);
    const landing = try find(group, fall.?, if (backward) 0 else 18, 0);
    result.fall_landing = try move(allocator, animations, landing, owned, resolver);
    const rest = try find(group, landing.target, 0, 0);
    result.rest = try clip(allocator, animations, rest.target, owned, resolver);
    result.mark_dead = (try find(group, rest.target, 0, 0)).flags & 8 != 0;
    return result;
}
