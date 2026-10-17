//! Plays a score on an OPL chip, on the output's sample clock. The score does not change; the
//! player owns the chip, the voices and a cursor for each part. Playback has these steps:
//! 1. `render` makes the chip's frames up to the start of the next tick.
//! 2. `advanceTick` plays the events that are due, part after part.
//! 3. A note takes a free melodic channel (0 to 5) or the channel of its drum (6 to 10).
//! Tick n starts at frame n * tick_pit_cycles * rate / 1,193,182 (the PIT clock). The drums use
//! the chip's rhythm mode. A note that finds no free channel does not play.
const std = @import("std");
const score_mod = @import("../content/score.zig");
const opl = @import("opl.zig");

/// A register write and the tick that it belongs to.
pub const RegisterWrite = struct {
    tick: u64,
    register: u8,
    value: u8,
};
/// Gets each register write before the chip. flashback-re's music_probe uses it to report the
/// timed writes.
pub const Observer = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, RegisterWrite) void,
};
/// A note that sounds. Its part and pitch find it at the release. `channel` is 0 to 5 for a
/// melodic note and 6 to 10 for a drum (the value of `score.Percussion`).
const Voice = struct {
    part: u4,
    pitch: u8,
    channel: u8,
    percussion: bool,
};
/// The position of a part: its next event, and the local tick where its current repeat started.
const Cursor = struct {
    event: usize = 0,
    origin: u64 = 0,
};
/// The OPL F-numbers of the notes C to B. The block (octave) of a note is its pitch / 12. The
/// values are equal-tempered, measured at the original's chip writes.
const frequencies = [_]u16{ 343, 364, 385, 408, 433, 459, 486, 515, 546, 579, 614, 650 };
/// The operator offsets of each channel: the modulator, then the carrier. Channels 6 to 10 are
/// the drums of `score.Percussion`. The bass drum has two operators, the other drums one.
const operators = [_][2]u8{
    .{ 0, 3 },
    .{ 1, 4 },
    .{ 2, 5 },
    .{ 8, 11 },
    .{ 9, 12 },
    .{ 10, 13 },
    .{ 16, 19 },
    .{ 20, 20 },
    .{ 18, 18 },
    .{ 21, 21 },
    .{ 17, 17 },
};
/// The operator offsets of the 9 channels of an OPL2.
const all_operators = [_]u8{ 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21 };

