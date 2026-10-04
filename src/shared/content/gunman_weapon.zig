//! Recover the shared gunman emitter's posture clips and impact placement.
const std = @import("std");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const motion = @import("../motion.zig");
const pistol = @import("../pistol_shot.zig");
fn clip(allocator: std.mem.Allocator, animations: []const u8, state: u16, owned: *std.ArrayList(animation.OwnedClip), resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    var result = try source.resolve(allocator, resolver);
    errdefer result.deinit();
    try owned.append(allocator, result);
    return result.clip();
}
pub fn load(allocator: std.mem.Allocator, record: @import("placement.zig").Record, rule_bytes: []const u8, animations: []const u8, owned: *std.ArrayList(animation.OwnedClip), resolver: anytype) !pistol.Definition {
    const group = try rules.group(rule_bytes, record.rule_group);
    if (record.parameters[0] <= 0 or record.parameters[0] > 64) return error.InvalidEnemyWeaponRange;
    var flashes: [2]motion.Clip = undefined;
    var impacts: [2]motion.Clip = undefined;
    var forward: [2]i16 = undefined;
    var down: [2]i16 = undefined;
    for (0..2) |height| {
        const message: i16 = @intCast(40 + height);
        const start = for (0..group.count()) |i| {
            const rule = group.at(i);
            if (rule.source == record.initial_state and rule.conditions[0].code == 34 and rule.conditions[0].argument == message and rule.conditions[1].code == 96 and rule.conditions[1].argument == message) break rule.target;
        } else return error.UnsupportedEnemyWeaponStart;
        flashes[height] = try clip(allocator, animations, start, owned, resolver);
        const impact = for (0..group.count()) |i| {
            const rule = group.at(i);
            if (rule.source == start and rule.conditions[1].code == 95) break rule;
        } else return error.UnsupportedEnemyWeaponImpact;
        impacts[height] = try clip(allocator, animations, impact.target, owned, resolver);
        forward[height] = -@as(i16, impact.dx);
        down[height] = -@as(i16, impact.dy);
    }
    return .{ .initial_phase = .flash, .ignition = flashes[0], .standing_flash = flashes[0], .crouched_flash = flashes[1], .standing_impact = impacts[0], .crouched_impact = impacts[1], .range_cells = @intCast(record.parameters[0]), .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .impact_forward = forward, .impact_down = down };
}
