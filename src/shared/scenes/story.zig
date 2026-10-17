//! A film with its music, shown while the world waits.
//!
//! The film ends when `update` returns true. Game reads the result and then resumes the level.
const std = @import("std");
const platform = @import("../platform.zig");
const vector = @import("vector_player.zig");
const audio = @import("../audio/soundtrack.zig");
pub const Story = struct {
    player: vector.Player,
    music: ?audio.Soundtrack,
    started_ns: u64,
    music_enabled: bool = true,
    skip: bool = false,

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
            .music = if (music) |name| try audio.Soundtrack.open(allocator, source, name) else null,
            .started_ns = now,
        };
    }

    pub fn deinit(self: *Story) void {
        self.player.deinit();
        if (self.music) |*music| {
            music.deinit();
        }
        self.* = undefined;
    }
    /// True when the film is over or skipped.
    pub fn update(self: *Story, now_ns: u64) !bool {
        // A held film does not look at its keys.
        if (self.player.paused_at != null) {
            self.skip = false;
        }
        return self.skip or try self.player.update(now_ns);
    }
    /// The film's music, with the MUSIC option.
    pub fn sound(self: *Story) ?*audio.Soundtrack {
        if (!self.music_enabled) return null;
        return if (self.music) |*music| music else null;
    }
    /// The film's keys: Backspace, Tab or Escape skips it, and Enter, Space or Shift turns an
    /// interactive page; with the `joystick` option, the joystick's buttons do as the keys do.
    /// True when the film took the event.
    pub fn event(self: *Story, input: platform.Event, joystick: bool) bool {
        if (vector.skips(input.payload, joystick)) {
            self.skip = true;
            return true;
        }
        switch (input.payload) {
            .key_down => |press| switch (press.key) {
                .enter, .space, .left_shift, .right_shift => if (!press.repeat)
                    self.player.confirm(),
                .tab, .backspace, .escape => {},
                else => return false,
            },
            .controller_button_down => |change| switch (change.button) {
                .a, .b, .x => if (joystick) self.player.confirm() else return false,
                else => return false,
            },
            else => return false,
        }
        return true;
    }
};
