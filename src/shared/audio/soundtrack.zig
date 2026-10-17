//! One music cue: a score and the OPL music player that renders it at the output's rate.
//! The scenes with music own their `Soundtrack`: the title menu, the films and the ending.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/music.zig");
const score = @import("../content/score.zig");
const music_player = @import("music_player.zig");
const output = @import("output.zig");

pub const Soundtrack = struct {
    /// The score, in its own arena.
    owned: score.Owned,
    /// The player, with its own OPL chip.
    player: music_player.Player,
    /// False until `output.Output.pump` first gets this music; only `pump` reads and sets it.
    /// While it is false, `pump` clears the queue, so the new music replaces what was queued.
    heard: bool = false,

    /// Loads the cue `name` (its profile, its MIDI file and its instruments) at tick 0.
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
