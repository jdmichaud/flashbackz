//! A story interlude temporarily owns presentation and audio while the world is paused.
const std = @import("std");
const platform = @import("../platform.zig");
const vector = @import("vector_player.zig");
const audio = @import("../audio/soundtrack.zig");
const props = @import("../world_props.zig");
pub const Story = struct {
    kind: props.Movie,
    player: vector.Player,
    music: audio.Soundtrack,
    started_ns: u64,
    audio_open: bool = false,
    music_enabled: bool = true,
    skip: bool = false,
    activation_key: ?platform.Key,

    pub fn open(allocator: std.mem.Allocator, source: platform.AssetSource, kind: props.Movie, now: u64, activation: ?platform.Key) !Story {
        const cue: struct { film: []const u8, entry: u16, music: []const u8 } = switch (kind) {
            .holocube_pickup => .{ .film = "OBJET", .entry = 3, .music = "OBJET3" },
            .disintegration => .{ .film = "DESINTEG", .entry = 0, .music = "DESINTE3" },
            .holocube_recording => .{ .film = "HOLOSEQ", .entry = 0, .music = "HOLO3" },
        };
        var player = try vector.Player.open(allocator, source, cue.film, cue.entry);
        errdefer player.deinit();
        return .{ .kind = kind, .player = player, .music = try audio.Soundtrack.open(allocator, source, cue.music, 44100), .started_ns = now, .activation_key = activation };
    }
    pub fn deinit(self: *Story) void {
        self.player.deinit();
        self.music.deinit();
        self.* = undefined;
    }
    pub fn stopAudio(self: *Story, p: *platform.Platform) void {
        if (self.audio_open) {
            p.audioClear();
            p.audioClose();
            self.audio_open = false;
        }
    }
    pub fn update(self: *Story, p: *platform.Platform) !bool {
        if (self.skip or try self.player.update(p.nowNs())) return true;
        if (!self.music_enabled) {
            self.stopAudio(p);
            return false;
        }
        if (!self.audio_open) {
            const format = try p.audioOpen(.{ .channels = 2, .sample_rate = 44100 });
            if (format.channels != 2 or format.sample_rate != 44100) {
                p.audioClose();
                return error.UnsupportedAudioFormat;
            }
            self.audio_open = true;
        }
        try self.music.pump(p);
        return false;
    }
    pub fn event(self: *Story, input: platform.Event) bool {
        switch (input.payload) {
            .key_up => |key| {
                if (self.activation_key == key.key) self.activation_key = null;
                return false;
            },
            .focus_lost => {
                self.activation_key = null;
                return false;
            },
            .key_down => |key| {
                const skip = switch (key.key) {
                    .tab, .escape, .enter, .space, .left_shift, .right_shift => true,
                    else => false,
                };
                if (skip and !key.repeat and self.activation_key != key.key) self.skip = true;
                return skip;
            },
            else => return false,
        }
    }
};
