//! A film with its music, which owns presentation and audio while the world waits.
const std = @import("std");
const platform = @import("../platform.zig");
const vector = @import("vector_player.zig");
const audio = @import("../audio/soundtrack.zig");
pub const Story = struct {
    player: vector.Player,
    music: ?audio.Soundtrack,
    started_ns: u64,
    audio_open: bool = false,
    music_enabled: bool = true,
    skip: bool = false,
    activation_key: ?platform.Key,

    /// Plays entry `entry` of film `film`, with the music file `music` if any.
    pub fn openFilm(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        film: []const u8,
        entry: u16,
        music: ?[]const u8,
        now: u64,
        activation: ?platform.Key,
    ) !Story {
        var player = try vector.Player.open(allocator, source, film, entry);
        errdefer player.deinit();
        return .{
            .player = player,
            .music = if (music) |name| try audio.Soundtrack.open(allocator, source, name, 44100) else null,
            .started_ns = now,
            .activation_key = activation,
        };
    }

    pub fn deinit(self: *Story) void {
        self.player.deinit();
        if (self.music) |*music| music.deinit();
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
        if (!self.music_enabled or self.music == null) {
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
        try self.music.?.pump(p);
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
                if (self.player.interactive() and key.key != .tab and key.key != .escape) {
                    const confirm = key.key == .enter or
                        key.key == .space or
                        key.key == .left_shift or
                        key.key == .right_shift;
                    if (confirm and
                        !key.repeat and
                        self.activation_key != key.key) self.player.confirm();
                    return confirm;
                }
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
