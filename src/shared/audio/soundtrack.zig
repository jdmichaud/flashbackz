//! One music cue: the OPL music player over a score, rendered at the output's rate.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/music.zig");
const score = @import("../content/score.zig");
const music_player = @import("music_player.zig");
const output = @import("output.zig");

pub const Soundtrack = struct {
    owned: score.Owned,
    player: music_player.Player,
    /// Set once the output plays it: a new music replaces what was queued before it.
    heard: bool = false,

    pub fn open(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        name: []const u8,
    ) !Soundtrack {
        const owned = try content.load(allocator, source, name);
        return .{
            .owned = owned,
            .player = music_player.Player.init(owned.score, output.format.sample_rate, null),
        };
    }
    pub fn deinit(self: *Soundtrack) void {
        self.owned.deinit();
        self.* = undefined;
    }
};
