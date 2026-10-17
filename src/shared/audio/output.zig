//! The game's one audio output (DESIGN 6). The game owns it. It opens the device once, at the
//! format that every source renders at. A device that fails leaves the game silent. It never
//! ends the game.
//!
//! The scenes own the sources: a `Soundtrack` or the level's `effects.Player`. The level pack
//! owns the effects `Bank`. `pump` borrows them as `Sources` for one call, and does these steps:
//! 1. It clears the queue when a new music starts or a source stops.
//! 2. It mixes the sources in chunks of at most 1,024 frames, then applies the volume.
//! 3. It queues the chunks until the device holds `lead_frames`.
//! A source advances only by the frames mixed. Thus a music stops while the device stalls or
//! while the music is not a source.
const std = @import("std");
const platform = @import("../platform.zig");
const sounds = @import("../content/sound_effects.zig");
const soundtrack = @import("soundtrack.zig");
const effects = @import("effects.zig");

/// Every source renders at this rate, in stereo; the host converts it to what the device plays.
pub const format: platform.AudioFormat = .{ .channels = 2, .sample_rate = 44100 };

/// How far ahead of the device the queue is kept: 35 ms. A device takes a period at a time
/// (SDL's 512 frames are 11.6 ms at 44.1 kHz), and the queue is topped up once a host frame
/// (16.7 ms at 60 Hz), so less than a period plus a frame leaves the device short, and SDL plays
/// silence for the rest of the period. A sound is heard within the lead and a period, about
/// 47 ms; the original takes about 12 ms. A host frame that takes longer than the lead (a
/// level loading) leaves a gap of silence.
pub const lead_frames = format.sample_rate * 35 / 1000;

/// What plays at a moment: a music (the title's, a film's, the ending's) and a level's sound.
/// The scenes own them; `pump` borrows them for one call.
pub const Sources = struct {
    music: ?*soundtrack.Soundtrack = null,
    level: ?Level = null,

    /// A level's effects and tunes, with the samples of its effects.
    pub const Level = struct {
        sound: *effects.Player,
        /// The level pack owns it.
        bank: sounds.Bank,
    };
};

pub const Output = struct {
    /// A device that failed stays `failed` until `close`: the game is then silent.
    state: enum { closed, open, failed } = .closed,
    /// The VOLUME setting, 0 to 100 percent, applied to the whole mix (`gain`). The game sets it
    /// before each `pump`. The music has a separate volume (`music_player.Player.master_volume`).
    volume: u8 = 100,
    /// One chunk: mixed and not yet queued (stereo, interleaved). `begin` and `end` give the
    /// samples that the host did not accept yet.
    pending: [2048]i16 = undefined,
    begin: usize = 0,
    end: usize = 0,
    /// The sources at the last `pump`. When one of them goes, `pump` drops what it had queued.
    played: struct { music: bool = false, level: bool = false } = .{},

    /// Keeps the queue `lead_frames` ahead of the device, with `sources` mixed. It clears the
    /// queue when a music starts that it did not get before (`heard` is false), or when the
    /// music or the level sound of the last call is gone.
    pub fn pump(self: *Output, p: *platform.Platform, sources: Sources) void {
        const fresh_music = if (sources.music) |music| !music.heard else false;
        if (fresh_music or
            (self.played.music and sources.music == null) or
            (self.played.level and sources.level == null)) {
            self.cut(p);
        }
        self.played = .{ .music = sources.music != null, .level = sources.level != null };
        if (sources.music == null and sources.level == null) return;
        if (sources.music) |music| {
            music.heard = true;
        }
        if (self.state == .closed) {
            self.open(p);
        }
        if (self.state != .open) return;
        // At most 8 passes. A pass mixes a new chunk when the host took all of the last one,
        // then queues what the host accepts. The sources advance only here, by the frames mixed.
        // Two full chunks fill an empty lead.
        for (0..8) |_| {
            const status = p.audioStatus();
            if (!status.running or status.suspended or status.queued_frames >= lead_frames) return;
            if (self.begin == self.end) {
                const frames: usize = @intCast(
                    @min(self.pending.len / 2, lead_frames - status.queued_frames),
                );
                self.begin = 0;
                self.end = frames * 2;
                mix(sources, self.pending[0..self.end], self.volume);
            }
            const accepted = p.audioQueue(self.pending[self.begin..self.end]) catch |err| {
                return self.fail(p, err);
            };
            self.begin += accepted * 2;
            if (accepted == 0) return;
        }
    }

    /// Closes the device, at the game's end.
    pub fn close(self: *Output, p: *platform.Platform) void {
        if (self.state == .open) {
            p.audioClear();
            p.audioClose();
        }
        self.* = .{ .volume = self.volume };
    }

    fn open(self: *Output, p: *platform.Platform) void {
        p.audioOpen(format) catch |err| return self.fail(p, err);
        self.state = .open;
    }

    fn fail(self: *Output, p: *platform.Platform, err: platform.PlatformError) void {
        if (err != error.Unsupported) {
            std.log.err("no sound: the audio device failed ({s})", .{ @errorName(err) });
        }
        if (self.state == .open) {
            p.audioClose();
        }
        self.state = .failed;
    }

    /// Drops what is mixed and queued.
    fn cut(self: *Output, p: *platform.Platform) void {
        if (self.state == .open) {
            p.audioClear();
        }
        self.begin = 0;
        self.end = 0;
    }
};

