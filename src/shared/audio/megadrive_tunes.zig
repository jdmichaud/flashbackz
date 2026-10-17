//! The Mega Drive edition's tunes during play (PLAN MD-C): its three-channel tracker and its play
//! driver's Z80 program, as the YM2612 writes they make each frame (flashback-re
//! docs/megadrive-music.md 3). For each note the tracker hands the channel's instrument, with the
//! note's frequency in it, to the driver, which writes it whole between a key off and a key on and
//! then counts the note's length down to its release.
const std = @import("std");
const megadrive = @import("../content/megadrive.zig");
const chips = @import("megadrive/root.zig");

const channels = megadrive.channels;

/// Added to each row's length during play on an NTSC console (the cartridge's $FFF62B).
const tempo = 1;

/// The registers an instrument's bytes 0-32 go to, in the driver's order; the channel is added
/// to each but the LFO's (0x22). Bytes 31 and 32 are the note's frequency.
const registers = [33]u8{
    0xB0, 0x30, 0x34, 0x38, 0x3C, 0x50, 0x54, 0x58, 0x5C, 0x60, 0x64, 0x68, 0x6C, 0x70, 0x74, 0x78,
    0x7C, 0x80, 0x84, 0x88, 0x8C, 0x40, 0x44, 0x48, 0x4C, 0x90, 0x94, 0x98, 0x9C, 0xB4, 0x22, 0xA4,
    0xA0,
};

/// A write to one of the YM2612's first three channels' registers (its port 0 and 1).
pub const Write = struct {
    register: u8,
    value: u8,
};

/// A frame's writes, in order: at most a note on each channel.
pub const FrameWrites = struct {
    items: [channels * (registers.len + 2)]Write = undefined,
    len: usize = 0,

    pub fn slice(self: *const FrameWrites) []const Write {
        return self.items[0..self.len];
    }

    fn add(self: *FrameWrites, register: u8, value: u8) void {
        self.items[self.len] = .{ .register = register, .value = value };
        self.len += 1;
    }
};

pub const Player = struct {
    tunes: *const megadrive.Tunes,
    tune: ?*const megadrive.Tune = null,
    row: usize = 0,
    /// Frames left before the next row.
    wait: u16 = 0,
    /// Each channel's instrument (1-based, 0 for none yet), kept from one tune to the next as the
    /// cartridge keeps it.
    instrument: [channels]u8 = @splat(0),
    /// The driver's counters of the notes' lengths.
    countdown: [channels]u8 = @splat(0),

    /// Starts tune `index` (0 for the cartridge's effect 68) from its first row, played at the next
    /// frame. A tune playing stops; its notes keep their releases.
    pub fn start(self: *Player, index: usize) void {
        self.tune = &self.tunes.tunes[index];
        self.row = 0;
        self.wait = 0;
    }

    pub fn playing(self: *const Player) bool {
        return self.tune != null;
    }

    /// One frame of the cartridge (a VBlank): the writes of the row due, and of the releases.
    pub fn frame(self: *Player) FrameWrites {
        var notes: [channels]?struct { instrument: *const megadrive.Instrument, pitch: u16 } =
            @splat(null);
        if (self.tune) |tune| {
            if (self.wait != 0) {
                self.wait -= 1;
            } else {
                const cells = tune.rows[self.row];
                for (0..channels) |channel| {
                    if (cells[2 * channel] != 0) {
                        self.instrument[channel] = cells[2 * channel];
                    }
                    const note = cells[2 * channel + 1];
                    const index = @as(usize, self.instrument[channel]) -% 1;
                    if (note == 0 or index >= tune.instruments.len) continue;
                    const detune: u16 = @bitCast(tune.detune[index]);
                    notes[channel] = .{
                        .instrument = &tune.instruments[index],
                        .pitch = self.tunes.pitches[note - 1] +% detune,
                    };
                }
                self.row += 1;
                self.wait = tune.frames_per_row + tempo;
                // The tune ends with its last row, not after it.
                if (self.row == tune.rows.len) {
                    self.tune = null;
                }
            }
        }
        var writes: FrameWrites = .{};
        for (0..channels) |c| {
            const channel: u8 = @intCast(c);
            if (notes[c]) |note| {
                var slot = note.instrument.*;
                std.mem.writeInt(u16, slot[31..33], note.pitch, .big);
                writes.add(0x28, channel);
                for (registers, slot[0..registers.len]) |register, value| {
                    writes.add(if (register == 0x22) register else register + channel, value);
                }
                self.countdown[c] = slot[33];
                writes.add(0x28, channel | slot[34]);
            } else if (self.countdown[c] != 0) {
                self.countdown[c] -= 1;
                if (self.countdown[c] == 0) {
                    writes.add(0x28, channel);
                    // The driver stores its register A back, which holds the channel number: the
                    // second and third channels' key off repeats every frame and every second
                    // frame until their next note (flashback-re docs/megadrive-music.md 3).
                    self.countdown[c] = channel;
                }
            }
        }
        return writes;
    }
};

