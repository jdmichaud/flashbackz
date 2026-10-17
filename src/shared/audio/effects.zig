//! Four digital effect voices, mixed in short source blocks and resampled to the output's rate.
//! The simulation submits entry events; the sound never changes game movement.
const std = @import("std");
const sounds = @import("../content/sound_effects.zig");
const megadrive = @import("../content/megadrive.zig");
const megadrive_tunes = @import("megadrive_tunes.zig");
const audio_output = @import("output.zig");

/// A sample of the effects bank.
pub const SoundId = enum(u16) { _ };
pub const Event = struct {
    sound: SoundId,
    attenuation: u2 = 0,
};
const Voice = struct {
    sound: SoundId,
    cursor: usize = 0,
    attenuation: u2,
};
pub const Mixer = struct {
    voices: [4]?Voice = @splat(null),
    block: [70]i8 = @splat(0),
    cursor: usize = 70,
    fraction: u64 = 0,
    pub fn start(self: *Mixer, bank: sounds.Bank, event: Event) void {
        const id = @backingInt(event.sound);
        if (id >= bank.samples.len or bank.samples[id].pcm.len == 0) return;
        var free: ?usize = null;
        for (self.voices, 0..) |voice, i| {
            if (voice) |playing| {
                if (playing.sound == event.sound) {
                    self.voices[i] = .{ .sound = event.sound, .attenuation = event.attenuation };
                    return;
                }
            } else if (free == null) {
                free = i;
            }
        }
        if (free) |index| {
            self.voices[index] = .{ .sound = event.sound, .attenuation = event.attenuation };
        }
    }
    /// Produce the next hardware-sized source block, before host resampling.
    pub fn mixBlock(self: *Mixer, bank: sounds.Bank) *const [70]i8 {
        var first = true;
        @memset(&self.block, 0);
        for (&self.voices) |*slot| if (slot.*) |*voice| {
            const pcm = bank.samples[@backingInt(voice.sound)].pcm;
            // The first source block starts with an odd encoded remainder. Its final
            // byte pair is deferred; a sample shorter than a block therefore ends two
            // samples early and the first voice holds its last decoded amplitude.
            const available = pcm.len - voice.cursor -| @as(usize, if (voice.cursor == 0) 2 else 0);
            const count = @min(self.block.len, available);
            const shift: u3 = @as(u3, voice.attenuation) * 2;
            for (pcm[voice.cursor..][0..count], self.block[0..count]) |sample, *target| {
                const value = sample >> shift;
                if (first) {
                    target.* = value;
                } else {
                    target.* +%= value;
                }
            }
            if (first and count != 0) {
                @memset(self.block[count..], self.block[count - 1]);
            }
            first = false;
            voice.cursor += count;
            if (pcm.len - voice.cursor <= 4) {
                slot.* = null;
            }
        };
        self.cursor = 0;
        return &self.block;
    }
    pub fn render(self: *Mixer, bank: sounds.Bank, output: []i16, rate: u32) void {
        std.debug.assert(output.len % 2 == 0 and rate >= 8000);
        var i: usize = 0;
        while (i < output.len) : (i += 2) {
            if (self.cursor == self.block.len) {
                _ = self.mixBlock(bank);
            }
            const value: i16 = @as(i16, self.block[self.cursor]) * 256;
            output[i] = value;
            output[i + 1] = value;
            // Original Sound Blaster time constant: 256 - floor(1,000,000 / 6000).
            self.fraction += 1_000_000;
            const period = @as(u64, rate) * 166;
            while (self.fraction >= period) {
                self.fraction -= period;
                self.cursor += 1;
                if (self.cursor == self.block.len) {
                    _ = self.mixBlock(bank);
                }
            }
        }
    }
};
/// What a level's sound plays, from the options: the effects with SOUND FX, and the Mega Drive
/// tunes with MUSIC, since they are its music.
pub const Enabled = struct {
    effects: bool,
    tunes: bool,
};