/// Writes the sources' next `out.len / 2` frames to `out`, at `volume` percent. The sum clips at
/// the limits of 16 bits before the volume applies.
fn mix(sources: Sources, out: []i16, volume: u8) void {
    @memset(out, 0);
    var part: [2048]i16 = undefined;
    if (sources.music) |music| {
        music.player.render(part[0..out.len]);
        add(out, part[0..out.len]);
    }
    if (sources.level) |level| {
        level.sound.render(level.bank, part[0..out.len]);
        add(out, part[0..out.len]);
    }
    scale(out, volume);
}

/// Returns the gain of the VOLUME option, in 1/65,536ths. Each percent below 100 removes 0.4 dB.
/// Thus each step of 10% is 4 dB and the steps sound even. 20% is -32 dB, and 0% is silent.
pub fn gain(volume: u8) u32 {
    if (volume == 0) return 0;
    if (volume >= 100) return 1 << 16;
    const decibels = (@as(f64, @floatFromInt(volume)) - 100) * 0.4;
    return @intFromFloat(@round(std.math.pow(f64, 10, decibels / 20) * (1 << 16)));
}

fn scale(samples: []i16, volume: u8) void {
    if (volume >= 100) return;
    const factor: i64 = gain(volume);
    for (samples) |*sample| {
        sample.* = @intCast((@as(i64, sample.*) * factor) >> 16);
    }
}

fn add(sum: []i16, part: []const i16) void {
    for (sum, part) |*total, sample| {
        total.* = @intCast(
            std.math.clamp(@as(i32, total.*) + sample, std.math.minInt(i16), std.math.maxInt(i16)),
        );
    }
}

test "the master volume keeps the full range, takes 4 dB a step and mutes" {
    const input = [_]i16{ -32768, -101, 0, 101, 32767 };
    var samples = input;
    scale(&samples, 100);
    try std.testing.expectEqualSlices(i16, &input, &samples);
    // 50% is -20 dB: a tenth.
    samples = input;
    scale(&samples, 50);
    try std.testing.expectEqualSlices(i16, &.{ -3277, -11, 0, 10, 3276 }, &samples);
    samples = input;
    scale(&samples, 0);
    try std.testing.expectEqualSlices(i16, &.{ 0, 0, 0, 0, 0 }, &samples);
    var step: u8 = 10;
    while (step <= 100) : (step += 10) {
        const ratio = @as(f64, @floatFromInt(gain(step))) /
            @as(f64, @floatFromInt(gain(step - 10)));
        if (step > 10) {
            try std.testing.expectApproxEqAbs(4.0, 20 * std.math.log10(ratio), 0.01);
        }
    }
}

test "sources add, short of clipping" {
    var sum = [_]i16{ 30000, -30000, 5 };
    add(&sum, &.{ 10000, -10000, -7 });
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32768, -2 }, &sum);
}