/// The tunes as sound: the player's writes given to the Mega Drive's chips on its master clock,
/// one VBlank at a time (NTSC), and the chips' output added to the effects' (PLAN MD-D).
pub const Output = struct {
    player: Player,
    synth: chips.synth.Default,
    /// The chips' time at the start of the next VBlank.
    vblank: u64 = 0,
    /// A VBlank's frames, rendered and not yet mixed (stereo, interleaved).
    frames: [2 * max_frames]i16 = undefined,
    begin: usize = 0,
    end: usize = 0,
    coupling: [2]Coupling,

    /// The cartridge's play driver writes a frame's registers from about 148,000 master cycles
    /// after the VBlank, 2,925 cycles apart (measured on capture_md_tune.py's recordings; the
    /// first write varies between 78,000 and 173,000). A register is its address and its data.
    const first_write: u64 = 148_000;
    const write_spacing: u64 = 2_925;
    /// The most frames a VBlank gives at the chips' highest output rate.
    const max_frames = 900;

    pub fn init(tunes: *const megadrive.Tunes, rate: u32) Output {
        const synth = chips.synth.init(.{ .rate = rate });
        std.debug.assert(synth.maxFrames(chips.synth.cycles_per_vblank) <= max_frames);
        var output: Output = .{
            .player = .{ .tunes = tunes },
            .synth = synth,
            .coupling = @splat(.init(rate)),
        };
        // The console's filter starts from zero: a silent VBlank brings the chips to their
        // resting level, which the coupling then starts from.
        output.renderVBlank();
        output.begin = output.end;
        return output;
    }

    /// Adds the tunes' next `out.len / 2` frames to `out`, about as loud as the loudest effects,
    /// as on the Mega Drive: there a full-scale effect through the DAC peaks at 5,400
    /// (`megadrive/model1.zig`) and the tunes at 5,100 to 8,300; here the effects reach 32,767,
    /// so the tunes are raised 3.5 times, the loudest (72) to 29,000, short of clipping alone.
    pub fn mixInto(self: *Output, out: []i16) void {
        var i: usize = 0;
        while (i < out.len) {
            if (self.begin == self.end) {
                self.renderVBlank();
            }
            const n = @min(out.len - i, self.end - self.begin);
            for (out[i..][0..n], self.frames[self.begin..][0..n], self.begin..) |*sample, tune, k| {
                const heard = self.coupling[k % 2].pass(tune);
                const sum = @as(i32, sample.*) + @divTrunc(heard * 7, 2);
                const low = std.math.minInt(i16);
                sample.* = @intCast(std.math.clamp(sum, low, std.math.maxInt(i16)));
            }
            i += n;
            self.begin += n;
        }
    }

    fn renderVBlank(self: *Output) void {
        const writes = self.player.frame();
        var count: usize = 0;
        for (writes.slice(), 0..) |write, k| {
            const at = self.vblank + first_write + k * write_spacing;
            count += self.synth.advanceTo(at, self.frames[2 * count..]);
            self.synth.writeFm(0, write.register);
            self.synth.writeFm(1, write.value);
        }
        self.vblank += chips.synth.cycles_per_vblank;
        count += self.synth.advanceTo(self.vblank, self.frames[2 * count..]);
        self.begin = 0;
        self.end = 2 * count;
    }
};

/// The console's output is AC-coupled: the chips' constant level, such as the YM2612's offset
/// while silent, is not heard. A one-pole high-pass at 5 Hz, in 16-bit fixed point, which starts
/// from the first level it is given so that the start makes no step.
const Coupling = struct {
    keep: i64,
    previous: ?i32 = null,
    level: i64 = 0,

    fn init(rate: u32) Coupling {
        const corner = 2.0 * std.math.pi * 5.0 * 65536.0 / @as(f64, @floatFromInt(rate));
        return .{ .keep = 65536 - @as(i64, @intFromFloat(@round(corner))) };
    }

    fn pass(self: *Coupling, input: i16) i32 {
        const previous = self.previous orelse input;
        self.previous = input;
        const step = @as(i64, input) - previous;
        self.level = step * 65536 + @divTrunc(self.keep * self.level, 65536);
        return @intCast(@divTrunc(self.level, 65536));
    }
};

// ----- tests: synthetic tunes, no cartridge

/// Eight copies of one synthetic tune, for tests: `rows` of an instrument whose bytes are their
/// indices, its release after `length` frames.
pub fn testTunes(rows: []const megadrive.Row, frames_per_row: u16, length: u8) megadrive.Tunes {
    var instrument: megadrive.Instrument = undefined;
    for (&instrument, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }
    instrument[33] = length;
    instrument[34] = 0xF0;
    const tune: megadrive.Tune = .{
        .rows = rows,
        .frames_per_row = frames_per_row,
        .instruments = @splat(instrument),
        .detune = .{ -2 } ++ @as([14]i16, @splat(0)),
    };
    var pitches: [255]u16 = @splat(0);
    pitches[0] = 0x1234;
    pitches[1] = 0x2345;
    return .{ .allocator = std.testing.allocator, .tunes = @splat(tune), .pitches = pitches };
}