pub const Player = struct {
    score: score_mod.Score,
    chip: opl.Chip,
    rate: u32,
    /// The frames rendered.
    samples: u64 = 0,
    /// The ticks done since the start.
    tick: u64 = 0,
    /// The tick of the last restart (`restart_after_ticks`). The local tick counts from it.
    score_origin: u64 = 0,
    cursors: [16]Cursor = @splat(.{}),
    /// The notes that sound: slots 0 to 5 hold melodic notes, 6 to 10 drums.
    voices: [11]?Voice = @splat(null),
    /// The value of register 0xBD. Bit 5 (0x20) sets the rhythm mode. Bits 4 to 0 key on the
    /// bass drum, snare, tom-tom, cymbal and hi-hat (channels 6 to 10).
    percussion_flags: u8 = 0x20,
    /// The music volume, 0 to 63, 48 at the start as in the original. The keypad + and - keys
    /// set it (`Game.music_volume`). `level` reads it only when a note starts. The VOLUME
    /// setting is a separate gain, in percent, on the whole mix (`output.Output.volume`).
    master_volume: u8 = 48,
    observer: ?Observer = null,

    /// Returns a player at tick 0, with the chip silent.
    pub fn init(score: score_mod.Score, rate: u32, observer: ?Observer) Player {
        var self: Player = .{
            .score = score,
            .chip = opl.init(rate),
            .rate = rate,
            .observer = observer,
        };
        self.silence();
        return self;
    }
    /// Sends a register write to the observer, then to the chip.
    fn write(self: *Player, register: u8, value: u8) void {
        if (self.observer) |observer| {
            observer.write(observer.context, .{
                .tick = self.tick,
                .register = register,
                .value = value,
            });
        }
        opl.write(&self.chip, register, value);
    }
    /// Keys off the notes and the drums, then clears the chip's registers. Forgets every voice.
    pub fn silence(self: *Player) void {
        for (0..6) |i| {
            self.write(0xb0 + @as(u8, @intCast(i)), 1);
        }
        for (6..11) |i| {
            self.releaseDrum(@intCast(i));
        }
        self.write(8, 0x40);
        for (all_operators) |op| {
            self.write(0x40 + op, 0x3f);
        }
        for (0..9) |i| {
            self.write(0xb0 + @as(u8, @intCast(i)), 0);
        }
        for (0..9) |i| {
            self.write(0xc0 + @as(u8, @intCast(i)), 0);
        }
        for ([_]u8{ 0x60, 0x80, 0x20, 0xe0 }) |base| {
            for (all_operators) |op| {
                self.write(base + op, 0);
            }
        }
        // Register 1: waveform selection on, then off, as the original does at its reset.
        self.write(1, 0x20);
        self.write(1, 0);
        for (0..9) |i| {
            self.write(0xb0 + @as(u8, @intCast(i)), 0);
            self.write(0xa0 + @as(u8, @intCast(i)), 0);
        }
        self.write(0xbd, 0);
        self.voices = @splat(null);
    }
    /// Keys off the drum of `channel` (6 to 10): it clears bit 10 - channel of register 0xBD.
    fn releaseDrum(self: *Player, channel: u8) void {
        self.percussion_flags &= ~(@as(u8, 1) << @as(u3, @intCast(10 - channel)));
        self.write(0xbd, self.percussion_flags);
    }
    /// Returns the key scale and the attenuation of `op` for a note of `velocity`. The
    /// attenuation is 0 to 63, in OPL steps of 0.75 dB. With `scale`, the level (63 minus the
    /// attenuation) is multiplied by volume / 127 and rounded to the nearest step. The volume is
    /// velocity * master_volume / 64, rounded down. Without `scale`, the attenuation does not
    /// change: a modulator in FM mode does not sound.
    fn level(self: *const Player, op: score_mod.Operator, velocity: u7, scale: bool) u8 {
        const volume: i32 = (@as(i32, velocity) * self.master_volume) >> 6;
        const attenuation = if (scale)
            63 - @divTrunc(2 * (63 - @as(i32, op.attenuation)) * volume + 127, 254)
        else
            op.attenuation;
        return op.key_scale | @as(u8, @intCast(attenuation));
    }
    /// Writes the operators of `instrument` for `channel`. A drum other than the bass drum has
    /// one operator: it gets only the carrier.
    fn configure(self: *Player, instrument: score_mod.Instrument, channel: u8, velocity: u7) void {
        const pair = operators[channel];
        if (instrument.percussion == null or instrument.percussion == .bass_drum) {
            const op = instrument.modulator;
            self.write(0x20 + pair[0], op.characteristics);
            self.write(0x40 + pair[0], self.level(op, velocity, instrument.scale_modulator));
            self.write(0x60 + pair[0], op.attack_decay);
            self.write(0x80 + pair[0], op.sustain_release);
            self.write(0xc0 + channel, instrument.feedback_connection);
            // The original writes the waveform to 0x0E + operator, not 0xE0 + operator. Thus
            // every operator keeps the sine wave that `silence` sets. For operators 18 to 21
            // the address is 0x20 to 0x23: the write sets the multiplier of operators 0 to 3
            // (channels 0 to 2) and clears their other bits, until their next note.
            self.write(0x0e + pair[0], op.waveform);
        }
        const op = instrument.carrier;
        self.write(0x20 + pair[1], op.characteristics);
        self.write(0x40 + pair[1], self.level(op, velocity, true));
        self.write(0x60 + pair[1], op.attack_decay);
        self.write(0x80 + pair[1], op.sustain_release);
        self.write(0x0e + pair[1], op.waveform);
    }
    fn channelBusy(self: *const Player, channel: u8) bool {
        for (self.voices) |entry| {
            if (entry) |voice| {
                if (voice.channel == channel) return true;
            }
        }
        return false;
    }
    /// Starts `note` of `part`. A melodic note takes the lowest free channel from 0 to 5, and a
    /// drum takes its own channel. A drum keys on in register 0xBD, a melodic note in 0xB0.
    fn play(self: *Player, part: u4, note: score_mod.Note) void {
        const instrument = self.score.instruments[note.instrument] orelse return;
        const channel: u8 = if (instrument.percussion) |drum| @backingInt(drum) else find: {
            for (0..6) |i| {
                if (!self.channelBusy(@intCast(i))) break :find @intCast(i);
            }
            return; // The original drops excess notes; it does not steal sounding voices.
        };
        if (self.channelBusy(channel)) return;
        const first: usize = if (instrument.percussion != null) 6 else 0;
        const slot = for (self.voices[first..], first..) |entry, i| {
            if (entry == null) break i;
        } else return;
        self.voices[slot] = .{
            .part = part,
            .pitch = note.pitch,
            .channel = channel,
            .percussion = instrument.percussion != null,
        };
        self.configure(instrument, channel, note.velocity);
        const frequency = frequencies[note.pitch % 12];
        // Register 0xB0: the block in bits 2 to 4, above bits 8 and 9 of the F-number.
        const high: u8 = @truncate((@as(u16, note.pitch / 12) << 2) | (frequency >> 8));
        if (instrument.percussion != null) {
            self.releaseDrum(channel);
            // The snare and the hi-hat share chip channel 7, the tom-tom and the cymbal 8.
            const physical = if (channel == 9) 8 else if (channel == 10) 7 else channel;
            self.write(0xa0 + physical, @truncate(frequency));
            self.write(0xb0 + physical, high);
            self.percussion_flags |= @as(u8, 1) << @as(u3, @intCast(10 - channel));
            self.write(0xbd, self.percussion_flags);
        } else {
            self.write(0xb0 + channel, 0);
            self.write(0xa0 + channel, @truncate(frequency));
            self.write(0xb0 + channel, high | 0x20);
        }
    }
    /// Keys off the first voice of `part` that plays `pitch`.
    fn release(self: *Player, part: u4, pitch: u8) void {
        for (&self.voices) |*entry| {
            if (entry.*) |voice| {
                if (voice.part != part or voice.pitch != pitch) continue;
                if (voice.percussion) {
                    self.releaseDrum(voice.channel);
                } else {
                    self.write(
                        0xb0 + voice.channel,
                        @truncate((@as(u16, pitch / 12) << 2) | (frequencies[pitch % 12] >> 8)),
                    );
                }
                entry.* = null;
                return;
            }
        }
    }
    /// Bends the voices of `part`. `amount` is the 14-bit MIDI value, read as a sign and a size:
    /// bit 13 set makes it negative, and bits 0 to 12 are the size. 8192 does nothing.
    fn bend(self: *Player, part: u4, amount: u14) void {
        // This keeps the original's asymmetric bend and octave rounding. The size is below 8192,
        // so the semitone shift is always 0. The detune is the signed amount * 25, wrapped to 16
        // bits, / 8192: -4 to +3 F-number steps. The written block is one less than the note's.
        if (amount == 8192) return;
        const signed: i32 = if (amount & 8192 != 0) -@as(i32, amount & 8191) else amount;
        for (self.voices) |entry| {
            if (entry) |voice| {
                if (voice.part != part) continue;
                var semitone: i32 = @as(i32, voice.pitch % 12) + @divTrunc(signed, 8192);
                var octave: i32 = voice.pitch / 12;
                if (semitone < 0) {
                    octave -= 1;
                    semitone = -semitone;
                } else if (semitone > 12) {
                    octave += 1;
                    semitone -= 12;
                }
                octave -= 1;
                const product: i16 = @truncate(@rem(signed, 8192) * 25);
                const detune = @divTrunc(@as(i32, product), 8192);
                const frequency: u16 = @intCast(
                    @as(i32, frequencies[@intCast(@rem(semitone, 12))]) + detune,
                );
                self.write(0xa0 + voice.channel, @truncate(frequency));
                self.write(
                    0xb0 + voice.channel,
                    @truncate(@as(u32, @bitCast(octave * 4)) | 0x20 | (frequency >> 8)),
                );
            }
        }
    }
    /// Advances the score by one tick and plays the events due. The local tick counts from the
    /// last restart:
    /// 1. When it reaches `restart_after_ticks`, the chip goes silent and every part restarts.
    /// 2. When it passes `stop_after_ticks`, no more events play. The notes keep sounding.
    /// 3. When it passes a part's origin plus `repeat_ticks`, the part starts again.
    pub fn advanceTick(self: *Player) void {
        self.tick += 1;
        var local_tick = self.tick - self.score_origin;
        if (self.score.restart_after_ticks) |period| {
            if (local_tick >= period) {
                self.silence();
                self.cursors = @splat(.{});
                self.score_origin = self.tick;
                local_tick = 0;
            }
        }
        if (self.score.stop_after_ticks) |limit| {
            if (local_tick > limit) return;
        }
        for (self.score.parts, 0..) |part, i| {
            if (part.events.len == 0) continue;
            const cursor = &self.cursors[i];
            if (part.repeat_ticks) |period| {
                if (local_tick > cursor.origin + period) {
                    cursor.origin += period;
                    cursor.event = 0;
                }
            }
            while (cursor.event < part.events.len and
                part.events[cursor.event].tick + cursor.origin <=
                    local_tick) : (cursor.event += 1) {
                switch (part.events[cursor.event].action) {
                    .play => |note| self.play(@intCast(i), note),
                    .release => |pitch| self.release(@intCast(i), pitch),
                    .bend => |amount| self.bend(@intCast(i), amount),
                }
            }
        }
    }
    /// Renders the next `stereo.len / 2` frames. The chip renders up to the first frame of the
    /// next tick, then that tick's events apply. Thus the output does not depend on the size of
    /// the buffers.
    pub fn render(self: *Player, stereo: []i16) void {
        std.debug.assert(stereo.len % 2 == 0);
        var frames: usize = 0;
        while (frames < stereo.len / 2) {
            const next = self.score.sampleAt(self.tick + 1, self.rate);
            if (next <= self.samples) {
                self.advanceTick();
                continue;
            }
            const count: usize = @intCast(@min(stereo.len / 2 - frames, next - self.samples));
            opl.render(&self.chip, stereo[frames * 2..][0..count * 2]);
            self.samples += count;
            frames += count;
        }
    }
};

