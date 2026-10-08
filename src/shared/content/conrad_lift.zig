//! Riding artwork bound to independent posture names. Validate the original player
//! family has no ordinary hit transitions before keeping these clips invulnerable.
const std = @import("std");
const runtime = @import("../actors/conrad_lift.zig");
const animation = @import("animation.zig");
const rules = @import("rule_table.zig");
const sources = [_]u16{
    169,
    130,
    234,
    235,
    236,
    238,
    237,
    239,
    240,
    243,
    244,
    241,
    242,
    259,
    256,
    245,
    247,
    246,
    248,
    249,
    250,
    260,
    254,
    251,
    258,
    253,
    252,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    clips: []animation.OwnedClip,
    definition: runtime.Clips,
    pub fn deinit(self: *Assets) void {
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
pub fn load(
    allocator: std.mem.Allocator,
    rule_bytes: []const u8,
    group_id: u16,
    animations: []const u8,
    resolver: anytype,
) !Assets {
    const group = try rules.group(rule_bytes, group_id);
    const clips = try allocator.alloc(animation.OwnedClip, sources.len);
    var loaded: usize = 0;
    errdefer {
        for (clips[0..loaded]) |*clip| clip.deinit();
        allocator.free(clips);
    }
    var definition: runtime.Clips = undefined;
    for (sources, clips, &definition.entries) |state, *clip, *entry| {
        var found = false;
        for (0..group.count()) |i| {
            const rule = group.at(i);
            if (rule.source != state) continue;
            found = true;
            for (rule.conditions) |condition| if (condition.code == 107) return error.UnsupportedRidingDamage;
        }
        if (!found) return error.MissingRidingPosture;
        var source = try animation.decode(allocator, animations, state);
        defer source.deinit();
        clip.* = try source.resolve(allocator, resolver);
        loaded += 1;
        entry.* = clip.clip();
    }
    return .{ .allocator = allocator, .clips = clips, .definition = definition };
}
