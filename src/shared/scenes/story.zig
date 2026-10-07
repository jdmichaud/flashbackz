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
            .delivery_briefing => .{ .film = "MISSIONS", .entry = 0, .music = "MISSION3" },
            .escort_briefing => .{ .film = "MISSIONS", .entry = 1, .music = "MISSION3" },
            .android_briefing => .{ .film = "MISSIONS", .entry = 2, .music = "MISSION3" },
            .reactor_briefing => .{ .film = "MISSIONS", .entry = 3, .music = "MISSION3" },
            .mutant_briefing => .{ .film = "MISSIONS", .entry = 4, .music = "MISSION3" },
            .mission_accepted => .{ .film = "MISSIONS", .entry = 5, .music = "MISVALI3" },
            .delivery_completed => .{ .film = "MISSIONS", .entry = 6, .music = "MISSION3" },
            .escort_completed => .{ .film = "MISSIONS", .entry = 7, .music = "MISSION3" },
            .android_completed => .{ .film = "MISSIONS", .entry = 8, .music = "MISSION3" },
            .reactor_completed => .{ .film = "MISSIONS", .entry = 9, .music = "MISSION3" },
            .mutant_completed => .{ .film = "MISSIONS", .entry = 10, .music = "MISSION3" },
            .papers_received => .{ .film = "OBJET", .entry = 15, .music = "DONNER3" },
            .parcel_received => .{ .film = "OBJET", .entry = 12, .music = "DONNER3" },
            .parcel_delivered => .{ .film = "OBJET", .entry = 13, .music = "DONNER3" },
            .card_delivery => .{ .film = "OBJET", .entry = 8, .music = "DONNER3" },
            .permit_received => .{ .film = "OBJET", .entry = 14, .music = "DONNER3" },
            .memory_restoration => .{ .film = "MEMO", .entry = 0, .music = "MEMORY3" },
            .earth_arrival => .{ .film = "VOYAGE", .entry = 0, .music = "VOYAGE3" },
            .spaceport_arrival => .{ .film = "ESPIONS", .entry = 0, .music = "CAPTURE3" },
            .alien_arrival => .{ .film = "TELEPORT", .entry = 0, .music = "TELEPOR3" },
            .city_arrival => .{ .film = "CHUTE", .entry = 1, .music = "CHUTE3" },
            .credit_payment => .{ .film = "OBJET", .entry = 7, .music = "DONNER3" },
            .anti_g_received => .{ .film = "OBJET", .entry = 9, .music = "DONNER3" },
            .teleporter_pickup => .{ .film = "OBJET", .entry = 5, .music = "OBJET3" },
            .teleporter_delivery => .{ .film = "OBJET", .entry = 10, .music = "DONNER3" },
            .id_card_pickup => .{ .film = "OBJET", .entry = 6, .music = "OBJET3" },
            .cartridge_pickup => .{ .film = "OBJET", .entry = 11, .music = "OBJET3" },
            .cartridge_recharge => .{ .film = "GEN", .entry = 1, .music = "RECHAGE3" },
            .bridge_activation => .{ .film = "PONT", .entry = 0, .music = "PONT3" },
            .shield_recharge => .{ .film = "GEN", .entry = 0, .music = "RECHAGE3" },
            .lift_ascent => .{ .film = "LIFT", .entry = 0, .music = "LIFT3" },
            .lift_descent => .{ .film = "LIFT", .entry = 1, .music = "LIFT3" },
            .credits_pickup => .{ .film = "OBJET", .entry = 1, .music = "OBJET3" },
            .fuse_pickup => .{ .film = "OBJET", .entry = 16, .music = "OBJET3" },
            .key_pickup => .{ .film = "OBJET", .entry = 4, .music = "OBJET3" },
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
                if (self.player.interactive() and key.key != .tab and key.key != .escape) {
                    const confirm = key.key == .enter or key.key == .space or key.key == .left_shift or key.key == .right_shift;
                    if (confirm and !key.repeat and self.activation_key != key.key) self.player.confirm();
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