test "music rendering is independent of host buffer sizes" {
    const op: score_mod.Operator = .{
        .characteristics = 1,
        .key_scale = 0,
        .attenuation = 0,
        .attack_decay = 0xf2,
        .sustain_release = 0x24,
        .waveform = 0,
    };
    var instruments: [16]?score_mod.Instrument = @splat(null);
    instruments[0] = .{
        .percussion = null,
        .modulator = op,
        .carrier = op,
        .feedback_connection = 1,
        .scale_modulator = true,
    };
    const events = [_]score_mod.Event{
        .{ .tick = 1, .action = .{ .play = .{ .instrument = 0, .pitch = 48, .velocity = 100 } } },
        .{ .tick = 20, .action = .{ .release = 48 } },
    };
    const parts = [_]score_mod.Part{.{ .events = &events, .repeat_ticks = 32 }};
    const score: score_mod.Score = .{
        .instruments = instruments,
        .parts = &parts,
        .tick_pit_cycles = 3724,
        .stop_after_ticks = null,
        .restart_after_ticks = null,
    };
    var whole = Player.init(score, 44100, null);
    var split = Player.init(score, 44100, null);
    var a: [10000]i16 = undefined;
    var b: [10000]i16 = undefined;
    whole.render(&a);
    for (0..100) |i| {
        split.render(b[i * 100..][0..100]);
    }
    try std.testing.expectEqualSlices(i16, &a, &b);
    try std.testing.expect(!std.mem.allEqual(i16, &a, 0));
}
