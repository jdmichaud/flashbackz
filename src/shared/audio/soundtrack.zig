//! Own one music cue and keep a short, bounded PCM queue ahead of the native device.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/music.zig");
const score = @import("score.zig");
const music = @import("music_player.zig");
const output_gain = @import("output_gain.zig");

pub const Soundtrack = struct {
    owned: score.Owned,
    player: music.Player,
    volume: u8 = 100,
    pending: [2048]i16 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,

    pub fn open(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        name: []const u8,
        rate: u32,
    ) !Soundtrack {
        const owned = try content.load(allocator, source, name);
        return .{ .owned = owned, .player = music.Player.init(owned.score, rate, null) };
    }
    pub fn deinit(self: *Soundtrack) void {
        self.owned.deinit();
        self.* = undefined;
    }
    pub fn pump(self: *Soundtrack, p: *platform.Platform) !void {
        const ahead = self.player.rate / 20;
        for (0..8) |_| {
            const status = p.audioStatus();
            if (!status.running or status.suspended or status.queued_frames >= ahead) return;
            if (self.pending_start == self.pending_end) {
                const frames: usize = @intCast(@min(
                    self.pending.len / 2,
                    ahead - status.queued_frames,
                ));
                self.pending_start = 0;
                self.pending_end = frames * 2;
                self.player.render(self.pending[0..self.pending_end]);
            }
            const accepted = try output_gain.queue(
                p,
                self.pending[self.pending_start..self.pending_end],
                self.volume,
            );
            self.pending_start += accepted * 2;
            if (accepted == 0) return;
        }
    }
};