/// A level's sound: four effect voices and, when the user gave the Mega Drive cartridge (PLAN
/// MD-D), its tunes, which its effects 68-75 play where the DOS bank has no sample.
pub const Player = struct {
    mixer: Mixer = .{},
    /// The tunes on the cartridge's chips.
    tunes: ?megadrive_tunes.Output = null,
    /// What the options last let play.
    enabled: Enabled = .{ .effects = true, .tunes = true },
    /// Whether anything played since the last stop: the sound starts with its first effect.
    started: bool = false,

    pub fn init(tunes: ?*const megadrive.Tunes) Player {
        return .{ .tunes = if (tunes) |t| .init(t, audio_output.format.sample_rate) else null };
    }

    /// Plays `event`, an effect or a tune, if what it is is enabled.
    pub fn submit(self: *Player, bank: sounds.Bank, event: Event, enabled: Enabled) void {
        const id = @backingInt(event.sound);
        if (self.tunes) |*tunes|
            if (id >= megadrive.first_tune and id < megadrive.first_tune + megadrive.tune_count) {
                // As in the cartridge, a tune asked for restarts the tunes' player with it.
                if (!enabled.tunes) return;
                tunes.player.start(id - megadrive.first_tune);
                self.started = true;
                return;
            };
        if (!enabled.effects) return;
        self.mixer.start(bank, event);
        self.started = true;
    }

    /// The next `out.len / 2` stereo frames at the output's rate.
    pub fn render(self: *Player, bank: sounds.Bank, out: []i16) void {
        self.mixer.render(bank, out, audio_output.format.sample_rate);
        if (self.tunes) |*tunes| {
            tunes.mixInto(out);
        }
    }

    /// Stops what the options turned off; everything when both are off.
    pub fn enable(self: *Player, enabled: Enabled) void {
        if (!enabled.effects and !enabled.tunes) {
            self.stop();
        } else {
            if (self.enabled.effects and !enabled.effects) {
                self.mixer = .{};
            }
            if (self.enabled.tunes and !enabled.tunes) {
                self.stopTunes();
            }
        }
        self.enabled = enabled;
    }

    /// Stops everything, as a film does in the cartridge.
    pub fn stop(self: *Player) void {
        self.mixer = .{};
        self.stopTunes();
        self.started = false;
    }

    fn stopTunes(self: *Player) void {
        if (self.tunes) |*tunes| {
            tunes.* = .init(tunes.player.tunes, audio_output.format.sample_rate);
        }
    }
};

test "effects mixer restarts identical cues and preserves wrapping byte mixing" {
    var positive: [72]i8 = @splat(100);
    var samples = [_]sounds.Sample{.{ .pcm = &positive }, .{ .pcm = &positive }};
    const bank: sounds.Bank = .{ .allocator = std.testing.allocator, .samples = &samples };
    var mixer: Mixer = .{};
    mixer.start(bank, .{ .sound = @fromBackingInt(0) });
    mixer.start(bank, .{ .sound = @fromBackingInt(0) });
    try std.testing.expect(mixer.voices[1] == null);
    mixer.start(bank, .{ .sound = @fromBackingInt(1) });
    var output: [2]i16 = undefined;
    mixer.render(bank, &output, 44100);
    try std.testing.expectEqual(@as(i16, -56 * 256), output[0]);
    try std.testing.expectEqual(output[0], output[1]);
}

test "a short initial effect holds the original decoder's final available amplitude" {
    var pcm = [_]i8{ 117, 117, 118, 120, 123, -112 };
    var samples = [_]sounds.Sample{.{ .pcm = &pcm }};
    const bank: sounds.Bank = .{ .allocator = std.testing.allocator, .samples = &samples };
    var mixer: Mixer = .{};
    mixer.start(bank, .{ .sound = @fromBackingInt(0) });
    const block = mixer.mixBlock(bank);
    try std.testing.expectEqualSlices(i8, &.{ 117, 117, 118, 120 }, block[0..4]);
    for (block[4..]) |value| {
        try std.testing.expectEqual(@as(i8, 120), value);
    }
    try std.testing.expect(mixer.voices[0] == null);
}

test "SOUND FX starts the effects and MUSIC the Mega Drive tunes; turned off, they stop" {
    const tunes = megadrive_tunes.testTunes(&.{.{ 1, 1, 0, 0, 0, 0 }}, 5, 0);
    var pcm: [72]i8 = @splat(100);
    var samples = [_]sounds.Sample{.{ .pcm = &pcm }};
    const bank: sounds.Bank = .{ .allocator = std.testing.allocator, .samples = &samples };
    const tune: Event = .{ .sound = @fromBackingInt(megadrive.first_tune + 2) };
    const effect: Event = .{ .sound = @fromBackingInt(0) };
    var player: Player = .init(&tunes);
    player.submit(bank, tune, .{ .effects = true, .tunes = false });
    player.submit(bank, effect, .{ .effects = false, .tunes = true });
    try std.testing.expect(!player.started);
    try std.testing.expect(!player.tunes.?.player.playing() and player.mixer.voices[0] == null);
    player.submit(bank, tune, .{ .effects = false, .tunes = true });
    try std.testing.expect(player.started and player.tunes.?.player.playing());
    player.submit(bank, effect, .{ .effects = true, .tunes = false });
    try std.testing.expect(player.mixer.voices[0] != null);
    player.enable(.{ .effects = true, .tunes = false });
    try std.testing.expect(!player.tunes.?.player.playing() and player.mixer.voices[0] != null);
    player.enable(.{ .effects = false, .tunes = false });
    try std.testing.expect(!player.started and player.mixer.voices[0] == null);
}
