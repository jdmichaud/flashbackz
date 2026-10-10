//! The game's one audio output (DESIGN 6): the device, opened once at the format every source
//! renders at, and the sources of the moment mixed on its sample clock, a short queue ahead of
//! the device. A device that fails leaves the game silent; it never ends the game.
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
pub const Sources = struct {
    music: ?*soundtrack.Soundtrack = null,
    level: ?Level = null,

    pub const Level = struct { sound: *effects.Player, bank: sounds.Bank };
};

pub const Output = struct {
    state: enum { closed, open, failed } = .closed,
    /// The master volume, in percent, applied to the mix (`gain`).
    volume: u8 = 100,
    /// Mixed and not yet queued (stereo, interleaved).
    pending: [2048]i16 = undefined,
    begin: usize = 0,
    end: usize = 0,
    /// What played at the last pump: a source gone takes what it had queued with it.
    played: struct { music: bool = false, level: bool = false } = .{},

    /// Keeps the queue `lead_frames` ahead with `sources` mixed. A music not heard yet replaces
    /// what was queued, as does a source that stopped.
    pub fn pump(self: *Output, p: *platform.Platform, sources: Sources) void {
        const fresh_music = if (sources.music) |music| !music.heard else false;
        if (fresh_music or
            (self.played.music and sources.music == null) or
            (self.played.level and sources.level == null)) self.cut(p);
        self.played = .{ .music = sources.music != null, .level = sources.level != null };
        if (sources.music == null and sources.level == null) return;
        if (sources.music) |music| music.heard = true;
        if (self.state == .closed) self.open(p);
        if (self.state != .open) return;
        for (0..8) |_| {
            const status = p.audioStatus();
            if (!status.running or status.suspended or status.queued_frames >= lead_frames) return;
            if (self.begin == self.end) {
                const frames: usize = @intCast(@min(self.pending.len / 2, lead_frames - status.queued_frames));
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
        if (err != error.Unsupported) std.log.err("no sound: the audio device failed ({s})", .{@errorName(err)});
        if (self.state == .open) p.audioClose();
        self.state = .failed;
    }

    /// Drops what is mixed and queued.
    fn cut(self: *Output, p: *platform.Platform) void {
        if (self.state == .open) p.audioClear();
        self.begin = 0;
        self.end = 0;
    }
};

/// The sources' next `out.len / 2` frames, added, at `volume` percent.
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

/// The VOLUME option's steps sound even: each percent below 100 takes 0.4 dB off, so that a step
/// of 10% is 4 dB (20% is -32 dB) and 0% is silent. As 1/65,536ths.
pub fn gain(volume: u8) u32 {
    if (volume == 0) return 0;
    if (volume >= 100) return 1 << 16;
    const decibels = (@as(f64, @floatFromInt(volume)) - 100) * 0.4;
    return @intFromFloat(@round(std.math.pow(f64, 10, decibels / 20) * (1 << 16)));
}

fn scale(samples: []i16, volume: u8) void {
    if (volume >= 100) return;
    const factor: i64 = gain(volume);
    for (samples) |*sample| sample.* = @intCast((@as(i64, sample.*) * factor) >> 16);
}

fn add(sum: []i16, part: []const i16) void {
    for (sum, part) |*total, sample| total.* = @intCast(std.math.clamp(
        @as(i32, total.*) + sample,
        std.math.minInt(i16),
        std.math.maxInt(i16),
    ));
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
        const ratio = @as(f64, @floatFromInt(gain(step))) / @as(f64, @floatFromInt(gain(step - 10)));
        if (step > 10) try std.testing.expectApproxEqAbs(4.0, 20 * std.math.log10(ratio), 0.01);
    }
}

test "sources add, short of clipping" {
    var sum = [_]i16{ 30000, -30000, 5 };
    add(&sum, &.{ 10000, -10000, -7 });
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32768, -2 }, &sum);
}
