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
    /// The joystick option: the joystick's buttons turn pages and skip as the keys do.
    joystick: bool = false,

    /// Plays entry `entry` of film `film`, with the music file `music` if any.
    pub fn openFilm(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        film: []const u8,
        entry: u16,
        music: ?[]const u8,
        now: u64,
    ) !Story {
        var player = try vector.Player.open(allocator, source, film, entry);
        errdefer player.deinit();
        return .{
            .player = player,
            .music = if (music) |name| try audio.Soundtrack.open(allocator, source, name, 44100) else null,
            .started_ns = now,
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
        // A held film does not look at its keys.
        if (self.player.paused_at != null) self.skip = false;
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
    /// The film's keys: Backspace or Tab skips it, and Enter, Space or Shift turns an
    /// interactive page. True when the film took the event.
    pub fn event(self: *Story, input: platform.Event) bool {
        if (vector.skips(input.payload, self.joystick)) {
            self.skip = true;
            return true;
        }
        switch (input.payload) {
            .key_down => |press| switch (press.key) {
                .enter, .space, .left_shift, .right_shift => if (!press.repeat) self.player.confirm(),
                .tab, .backspace => {},
                else => return false,
            },
            .controller_button_down => |change| switch (change.button) {
                .a, .b, .x => if (self.joystick) self.player.confirm() else return false,
                else => return false,
            },
            else => return false,
        }
        return true;
    }
};