test "a note: key off, the instrument's registers, its frequency, key on" {
    const tunes = testTunes(&.{.{ 1, 1, 0, 0, 0, 0 }}, 5, 0);
    var player: Player = .{ .tunes = &tunes };
    player.start(0);
    const writes = player.frame().slice();
    try std.testing.expectEqual(@as(usize, 35), writes.len);
    try std.testing.expectEqual(Write{ .register = 0x28, .value = 0 }, writes[0]);
    try std.testing.expectEqual(Write{ .register = 0xB0, .value = 0 }, writes[1]);
    try std.testing.expectEqual(Write{ .register = 0x9C, .value = 28 }, writes[29]);
    try std.testing.expectEqual(Write{ .register = 0x22, .value = 30 }, writes[31]);
    // The note table's word plus the instrument's detune: 0x1234 - 2.
    try std.testing.expectEqual(Write{ .register = 0xA4, .value = 0x12 }, writes[32]);
    try std.testing.expectEqual(Write{ .register = 0xA0, .value = 0x32 }, writes[33]);
    try std.testing.expectEqual(Write{ .register = 0x28, .value = 0xF0 }, writes[34]);
    // The last row played, the tune is over.
    try std.testing.expect(!player.playing());
}

test "rows last their frames plus the tempo plus one; the channel number is added" {
    const tunes = testTunes(&.{.{ 1, 1, 0, 0, 0, 0 }, .{ 0, 0, 1, 2, 0, 0 }}, 3, 0);
    var player: Player = .{ .tunes = &tunes };
    player.start(0);
    try std.testing.expectEqual(@as(usize, 35), player.frame().len);
    for (0..4) |_| {
        try std.testing.expectEqual(@as(usize, 0), player.frame().len);
    }
    const writes = player.frame().slice();
    try std.testing.expectEqual(Write{ .register = 0xB1, .value = 0 }, writes[1]);
    try std.testing.expectEqual(Write{ .register = 0x22, .value = 30 }, writes[31]);
    try std.testing.expectEqual(Write{ .register = 0xA5, .value = 0x23 }, writes[32]);
    try std.testing.expectEqual(Write{ .register = 0x28, .value = 0xF1 }, writes[34]);
}

test "a note's length releases it; channels 2 and 3 repeat their key off" {
    const tunes = testTunes(&.{.{ 1, 1, 1, 1, 1, 1 }}, 5, 2);
    var player: Player = .{ .tunes = &tunes };
    player.start(0);
    try std.testing.expectEqual(@as(usize, 3 * 35), player.frame().len);
    var offs: [3][8]bool = @splat(@splat(false));
    for (0..8) |f| {
        for (player.frame().slice()) |write| {
            try std.testing.expectEqual(@as(u8, 0x28), write.register);
            offs[write.value][f] = true;
        }
    }
    // Frames after the notes: channel 1 once, at its length; 2 every frame; 3 every second one.
    const o = true;
    const x = false;
    try std.testing.expectEqualSlices(bool, &.{ x, o, x, x, x, x, x, x }, &offs[0]);
    try std.testing.expectEqualSlices(bool, &.{ x, o, o, o, o, o, o, o }, &offs[1]);
    try std.testing.expectEqualSlices(bool, &.{ x, o, x, o, x, o, x, o }, &offs[2]);
}

test "the output adds a VBlank's tune to the effects, silent before a tune" {
    var tunes = testTunes(&.{.{ 1, 1, 0, 0, 0, 0 }}, 5, 0);
    // Heard at once: the fastest attack and no attenuation on every operator.
    @memset(tunes.tunes[0].instruments[0][5..9], 31);
    @memset(tunes.tunes[0].instruments[0][21..25], 0);
    tunes.tunes[0].instruments[0][29] = 0xC0; // both sides
    var output = Output.init(&tunes, 48000);
    var effects: [2 * 400]i16 = @splat(100);
    output.mixInto(&effects);
    for (effects) |sample| {
        try std.testing.expectEqual(@as(i16, 100), sample);
    }
    output.player.start(0);
    var heard: [2 * 2000]i16 = @splat(0);
    output.mixInto(&heard);
    var loudest: u16 = 0;
    for (heard) |sample| {
        loudest = @max(loudest, @abs(sample));
    }
    try std.testing.expect(loudest > 0);
}

test "the coupling passes a tone and removes a constant level" {
    var coupling = Coupling.init(48000);
    for (0..48000) |_| {
        try std.testing.expectEqual(@as(i32, 0), coupling.pass(143));
    }
    var loudest: i32 = 0;
    for (0..4800) |n| {
        const tone: i16 = if (n / 24 % 2 == 0) 1000 else -1000;
        loudest = @max(loudest, coupling.pass(tone + 143));
    }
    try std.testing.expect(loudest > 900);
}
