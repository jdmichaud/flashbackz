//! Generic OPL2/OPL3 synthesizer reused from vpoolz commit
//! 9459fb3a8695eb8b8af451711b2351c849924a87. Register writes become PCM here;
//! Flashback sequencing and voice ownership are separate systems.
//!
//! The upstream Zig translation preserves DOSBox 0.73 ADLIBEMU arithmetic. Its synthetic
//! register-script reference is included and required by the tests. No game content is used.
//!
//! Copyright (C) 2002-2009 The DOSBox Team. OPL2/OPL3 emulation library.
//!
//! This library is free software; you can redistribute it and/or modify it under the terms of the
//! GNU Lesser General Public License as published by the Free Software Foundation; either version
//! 2.1 of the License, or (at your option) any later version.
//!
//! This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//! without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
//! the GNU Lesser General Public License for more details.
//!
//! You should have received a copy of the GNU Lesser General Public License along with this
//! library; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//! Boston, MA 02110-1301 USA.
const std = @import("std");

pub const num_channels = 18;
pub const max_operators = num_channels * 2;

const fixedpt: f64 = 0x10000;
const fixedpt_int: u32 = 0x10000;
const fixedpt_lfo: f64 = 0x1000000;
const waveprec: usize = 1024;
/// The chip's own clock: 14,318,180 / 288 Hz.
const intfrequ: f64 = 14318180.0 / 288.0;

const OpState = enum(u32) {
    attack = 0,
    decay = 1,
    release = 2,
    sustain = 3,
    sustain_nokeep = 4,
    off = 5,
};

const arc_control = 0x00;
const arc_tvs_ksr_mul = 0x20;
const arc_ksl_outlev = 0x40;
const arc_attr_decr = 0x60;
const arc_susl_relr = 0x80;
const arc_freq_num = 0xa0;
const arc_kon_bnum = 0xb0;
const arc_perc_mode = 0xbd;
const arc_feedback = 0xc0;
const arc_wave_sel = 0xe0;
const arc_secondset = 0x100;

const op_act_off: u32 = 0x00;
const op_act_normal: u32 = 0x01;
const op_act_perc: u32 = 0x02;

const blockbuf_size = 512;
const vibtab_size = 8;
const tremtab_size = 53;
const trem_freq: f64 = 3.7;

/// One operator. The field names are those of the emulator.
const Operator = struct {
    cval: i32 = 0,
    lastcval: i32 = 0,
    tcount: u32 = 0,
    wfpos: u32 = 0,
    tinc: u32 = 0,
    amp: f64 = 0,
    step_amp: f64 = 0,
    vol: f64 = 0,
    sustain_level: f64 = 0,
    mfbi: i32 = 0,
    a0: f64 = 0,
    a1: f64 = 0,
    a2: f64 = 0,
    a3: f64 = 0,
    decaymul: f64 = 0,
    releasemul: f64 = 0,
    op_state: OpState = .off,
    toff: u32 = 0,
    freq_high: i32 = 0,
    /// The start of the selected waveform in `wavtable`. DOSBox 0.73's C code (as modified for
    /// vpoolz's oracle) keeps a pointer; an index avoids a self-reference.
    cur_wform: usize = 0,
    cur_wmask: u32 = 0,
    act_state: u32 = op_act_off,
    sus_keep: bool = false,
    vibrato: bool = false,
    tremolo: bool = false,
    generator_pos: u32 = 0,
    cur_env_step: u32 = 0,
    env_step_a: i32 = 0,
    env_step_d: i32 = 0,
    env_step_r: i32 = 0,
    step_skip_pos: u8 = 0,
    env_step_skip_a: i32 = 0,
    is_4op: bool = false,
    is_4op_attached: bool = false,
    left_pan: i32 = 0,
    right_pan: i32 = 0,
};

const kslmul = [4]f64{ 0.0, 0.5, 0.25, 1.0 };
const frqmul_tab = [16]f64{ 0.5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 12, 12, 15, 15 };
const modulatorbase = [9]u8{ 0, 1, 2, 8, 9, 10, 16, 17, 18 };

const regbase2modop = [44]u8{
    0,  1,  2,  0,  1,  2,  0,  0,  3,  4,  5,
    3,  4,  5,  0,  0,  6,  7,  8,  6,  7,  8,
    18, 19, 20, 18, 19, 20, 0,  0,  21, 22, 23,
    21, 22, 23, 0,  0,  24, 25, 26, 24, 25, 26,
};
const regbase2op = [44]u8{
    0,  1,  2,  9,  10, 11, 0,  0,  3,  4,  5,
    12, 13, 14, 0,  0,  6,  7,  8,  15, 16, 17,
    18, 19, 20, 27, 28, 29, 0,  0,  21, 22, 23,
    30, 31, 32, 0,  0,  24, 25, 26, 33, 34, 35,
};

const waveform = [8]u32{
    waveprec, waveprec >> 1, waveprec,            (waveprec * 3) >> 2,
    0,        0,             (waveprec * 5) >> 2, waveprec << 1,
};
const wavemask = [8]u32{
    waveprec - 1,        waveprec - 1, (waveprec >> 1) - 1,
    (waveprec >> 1) - 1, waveprec - 1, ((waveprec * 3) >> 2) - 1,
    waveprec >> 1,       waveprec - 1,
};
const wavestart = [8]u32{ 0, waveprec >> 1, 0, waveprec >> 2, 0, 0, 0, waveprec >> 3 };

const attackconst = [4]f64{ 1.0 / 2.82624, 1.0 / 2.25280, 1.0 / 1.88416, 1.0 / 1.59744 };
const decrelconst = [4]f64{ 1.0 / 39.28064, 1.0 / 31.41608, 1.0 / 26.17344, 1.0 / 22.44608 };

/// The C code converts a double to an `int32_t` with a plain cast. Zig's `@intFromFloat` does
/// not accept a value outside the range of the type, so this function truncates toward zero and
/// clamps at the limits. The two differ only on values that the chip never makes.
fn toI32(v: f64) i32 {
    const t = @trunc(v);
    if (!(t > -2147483649.0)) return std.math.minInt(i32);
    if (!(t < 2147483648.0)) return std.math.maxInt(i32);
    return @intFromFloat(t);
}

fn toU32(v: f64) u32 {
    const t = @trunc(v);
    if (!(t > -1.0)) return 0;
    if (!(t < 4294967296.0)) return std.math.maxInt(u32);
    return @intFromFloat(t);
}

/// The whole chip. One instance is one YMF262. Each music player (one for each `Soundtrack`)
/// owns its chip.
pub const Chip = struct {
    op: [max_operators]Operator = @splat(.{}),
    int_samplerate: i32 = 0,
    /// The register set, both banks.
    adlibreg: [512]u8 = @splat(0),
    wave_sel: [44]u8 = @splat(0),

    vibtab_pos: u32 = 0,
    vibtab_add: u32 = 0,
    tremtab_pos: u32 = 0,
    tremtab_add: u32 = 0,
    generator_add: u32 = 0,
    /// The state of the noise generator of the rhythm section. The C code uses this generator
    /// instead of `rand()`, so the noise is reproducible and the audio thread makes no libc call.
    noise_seed: u32 = 1,

    recipsamp: f64 = 0,
    wavtable: [waveprec * 3]i16 = @splat(0),

    vib_table: [vibtab_size]i32 = @splat(0),
    trem_table: [tremtab_size * 2]i32 = @splat(0),
    vibval_const: [blockbuf_size]i32 = @splat(0),
    tremval_const: [blockbuf_size]i32 = @splat(0),
    vibval_var1: [blockbuf_size]i32 = @splat(0),
    vibval_var2: [blockbuf_size]i32 = @splat(0),

    frqmul: [16]f32 = @splat(0),
    kslev: [8][16]u8 = @splat(@splat(0)),

    /// The two timers and the status register. The C code runs them on the chip's own clock
    /// (the frames rendered), not on a wall clock.
    timers: [2]Timer = @splat(.{}),
    chip_frames: u64 = 0,
    /// The status register: bit 6 is the flag of timer 1, bit 5 the flag of timer 2. Bit 7 is
    /// set when either flag is set.
    chip_status: u8 = 0,

    fn noiseBit(self: *Chip) u32 {
        self.noise_seed = self.noise_seed *% 1103515245 +% 12345;
        return (self.noise_seed >> 16) & 1;
    }

    // --- the operator steps ------------------------------------------------------------------

    fn operatorAdvance(self: *Chip, o: *Operator, vib: i32) void {
        o.wfpos = o.tcount;
        o.tcount +%= o.tinc;
        const scaled: i64 = @divTrunc(@as(i64, @as(i32, @bitCast(o.tinc))) * vib, 0x10000);
        o.tcount +%= @bitCast(@as(i32, @truncate(scaled)));
        o.generator_pos +%= self.generator_add;
    }

    fn operatorAdvanceDrums(
        self: *Chip,
        hihat: usize,
        vib1: i32,
        snare: usize,
        vib2: i32,
        cymbal: usize,
        vib3: i32,
    ) void {
        const c1 = self.op[hihat].tcount / fixedpt_int;
        const c3 = self.op[cymbal].tcount / fixedpt_int;
        const phasebit: u32 = if ((((c1 & 0x88) ^ ((c1 << 5) & 0x80)) |
            ((c3 ^ (c3 << 2)) & 0x20)) != 0) 0x02 else 0x00;
        const noisebit = self.noiseBit();
        const snare_phase_bit: u32 = ((self.op[hihat].tcount / fixedpt_int) / 0x100) & 1;

        // Hi-hat
        var inttm: u32 = (phasebit << 8) | (@as(u32, 0x34) << @intCast(phasebit ^ (noisebit << 1)));
        self.drumStep(hihat, inttm, vib1);
        // Snare
        inttm = ((1 + snare_phase_bit) ^ noisebit) << 8;
        self.drumStep(snare, inttm, vib2);
        // Cymbal
        inttm = (1 + phasebit) << 8;
        self.drumStep(cymbal, inttm, vib3);
    }

    fn drumStep(self: *Chip, index: usize, inttm: u32, vib: i32) void {
        const o = &self.op[index];
        o.wfpos = inttm *% fixedpt_int;
        o.tcount +%= o.tinc;
        const scaled: i64 = @divTrunc(@as(i64, @as(i32, @bitCast(o.tinc))) * vib, 0x10000);
        o.tcount +%= @bitCast(@as(i32, @truncate(scaled)));
        o.generator_pos +%= self.generator_add;
    }

    fn operatorOutput(self: *Chip, o: *Operator, modulator: i32, trem: i32) void {
        if (o.op_state == .off) return;
        o.lastcval = o.cval;
        const sum: u32 = o.wfpos +% @as(u32, @bitCast(modulator));
        const i: u32 = sum / fixedpt_int;
        const sample = self.wavtable[o.cur_wform + (i & o.cur_wmask)];
        o.cval = toI32(
            o.step_amp * o.vol * @as(f64, @floatFromInt(sample)) *
                @as(f64, @floatFromInt(trem)) / 16.0,
        );
    }

    fn operatorSustain(o: *Operator) void {
        const num_steps_add = o.generator_pos / fixedpt_int;
        o.cur_env_step +%= num_steps_add;
        o.generator_pos -%= num_steps_add *% fixedpt_int;
    }

    fn operatorRelease(o: *Operator) void {
        if (o.amp > 0.00000001) {
            o.amp *= o.releasemul;
        }
        const num_steps_add = o.generator_pos / fixedpt_int;
        var ct: u32 = 0;
        while (ct < num_steps_add) : (ct += 1) {
            o.cur_env_step +%= 1;
            if ((o.cur_env_step & @as(u32, @bitCast(o.env_step_r))) == 0) {
                if (o.amp <= 0.00000001) {
                    o.amp = 0.0;
                    if (o.op_state == .release) {
                        o.op_state = .off;
                    }
                }
                o.step_amp = o.amp;
            }
        }
        o.generator_pos -%= num_steps_add *% fixedpt_int;
    }

    fn operatorDecay(o: *Operator) void {
        if (o.amp > o.sustain_level) {
            o.amp *= o.decaymul;
        }
        const num_steps_add = o.generator_pos / fixedpt_int;
        var ct: u32 = 0;
        while (ct < num_steps_add) : (ct += 1) {
            o.cur_env_step +%= 1;
            if ((o.cur_env_step & @as(u32, @bitCast(o.env_step_d))) == 0) {
                if (o.amp <= o.sustain_level) {
                    if (o.sus_keep) {
                        o.op_state = .sustain;
                        o.amp = o.sustain_level;
                    } else {
                        o.op_state = .sustain_nokeep;
                    }
                }
                o.step_amp = o.amp;
            }
        }
        o.generator_pos -%= num_steps_add *% fixedpt_int;
    }

    fn operatorAttack(o: *Operator) void {
        o.amp = ((o.a3 * o.amp + o.a2) * o.amp + o.a1) * o.amp + o.a0;
        const num_steps_add = o.generator_pos / fixedpt_int;
        var ct: u32 = 0;
        while (ct < num_steps_add) : (ct += 1) {
            o.cur_env_step +%= 1;
            if ((o.cur_env_step & @as(u32, @bitCast(o.env_step_a))) == 0) {
                if (o.amp > 1.0) {
                    o.op_state = .decay;
                    o.amp = 1.0;
                    o.step_amp = 1.0;
                }
                o.step_skip_pos = o.step_skip_pos *% 2;
                if (o.step_skip_pos == 0) {
                    o.step_skip_pos = 1;
                }
                if ((@as(i32, o.step_skip_pos) & o.env_step_skip_a) != 0) {
                    o.step_amp = o.amp;
                }
            }
        }
        o.generator_pos -%= num_steps_add *% fixedpt_int;
    }

    /// The `opfuncs` table: the step that an operator takes in each state.
    fn operatorStep(o: *Operator) void {
        switch (o.op_state) {
            .attack => operatorAttack(o),
            .decay => operatorDecay(o),
            // Sustain-no-keep runs the release step, as in the table of the C version.
            .release, .sustain_nokeep => operatorRelease(o),
            .sustain => operatorSustain(o),
            .off => {},
        }
    }
};

/// One of the two timers of the chip.
///
/// DOSBox keeps the timers outside the emulator, in a wrapper that the host's wall clock drives.
/// The C code and this file put them on the chip's own clock, which is the audio output.
/// `chip_frames` counts the frames rendered. A timer with preset N expires `(256 - N)` times its
/// scale in microseconds after its start. It then reloads and continues, so the flag comes again
/// one period after each reset, as on the chip.
const Timer = struct {
    /// The preset, register 2 or 3.
    counter: u8 = 0,
    running: bool = false,
    masked: bool = false,
    overflow: bool = false,
    /// The frames << 16 of one period, and the chip time of the next overflow.
    period: u64 = 0,
    expiry: u64 = 0,
};

/// Timer 1 counts in 80-microsecond steps and timer 2 in 320.
const timer_scale_us = [2]u64{ 80, 320 };

// --- the register handlers ---------------------------------------------------------------------

/// `pow(2, x)`. The call is inlined, so the base is known at compile time and `pow` takes
/// `log(2)` as a constant in every build mode: a freestanding build without compiler-rt,
/// imports no `log`.
fn pow2(x: f64) f64 {
    return @call(.always_inline, std.math.pow, .{ f64, 2.0, x });
}

const step_skip_mask = [5]u8{ 0xff, 0xfe, 0xee, 0xba, 0xaa };

pub fn changeAttackRate(chip: *Chip, regbase: usize, o: *Operator) void {
    const attackrate: i32 = chip.adlibreg[arc_attr_decr + regbase] >> 4;
    if (attackrate != 0) {
        const f = pow2(
            @as(f64, @floatFromInt(attackrate)) + @as(f64, @floatFromInt(o.toff >> 2)) - 1,
        ) *
            attackconst[o.toff & 3] * chip.recipsamp;
        o.a0 = 0.0377 * f;
        o.a1 = 10.73 * f + 1;
        o.a2 = -17.57 * f;
        o.a3 = 7.42 * f;

        const step_skip: i32 = attackrate * 4 + @as(i32, @intCast(o.toff));
        const steps = step_skip >> 2;
        const shift: u5 = if (steps <= 12) @intCast(12 - steps) else 0;
        o.env_step_a = (@as(i32, 1) << shift) - 1;

        const step_num: usize = if (step_skip <= 48) @intCast(4 - (step_skip & 3)) else 0;
        o.env_step_skip_a = step_skip_mask[step_num];

        if (step_skip >= 60) {
            // This causes an immediate transition to amp = 1.0.
            o.a0 = 2.0;
            o.a1 = 0.0;
            o.a2 = 0.0;
            o.a3 = 0.0;
        }
    } else {
        o.a0 = 0.0;
        o.a1 = 1.0;
        o.a2 = 0.0;
        o.a3 = 0.0;
        o.env_step_a = 0;
        o.env_step_skip_a = 0;
    }
}

pub fn changeDecayRate(chip: *Chip, regbase: usize, o: *Operator) void {
    const decayrate: i32 = chip.adlibreg[arc_attr_decr + regbase] & 15;
    if (decayrate != 0) {
        const f = -7.4493 * decrelconst[o.toff & 3] * chip.recipsamp;
        o.decaymul = pow2(f * pow2(@floatFromInt(decayrate + @as(i32, @intCast(o.toff >> 2)))));
        const steps = (decayrate * 4 + @as(i32, @intCast(o.toff))) >> 2;
        const shift: u5 = if (steps <= 12) @intCast(12 - steps) else 0;
        o.env_step_d = (@as(i32, 1) << shift) - 1;
    } else {
        o.decaymul = 1.0;
        o.env_step_d = 0;
    }
}

pub fn changeReleaseRate(chip: *Chip, regbase: usize, o: *Operator) void {
    const releaserate: i32 = chip.adlibreg[arc_susl_relr + regbase] & 15;
    if (releaserate != 0) {
        const f = -7.4493 * decrelconst[o.toff & 3] * chip.recipsamp;
        o.releasemul = pow2(f * pow2(@floatFromInt(releaserate + @as(i32, @intCast(o.toff >> 2)))));
        const steps = (releaserate * 4 + @as(i32, @intCast(o.toff))) >> 2;
        const shift: u5 = if (steps <= 12) @intCast(12 - steps) else 0;
        o.env_step_r = (@as(i32, 1) << shift) - 1;
    } else {
        o.releasemul = 1.0;
        o.env_step_r = 0;
    }
}

pub fn changeSustainLevel(chip: *Chip, regbase: usize, o: *Operator) void {
    const sustainlevel: i32 = chip.adlibreg[arc_susl_relr + regbase] >> 4;
    o.sustain_level = if (sustainlevel < 15)
        pow2(@as(f64, @floatFromInt(sustainlevel)) * -0.5)
    else
        0.0;
}

pub fn changeWaveform(chip: *Chip, regbase_in: usize, o: *Operator) void {
    var regbase = regbase_in;
    if (regbase >= arc_secondset) {
        regbase -= (arc_secondset - 22);
    }
    o.cur_wmask = wavemask[chip.wave_sel[regbase]];
    o.cur_wform = waveform[chip.wave_sel[regbase]];
}

pub fn changeKeepSustain(chip: *Chip, regbase: usize, o: *Operator) void {
    o.sus_keep = (chip.adlibreg[arc_tvs_ksr_mul + regbase] & 0x20) > 0;
    if (o.op_state == .sustain) {
        if (!o.sus_keep) {
            o.op_state = .sustain_nokeep;
        }
    } else if (o.op_state == .sustain_nokeep) {
        if (o.sus_keep) {
            o.op_state = .sustain;
        }
    }
}

pub fn changeVibrato(chip: *Chip, regbase: usize, o: *Operator) void {
    o.vibrato = (chip.adlibreg[arc_tvs_ksr_mul + regbase] & 0x40) != 0;
    o.tremolo = (chip.adlibreg[arc_tvs_ksr_mul + regbase] & 0x80) != 0;
}

pub fn changeFeedback(chip: *Chip, chanbase: usize, o: *Operator) void {
    const feedback: i32 = chip.adlibreg[arc_feedback + chanbase] & 14;
    o.mfbi = if (feedback != 0) toI32(pow2(@floatFromInt((feedback >> 1) + 8))) else 0;
}

pub fn changeFrequency(chip: *Chip, chanbase: usize, regbase: usize, o: *Operator) void {
    const frn: u32 = ((@as(u32, chip.adlibreg[arc_kon_bnum + chanbase]) & 3) << 8) +
        @as(u32, chip.adlibreg[arc_freq_num + chanbase]);
    const oct: u32 = (@as(u32, chip.adlibreg[arc_kon_bnum + chanbase]) >> 2) & 7;
    o.freq_high = @intCast((frn >> 7) & 7);

    const note_sel: u32 = (chip.adlibreg[8] >> 6) & 1;
    o.toff = ((frn >> 9) & (note_sel ^ 1)) | ((frn >> 8) & note_sel);
    o.toff += (oct << 1);

    if ((chip.adlibreg[arc_tvs_ksr_mul + regbase] & 0x10) == 0) {
        o.toff >>= 2;
    }

    const shifted: f64 = @floatFromInt(frn << @intCast(oct));
    o.tinc = toU32(shifted * @as(f64, chip.frqmul[chip.adlibreg[arc_tvs_ksr_mul + regbase] & 15]));

    const vol_in = @as(f64, @floatFromInt(chip.adlibreg[arc_ksl_outlev + regbase] & 63)) +
        kslmul[chip.adlibreg[arc_ksl_outlev + regbase] >> 6] *
            @as(f64, @floatFromInt(chip.kslev[oct][frn >> 6]));
    o.vol = pow2(vol_in * -0.125 - 14);

    changeAttackRate(chip, regbase, o);
    changeDecayRate(chip, regbase, o);
    changeReleaseRate(chip, regbase, o);
}

pub fn enableOperator(chip: *Chip, regbase: usize, o: *Operator, act_type: u32) void {
    if (o.act_state == op_act_off) {
        var wselbase = regbase;
        if (wselbase >= arc_secondset) {
            wselbase -= (arc_secondset - 22);
        }
        o.tcount = wavestart[chip.wave_sel[wselbase]] *% fixedpt_int;
        o.op_state = .attack;
        o.act_state |= act_type;
    }
}

pub fn disableOperator(o: *Operator, act_type: u32) void {
    if (o.act_state != op_act_off) {
        o.act_state &= ~act_type;
        if (o.act_state == op_act_off) {
            if (o.op_state != .off) {
                o.op_state = .release;
            }
        }
    }
}

// --- the chip's own reset (adlib_init) ---------------------------------------------------------

/// The waveform table. The C code builds it once into a static. The values do not depend on
/// the sample rate, so the table is built once, at compile time; freestanding builds link no
/// compiler-rt, and at run time `sin` would be an import. A test checks it against the table
/// built at run time.
const wave_table: [waveprec * 3]i16 = buildWaveTable(wave_pi);

const wave_pi: f64 = 3.1415926535897932384626433832795;

fn buildWaveTable(pi: f64) [waveprec * 3]i16 {
    @setEvalBranchQuota(20_000);
    var table: [waveprec * 3]i16 = @splat(0);
    for (0..waveprec >> 1) |n| {
        const a = 16384.0 * @sin(@as(f64, @floatFromInt(n << 1)) * pi * 2 / @as(f64, waveprec));
        const b = 16384.0 *
            @sin(@as(f64, @floatFromInt((n << 1) + 1)) * pi * 2 / @as(f64, waveprec));
        table[(n << 1) + waveprec] = @intCast(toI32(a));
        table[(n << 1) + 1 + waveprec] = @intCast(toI32(b));
        table[n] = table[(n << 1) + waveprec];
    }
    for (0..waveprec >> 3) |n| {
        table[n + (waveprec << 1)] = table[n + (waveprec >> 3)] -% 16384;
        table[n + ((waveprec * 17) >> 3)] = table[n + (waveprec >> 2)] +% 16384;
    }
    return table;
}

/// A new chip at a sample rate, with all tables built. The C code keeps the waveform and
/// key-scale tables in statics that it builds once. Here the chip holds them: the result is the
/// same for one instance, and two instances are independent.
pub fn init(samplerate_in: u32) Chip {
    var chip = Chip{};
    const samplerate: u32 = if (samplerate_in == 0) 44100 else samplerate_in;
    chip.int_samplerate = @intCast(samplerate);
    chip.generator_add = toU32(intfrequ * fixedpt / @as(f64, @floatFromInt(chip.int_samplerate)));

    for (&chip.op) |*o| {
        o.* = .{};
        o.op_state = .off;
        o.act_state = op_act_off;
        o.cur_wmask = wavemask[0];
        o.cur_wform = waveform[0];
        o.left_pan = 1;
        o.right_pan = 1;
    }

    chip.recipsamp = 1.0 / @as(f64, @floatFromInt(chip.int_samplerate));
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        chip.frqmul[i] = @floatCast(
            frqmul_tab[i] * intfrequ / @as(f64, waveprec) * fixedpt * chip.recipsamp,
        );
    }

    chip.vib_table[0] = 8;
    chip.vib_table[1] = 4;
    chip.vib_table[2] = 0;
    chip.vib_table[3] = -4;
    for (4..vibtab_size) |n| {
        chip.vib_table[n] = chip.vib_table[n - 4] * -1;
    }

    // The order of the C expression is important: `VIBTAB_SIZE * FIXEDPT_LFO / 8192` is integer.
    chip.vibtab_add = toU32(
        @as(f64, @floatFromInt(@as(u64, vibtab_size) * 0x1000000 / 8192)) *
            intfrequ / @as(f64, @floatFromInt(chip.int_samplerate)),
    );
    chip.vibtab_pos = 0;
    chip.vibval_const = @splat(0);

    var trem_table_int: [tremtab_size]i32 = undefined;
    for (0..14) |n| {
        trem_table_int[n] = @as(i32, @intCast(n)) - 13;
    }
    for (14..41) |n| {
        trem_table_int[n] = -@as(i32, @intCast(n)) + 14;
    }
    for (41..53) |n| {
        trem_table_int[n] = @as(i32, @intCast(n)) - 40 - 26;
    }

    for (0..tremtab_size) |n| {
        const trem_val1 = @as(f64, @floatFromInt(trem_table_int[n])) * 4.8 / 26.0 / 6.0;
        const trem_val2 = @as(f64, @floatFromInt(@divTrunc(trem_table_int[n], 4))) *
            1.2 /
            6.0 /
            6.0;
        chip.trem_table[n] = toI32(pow2(trem_val1) * fixedpt);
        chip.trem_table[tremtab_size + n] = toI32(pow2(trem_val2) * fixedpt);
    }

    chip.tremtab_add = toU32(
        @as(f64, tremtab_size) * trem_freq * fixedpt_lfo /
            @as(f64, @floatFromInt(chip.int_samplerate)),
    );
    chip.tremtab_pos = 0;
    chip.tremval_const = @splat(toI32(fixedpt));

    chip.wavtable = wave_table;

    // The key scale level table. It is the table of the book, times 8/3.
    chip.kslev[7] = .{ 0, 24, 32, 37, 40, 43, 45, 47, 48, 0, 0, 0, 0, 0, 0, 0 };
    for (9..16) |n| {
        chip.kslev[7][n] = @intCast(n + 41);
    }
    var j: usize = 7;
    while (j > 0) {
        j -= 1;
        for (0..16) |n| {
            const oct = @as(i32, chip.kslev[j + 1][n]) - 8;
            chip.kslev[j][n] = if (oct < 0) 0 else @intCast(oct);
        }
    }

    chip.noise_seed = 1;
    chip.timers = @splat(.{});
    chip.chip_frames = 0;
    chip.chip_status = 0;
    return chip;
}

// --- the register write (adlib_write) ----------------------------------------------------------

pub fn adlibWrite(chip: *Chip, idx: usize, val: u8) void {
    const second_set: usize = idx & 0x100;
    chip.adlibreg[idx] = val;
    const opl3 = (chip.adlibreg[0x105] & 1) != 0;

    switch (idx & 0xf0) {
        arc_control => switch (idx) {
            // 0x02, 0x03 and 0x04 are the timers, which do not reach the synthesiser: `write`
            // runs them on the chip's own clock, as the C version does.
            0x02, 0x03, 0x04, 0x05 | arc_secondset, 0x08 => {},
            0x04 | arc_secondset => {
                // The four-operator switches, one bit for each pair of operators.
                const pairs = [_][2]usize{
                    .{ 0, 3 },
                    .{ 1, 4 },
                    .{ 2, 5 },
                    .{ 18, 21 },
                    .{ 19, 22 },
                    .{ 20, 23 },
                };
                for (pairs, 0..) |pair, bit| {
                    chip.op[pair[0]].is_4op = (val & (@as(u8, 1) << @intCast(bit))) > 0;
                    chip.op[pair[1]].is_4op_attached = chip.op[pair[0]].is_4op;
                }
            },
            else => {},
        },
        arc_tvs_ksr_mul, arc_tvs_ksr_mul + 0x10 => {
            const num = idx & 7;
            const base = (idx -% arc_tvs_ksr_mul) & 0xff;
            if (num < 6 and base < 22) {
                const modop: usize = regbase2modop[if (second_set != 0) base + 22 else base];
                const regbase = base + second_set;
                const chanbase: usize = if (second_set != 0) modop - 18 + arc_secondset else modop;
                const o = &chip.op[modop + (if (num < 3) @as(usize, 0) else 9)];
                changeKeepSustain(chip, regbase, o);
                changeVibrato(chip, regbase, o);
                if (opl3 and chip.op[modop].is_4op_attached) {
                    changeFrequency(chip, chanbase - 3, regbase, o);
                } else {
                    changeFrequency(chip, chanbase, regbase, o);
                }
            }
        },
        arc_ksl_outlev, arc_ksl_outlev + 0x10 => {
            const num = idx & 7;
            const base = (idx -% arc_ksl_outlev) & 0xff;
            if (num < 6 and base < 22) {
                const modop: usize = regbase2modop[if (second_set != 0) base + 22 else base];
                const chanbase: usize = if (second_set != 0) modop - 18 + arc_secondset else modop;
                const o = &chip.op[modop + (if (num < 3) @as(usize, 0) else 9)];
                const regbase = base + second_set;
                if (opl3 and chip.op[modop].is_4op_attached) {
                    changeFrequency(chip, chanbase - 3, regbase, o);
                } else {
                    changeFrequency(chip, chanbase, regbase, o);
                }
            }
        },
        arc_attr_decr, arc_attr_decr + 0x10 => {
            const num = idx & 7;
            const base = (idx -% arc_attr_decr) & 0xff;
            if (num < 6 and base < 22) {
                const regbase = base + second_set;
                const o = &chip.op[regbase2op[if (second_set != 0) base + 22 else base]];
                changeAttackRate(chip, regbase, o);
                changeDecayRate(chip, regbase, o);
            }
        },
        arc_susl_relr, arc_susl_relr + 0x10 => {
            const num = idx & 7;
            const base = (idx -% arc_susl_relr) & 0xff;
            if (num < 6 and base < 22) {
                const regbase = base + second_set;
                const o = &chip.op[regbase2op[if (second_set != 0) base + 22 else base]];
                changeReleaseRate(chip, regbase, o);
                changeSustainLevel(chip, regbase, o);
            }
        },
        arc_freq_num => {
            const base = (idx -% arc_freq_num) & 0xff;
            if (base < 9) {
                const opbase: usize = if (second_set != 0) base + 18 else base;
                if (opl3 and chip.op[opbase].is_4op_attached) return;
                const modbase: usize = modulatorbase[base] + second_set;
                const chanbase = base + second_set;
                changeFrequency(chip, chanbase, modbase, &chip.op[opbase]);
                changeFrequency(chip, chanbase, modbase + 3, &chip.op[opbase + 9]);
                if (opl3 and chip.op[opbase].is_4op) {
                    changeFrequency(chip, chanbase, modbase + 8, &chip.op[opbase + 3]);
                    changeFrequency(chip, chanbase, modbase + 3 + 8, &chip.op[opbase + 3 + 9]);
                }
            }
        },
        arc_kon_bnum => {
            if (idx == arc_perc_mode) {
                if (second_set != 0) return;
                percussion(chip, val);
                return;
            }
            const base = (idx -% arc_kon_bnum) & 0xff;
            if (base < 9) {
                const opbase: usize = if (second_set != 0) base + 18 else base;
                if (opl3 and chip.op[opbase].is_4op_attached) return;
                const modbase: usize = modulatorbase[base] + second_set;

                if ((val & 32) != 0) {
                    enableOperator(chip, modbase, &chip.op[opbase], op_act_normal);
                    enableOperator(chip, modbase + 3, &chip.op[opbase + 9], op_act_normal);
                    if (opl3 and chip.op[opbase].is_4op) {
                        enableOperator(chip, modbase + 8, &chip.op[opbase + 3], op_act_normal);
                        enableOperator(
                            chip,
                            modbase + 3 + 8,
                            &chip.op[opbase + 3 + 9],
                            op_act_normal,
                        );
                    }
                } else {
                    disableOperator(&chip.op[opbase], op_act_normal);
                    disableOperator(&chip.op[opbase + 9], op_act_normal);
                    if (opl3 and chip.op[opbase].is_4op) {
                        disableOperator(&chip.op[opbase + 3], op_act_normal);
                        disableOperator(&chip.op[opbase + 3 + 9], op_act_normal);
                    }
                }

                const chanbase = base + second_set;
                changeFrequency(chip, chanbase, modbase, &chip.op[opbase]);
                changeFrequency(chip, chanbase, modbase + 3, &chip.op[opbase + 9]);
                if (opl3 and chip.op[opbase].is_4op) {
                    changeFrequency(chip, chanbase, modbase + 8, &chip.op[opbase + 3]);
                    changeFrequency(chip, chanbase, modbase + 3 + 8, &chip.op[opbase + 3 + 9]);
                }
            }
        },
        arc_feedback => {
            const base = (idx -% arc_feedback) & 0xff;
            if (base < 9) {
                const opbase: usize = if (second_set != 0) base + 18 else base;
                const chanbase = base + second_set;
                changeFeedback(chip, chanbase, &chip.op[opbase]);
                chip.op[opbase].left_pan = (val & 0x10) >> 4;
                chip.op[opbase].right_pan = (val & 0x20) >> 5;
            }
        },
        arc_wave_sel, arc_wave_sel + 0x10 => {
            const num = idx & 7;
            const base = (idx -% arc_wave_sel) & 0xff;
            if (num < 6 and base < 22) {
                const wselbase: usize = if (second_set != 0) base + 22 else base;
                chip.wave_sel[wselbase] = if (opl3) val & 7 else val & 3;
                const o = &chip.op[regbase2modop[wselbase] + (if (num < 3) @as(usize, 0) else 9)];
                changeWaveform(chip, wselbase, o);
            }
        },
        else => {},
    }
}

/// The rhythm register 0xBD: five drums. Each drum needs bit 5 (rhythm mode) and its own bit,
/// and uses its own operators.
fn percussion(chip: *Chip, val: u8) void {
    // Bass drum: two operators of channel 6.
    if ((val & 0x30) == 0x30) {
        enableOperator(chip, 16, &chip.op[6], op_act_perc);
        changeFrequency(chip, 6, 16, &chip.op[6]);
        enableOperator(chip, 16 + 3, &chip.op[6 + 9], op_act_perc);
        changeFrequency(chip, 6, 16 + 3, &chip.op[6 + 9]);
    } else {
        disableOperator(&chip.op[6], op_act_perc);
        disableOperator(&chip.op[6 + 9], op_act_perc);
    }
    if ((val & 0x28) == 0x28) { // Snare
        enableOperator(chip, 17 + 3, &chip.op[16], op_act_perc);
        changeFrequency(chip, 7, 17 + 3, &chip.op[16]);
    } else disableOperator(&chip.op[16], op_act_perc);
    if ((val & 0x24) == 0x24) { // Tom-tom
        enableOperator(chip, 18, &chip.op[8], op_act_perc);
        changeFrequency(chip, 8, 18, &chip.op[8]);
    } else disableOperator(&chip.op[8], op_act_perc);
    if ((val & 0x22) == 0x22) { // Cymbal
        enableOperator(chip, 18 + 3, &chip.op[8 + 9], op_act_perc);
        changeFrequency(chip, 8, 18 + 3, &chip.op[8 + 9]);
    } else disableOperator(&chip.op[8 + 9], op_act_perc);
    if ((val & 0x21) == 0x21) { // Hi-hat
        enableOperator(chip, 17, &chip.op[7], op_act_perc);
        changeFrequency(chip, 7, 17, &chip.op[7]);
    } else disableOperator(&chip.op[7], op_act_perc);
}

// --- rendering (adlib_getsample) ---------------------------------------------------------------

fn clipit16(ival: i32) i16 {
    if (ival < 32768) {
        if (ival > -32769) return @intCast(ival);
        return -32768;
    }
    return 32767;
}

/// The per-block scratch buffers of the render. The C code keeps them on the stack of
/// `adlib_getsample`.
const Render = struct {
    outbufl: [blockbuf_size]i32 = @splat(0),
    outbufr: [blockbuf_size]i32 = @splat(0),
    vib_lut: [blockbuf_size]i32 = @splat(0),
    trem_lut: [blockbuf_size]i32 = @splat(0),
    end: usize = 0,
    opl3: bool = false,

    /// `CHANVAL_OUT`: in OPL3 mode a channel is panned. Otherwise all output goes to the left
    /// buffer, and the right buffer is not used.
    fn out(self: *Render, i: usize, chanval: i32, o: *const Operator) void {
        if (self.opl3) {
            self.outbufl[i] +%= chanval *% o.left_pan;
            self.outbufr[i] +%= chanval *% o.right_pan;
        } else {
            self.outbufl[i] +%= chanval;
        }
    }
};

/// `VIBFAC` is `70 / 50000` without parentheses, so the whole expression is integer arithmetic in
/// the C version and here: `(vib_lut * freq_high / 8) * 65536 * 70 / 50000`.
fn vibValue(lut: i32, freq_high: i32) i32 {
    return @divTrunc(@divTrunc(lut * freq_high, 8) * 65536 * 70, 50000);
}

fn fillVib(out: *[blockbuf_size]i32, r: *const Render, freq_high: i32) void {
    for (0..r.end) |i| {
        out[i] = vibValue(r.vib_lut[i], freq_high);
    }
}

pub fn getSample(chip: *Chip, dst: []i16, numsamples: usize) void {
    var r = Render{};
    var written: usize = 0;
    var cursmp: usize = 0;
    while (cursmp < numsamples) : (cursmp += r.end) {
        r.end = @min(numsamples - cursmp, blockbuf_size);
        r.opl3 = (chip.adlibreg[0x105] & 1) != 0;
        @memset(r.outbufl[0..r.end], 0);
        if (r.opl3) {
            @memset(r.outbufr[0..r.end], 0);
        }

        // The vibrato and tremolo tables for this block.
        const vib_tshift: u5 = if ((chip.adlibreg[arc_perc_mode] & 0x40) == 0) 1 else 0;
        for (0..r.end) |i| {
            chip.vibtab_pos +%= chip.vibtab_add;
            if (chip.vibtab_pos / 0x1000000 >= vibtab_size) {
                chip.vibtab_pos -%= vibtab_size * 0x1000000;
            }
            r.vib_lut[i] = chip.vib_table[chip.vibtab_pos / 0x1000000] >> vib_tshift;

            chip.tremtab_pos +%= chip.tremtab_add;
            if (chip.tremtab_pos / 0x1000000 >= tremtab_size) {
                chip.tremtab_pos -%= tremtab_size * 0x1000000;
            }
            r.trem_lut[i] = if ((chip.adlibreg[arc_perc_mode] & 0x80) != 0)
                chip.trem_table[chip.tremtab_pos / 0x1000000]
            else
                chip.trem_table[tremtab_size + chip.tremtab_pos / 0x1000000];
        }

        if ((chip.adlibreg[arc_perc_mode] & 0x20) != 0) {
            renderPercussion(chip, &r);
        }
        renderChannels(chip, &r);

        // The output always has two channels. In OPL2 mode the left buffer goes to both.
        for (0..r.end) |i| {
            const left = clipit16(r.outbufl[i] *% 2);
            const right = if (r.opl3) clipit16(r.outbufr[i] *% 2) else left;
            if (written + 1 < dst.len) {
                dst[written] = left;
                dst[written + 1] = right;
            }
            written += 2;
        }
        if (r.end == 0) break;
    }
}

/// The rhythm section: five drums on the operators of channels 6, 7 and 8.
fn renderPercussion(chip: *Chip, r: *Render) void {
    // Bass drum, on the operator pair of channel 6.
    if ((chip.adlibreg[arc_feedback + 6] & 1) != 0) {
        // Additive: only the carrier sounds.
        if (chip.op[15].op_state != .off) {
            const v1: []const i32 = if (chip.op[15].vibrato) blk: {
                fillVib(&chip.vibval_var1, r, chip.op[15].freq_high);
                break :blk &chip.vibval_var1;
            } else &chip.vibval_const;
            const t1: []const i32 = if (chip.op[15].tremolo) &r.trem_lut else &chip.tremval_const;
            for (0..r.end) |i| {
                chip.operatorAdvance(&chip.op[15], v1[i]);
                Chip.operatorStep(&chip.op[15]);
                chip.operatorOutput(&chip.op[15], 0, t1[i]);
                r.out(i, chip.op[15].cval *% 2, &chip.op[6]);
            }
        }
    } else {
        // Frequency modulation: the modulator feeds the carrier.
        if (chip.op[15].op_state != .off or chip.op[6].op_state != .off) {
            const v1: []const i32 = if (chip.op[6].vibrato and chip.op[6].op_state != .off) blk: {
                fillVib(&chip.vibval_var1, r, chip.op[6].freq_high);
                break :blk &chip.vibval_var1;
            } else &chip.vibval_const;
            const v2: []const i32 = if (chip.op[15].vibrato and chip.op[15].op_state != .off) blk: {
                fillVib(&chip.vibval_var2, r, chip.op[15].freq_high);
                break :blk &chip.vibval_var2;
            } else &chip.vibval_const;
            const t1: []const i32 = if (chip.op[6].tremolo) &r.trem_lut else &chip.tremval_const;
            const t2: []const i32 = if (chip.op[15].tremolo) &r.trem_lut else &chip.tremval_const;
            for (0..r.end) |i| {
                chip.operatorAdvance(&chip.op[6], v1[i]);
                Chip.operatorStep(&chip.op[6]);
                const feedback = (chip.op[6].lastcval +% chip.op[6].cval) *% chip.op[6].mfbi;
                chip.operatorOutput(&chip.op[6], @divTrunc(feedback, 2), t1[i]);

                chip.operatorAdvance(&chip.op[15], v2[i]);
                Chip.operatorStep(&chip.op[15]);
                chip.operatorOutput(&chip.op[15], chip.op[6].cval *% 0x10000, t2[i]);

                r.out(i, chip.op[15].cval *% 2, &chip.op[6]);
            }
        }
    }

    // Tom-tom, on the modulator of channel 8.
    if (chip.op[8].op_state != .off) {
        const v3: []const i32 = if (chip.op[8].vibrato) blk: {
            fillVib(&chip.vibval_var1, r, chip.op[8].freq_high);
            break :blk &chip.vibval_var1;
        } else &chip.vibval_const;
        const t3: []const i32 = if (chip.op[8].tremolo) &r.trem_lut else &chip.tremval_const;
        for (0..r.end) |i| {
            chip.operatorAdvance(&chip.op[8], v3[i]);
            Chip.operatorStep(&chip.op[8]);
            chip.operatorOutput(&chip.op[8], 0, t3[i]);
            r.out(i, chip.op[8].cval *% 2, &chip.op[8]);
        }
    }

    // Hi-hat, snare and cymbal, which share a phase generator.
    if (chip.op[7].op_state != .off or
        chip.op[16].op_state != .off or
        chip.op[17].op_state != .off) {
        const v1: []const i32 = if (chip.op[7].vibrato and chip.op[7].op_state != .off) blk: {
            fillVib(&chip.vibval_var1, r, chip.op[7].freq_high);
            break :blk &chip.vibval_var1;
        } else &chip.vibval_const;
        // The emulator tests `== OFF` here, where every other site tests `!= OFF`. This file
        // keeps the condition of the emulator.
        const v2: []const i32 = if (chip.op[16].vibrato and chip.op[16].op_state == .off) blk: {
            fillVib(&chip.vibval_var2, r, chip.op[16].freq_high);
            break :blk &chip.vibval_var2;
        } else &chip.vibval_const;
        const t1: []const i32 = if (chip.op[7].tremolo) &r.trem_lut else &chip.tremval_const;
        const t2: []const i32 = if (chip.op[16].tremolo) &r.trem_lut else &chip.tremval_const;
        const v4: []const i32 = if (chip.op[17].vibrato and chip.op[17].op_state == .off) blk: {
            fillVib(&chip.vibval_var2, r, chip.op[17].freq_high);
            break :blk &chip.vibval_var2;
        } else &chip.vibval_const;
        const t4: []const i32 = if (chip.op[17].tremolo) &r.trem_lut else &chip.tremval_const;

        for (0..r.end) |i| {
            chip.operatorAdvanceDrums(7, v1[i], 16, v2[i], 17, v4[i]);

            Chip.operatorStep(&chip.op[7]);
            chip.operatorOutput(&chip.op[7], 0, t1[i]);
            Chip.operatorStep(&chip.op[16]);
            chip.operatorOutput(&chip.op[16], 0, t2[i]);
            Chip.operatorStep(&chip.op[17]);
            chip.operatorOutput(&chip.op[17], 0, t4[i]);

            const chanval = (chip.op[7].cval +% chip.op[16].cval +% chip.op[17].cval) *% 2;
            r.out(i, chanval, &chip.op[8]);
        }
    }
}

/// The eighteen (or nine) melodic channels, from the highest to the lowest, as in the emulator.
fn renderChannels(chip: *Chip, r: *Render) void {
    const max_channel: usize = if (r.opl3) num_channels else num_channels / 2;
    var ch: isize = @as(isize, @intCast(max_channel)) - 1;
    while (ch >= 0) : (ch -= 1) {
        const cur_ch: usize = @intCast(ch);
        // When the rhythm section is on, it uses channels 6 to 8.
        if ((chip.adlibreg[arc_perc_mode] & 0x20) != 0 and cur_ch >= 6 and cur_ch < 9) continue;

        var k: usize = cur_ch;
        var b: usize = cur_ch;
        if (cur_ch >= 9) {
            b = cur_ch + 9; // the second set is operators 18..35
            k = cur_ch - 9 + 256; // and registers 0x100 onwards
        }
        if (r.opl3 and chip.op[b].is_4op_attached) continue;

        const additive = (chip.adlibreg[arc_feedback + k] & 1) != 0;
        const four_op = r.opl3 and chip.op[b].is_4op;
        const second_additive = four_op and (chip.adlibreg[arc_feedback + k + 3] & 1) != 0;

        if (additive) {
            if (four_op) {
                if (second_additive) {
                    // AM-AM: op1[fb] + (op2 * op3) + op4.
                    armFeedbackOnly(chip, r, b, 0);
                    armModulated(chip, r, b, 9, 3);
                    armPlain(chip, r, b, 3 + 9);
                } else {
                    // AM-FM: op1[fb] + (op2 * op3 * op4).
                    armFeedbackOnly(chip, r, b, 0);
                    armChain3(chip, r, b);
                }
                continue;
            }
            // Two-operator additive: both operators sound.
            if (chip.op[b + 9].op_state == .off and chip.op[b].op_state == .off) continue;
            const v1 = pickVib(chip, r, b + 0, &chip.vibval_var1, true);
            const v2 = pickVib(chip, r, b + 9, &chip.vibval_var2, true);
            const t1 = pickTrem(chip, r, b + 0);
            const t2 = pickTrem(chip, r, b + 9);
            for (0..r.end) |i| {
                chip.operatorAdvance(&chip.op[b], v1[i]);
                Chip.operatorStep(&chip.op[b]);
                const feedback = (chip.op[b].lastcval +% chip.op[b].cval) *% chip.op[b].mfbi;
                chip.operatorOutput(&chip.op[b], @divTrunc(feedback, 2), t1[i]);

                chip.operatorAdvance(&chip.op[b + 9], v2[i]);
                Chip.operatorStep(&chip.op[b + 9]);
                chip.operatorOutput(&chip.op[b + 9], 0, t2[i]);

                r.out(i, chip.op[b + 9].cval +% chip.op[b].cval, &chip.op[b]);
            }
        } else {
            if (four_op) {
                if (second_additive) {
                    // FM-AM: (op1[fb] * op2) + (op3 * op4).
                    armPair(chip, r, b);
                    armPairPlain(chip, r, b, 3);
                } else {
                    // FM-FM: op1[fb] * op2 * op3 * op4.
                    armChain4(chip, r, b);
                }
                continue;
            }
            // Two-operator frequency modulation, which is what the game's music uses.
            if (chip.op[b + 9].op_state == .off and chip.op[b].op_state == .off) continue;
            const v1 = pickVib(chip, r, b + 0, &chip.vibval_var1, true);
            const v2 = pickVib(chip, r, b + 9, &chip.vibval_var2, true);
            const t1 = pickTrem(chip, r, b + 0);
            const t2 = pickTrem(chip, r, b + 9);
            for (0..r.end) |i| {
                chip.operatorAdvance(&chip.op[b], v1[i]);
                Chip.operatorStep(&chip.op[b]);
                const feedback = (chip.op[b].lastcval +% chip.op[b].cval) *% chip.op[b].mfbi;
                chip.operatorOutput(&chip.op[b], @divTrunc(feedback, 2), t1[i]);

                chip.operatorAdvance(&chip.op[b + 9], v2[i]);
                Chip.operatorStep(&chip.op[b + 9]);
                chip.operatorOutput(&chip.op[b + 9], chip.op[b].cval *% 0x10000, t2[i]);

                r.out(i, chip.op[b + 9].cval, &chip.op[b]);
            }
        }
    }
}

/// `vibval1 = ...`: the variable table when the operator uses vibrato, else the constant table.
/// `check_state` tells whether the site also requires the operator to be sounding. The emulator
/// is not consistent about this, and the difference is audible.
fn pickVib(
    chip: *Chip,
    r: *const Render,
    index: usize,
    buf: *[blockbuf_size]i32,
    check_state: bool,
) []const i32 {
    const o = &chip.op[index];
    const want = o.vibrato and (!check_state or o.op_state != .off);
    if (!want) return &chip.vibval_const;
    fillVib(buf, r, o.freq_high);
    return buf;
}

fn pickTrem(chip: *Chip, r: *const Render, index: usize) []const i32 {
    return if (chip.op[index].tremolo) &r.trem_lut else &chip.tremval_const;
}

/// One operator with its own feedback and no modulator.
fn armFeedbackOnly(chip: *Chip, r: *Render, b: usize, off: usize) void {
    if (chip.op[b + off].op_state == .off) return;
    const v1 = pickVib(chip, r, b + off, &chip.vibval_var1, false);
    const t1 = pickTrem(chip, r, b + off);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b + off], v1[i]);
        Chip.operatorStep(&chip.op[b + off]);
        const feedback = (chip.op[b + off].lastcval +% chip.op[b + off].cval) *%
            chip.op[b + off].mfbi;
        chip.operatorOutput(&chip.op[b + off], @divTrunc(feedback, 2), t1[i]);
        r.out(i, chip.op[b + off].cval, &chip.op[b]);
    }
}

/// One operator that modulates another. The second operator advances without vibrato.
fn armModulated(chip: *Chip, r: *Render, b: usize, modulator: usize, carrier: usize) void {
    if (chip.op[b + carrier].op_state == .off and chip.op[b + modulator].op_state == .off) return;
    const v1 = pickVib(chip, r, b + modulator, &chip.vibval_var1, true);
    const t1 = pickTrem(chip, r, b + modulator);
    const t2 = pickTrem(chip, r, b + carrier);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b + modulator], v1[i]);
        Chip.operatorStep(&chip.op[b + modulator]);
        chip.operatorOutput(&chip.op[b + modulator], 0, t1[i]);

        chip.operatorAdvance(&chip.op[b + carrier], 0);
        Chip.operatorStep(&chip.op[b + carrier]);
        chip.operatorOutput(&chip.op[b + carrier], chip.op[b + modulator].cval *% 0x10000, t2[i]);

        r.out(i, chip.op[b + carrier].cval, &chip.op[b]);
    }
}

/// One operator alone, without vibrato or modulation.
fn armPlain(chip: *Chip, r: *Render, b: usize, off: usize) void {
    if (chip.op[b + off].op_state == .off) return;
    const t1 = pickTrem(chip, r, b + off);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b + off], 0);
        Chip.operatorStep(&chip.op[b + off]);
        chip.operatorOutput(&chip.op[b + off], 0, t1[i]);
        r.out(i, chip.op[b + off].cval, &chip.op[b]);
    }
}

/// op2 -> op3 -> op4: the second half of the AM-FM arm.
fn armChain3(chip: *Chip, r: *Render, b: usize) void {
    if (chip.op[b + 9].op_state == .off and chip.op[b + 3].op_state == .off and
        chip.op[b + 3 + 9].op_state == .off) {
        return;
    }
    const v1 = pickVib(chip, r, b + 9, &chip.vibval_var1, true);
    const t1 = pickTrem(chip, r, b + 9);
    const t2 = pickTrem(chip, r, b + 3);
    const t3 = pickTrem(chip, r, b + 3 + 9);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b + 9], v1[i]);
        Chip.operatorStep(&chip.op[b + 9]);
        chip.operatorOutput(&chip.op[b + 9], 0, t1[i]);

        chip.operatorAdvance(&chip.op[b + 3], 0);
        Chip.operatorStep(&chip.op[b + 3]);
        chip.operatorOutput(&chip.op[b + 3], chip.op[b + 9].cval *% 0x10000, t2[i]);

        chip.operatorAdvance(&chip.op[b + 3 + 9], 0);
        Chip.operatorStep(&chip.op[b + 3 + 9]);
        chip.operatorOutput(&chip.op[b + 3 + 9], chip.op[b + 3].cval *% 0x10000, t3[i]);

        r.out(i, chip.op[b + 3 + 9].cval, &chip.op[b]);
    }
}

/// op1[fb] * op2: the first half of the FM-AM arm.
fn armPair(chip: *Chip, r: *Render, b: usize) void {
    if (chip.op[b].op_state == .off and chip.op[b + 9].op_state == .off) return;
    const v1 = pickVib(chip, r, b + 0, &chip.vibval_var1, true);
    const v2 = pickVib(chip, r, b + 9, &chip.vibval_var2, true);
    const t1 = pickTrem(chip, r, b + 0);
    const t2 = pickTrem(chip, r, b + 9);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b], v1[i]);
        Chip.operatorStep(&chip.op[b]);
        const feedback = (chip.op[b].lastcval +% chip.op[b].cval) *% chip.op[b].mfbi;
        chip.operatorOutput(&chip.op[b], @divTrunc(feedback, 2), t1[i]);

        chip.operatorAdvance(&chip.op[b + 9], v2[i]);
        Chip.operatorStep(&chip.op[b + 9]);
        chip.operatorOutput(&chip.op[b + 9], chip.op[b].cval *% 0x10000, t2[i]);

        r.out(i, chip.op[b + 9].cval, &chip.op[b]);
    }
}

/// op3 * op4, both without vibrato: the second half of the FM-AM arm.
fn armPairPlain(chip: *Chip, r: *Render, b: usize, off: usize) void {
    if (chip.op[b + off].op_state == .off and chip.op[b + off + 9].op_state == .off) return;
    const t1 = pickTrem(chip, r, b + off);
    const t2 = pickTrem(chip, r, b + off + 9);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b + off], 0);
        Chip.operatorStep(&chip.op[b + off]);
        chip.operatorOutput(&chip.op[b + off], 0, t1[i]);

        chip.operatorAdvance(&chip.op[b + off + 9], 0);
        Chip.operatorStep(&chip.op[b + off + 9]);
        chip.operatorOutput(&chip.op[b + off + 9], chip.op[b + off].cval *% 0x10000, t2[i]);

        r.out(i, chip.op[b + off + 9].cval, &chip.op[b]);
    }
}

/// op1[fb] * op2 * op3 * op4: the whole four-operator chain.
fn armChain4(chip: *Chip, r: *Render, b: usize) void {
    if (chip.op[b].op_state == .off and chip.op[b + 9].op_state == .off and
        chip.op[b + 3].op_state == .off and chip.op[b + 3 + 9].op_state == .off) {
        return;
    }
    const v1 = pickVib(chip, r, b + 0, &chip.vibval_var1, true);
    const v2 = pickVib(chip, r, b + 9, &chip.vibval_var2, true);
    const t1 = pickTrem(chip, r, b + 0);
    const t2 = pickTrem(chip, r, b + 9);
    const t3 = pickTrem(chip, r, b + 3);
    const t4 = pickTrem(chip, r, b + 3 + 9);
    for (0..r.end) |i| {
        chip.operatorAdvance(&chip.op[b], v1[i]);
        Chip.operatorStep(&chip.op[b]);
        const feedback = (chip.op[b].lastcval +% chip.op[b].cval) *% chip.op[b].mfbi;
        chip.operatorOutput(&chip.op[b], @divTrunc(feedback, 2), t1[i]);

        chip.operatorAdvance(&chip.op[b + 9], v2[i]);
        Chip.operatorStep(&chip.op[b + 9]);
        chip.operatorOutput(&chip.op[b + 9], chip.op[b].cval *% 0x10000, t2[i]);

        chip.operatorAdvance(&chip.op[b + 3], 0);
        Chip.operatorStep(&chip.op[b + 3]);
        chip.operatorOutput(&chip.op[b + 3], chip.op[b + 9].cval *% 0x10000, t3[i]);

        chip.operatorAdvance(&chip.op[b + 3 + 9], 0);
        Chip.operatorStep(&chip.op[b + 3 + 9]);
        chip.operatorOutput(&chip.op[b + 3 + 9], chip.op[b + 3].cval *% 0x10000, t4[i]);

        r.out(i, chip.op[b + 3 + 9].cval, &chip.op[b]);
    }
}

// --- the timers and the status register ---------------------------------------------------------

fn statusRefresh(chip: *Chip) void {
    var s: u8 = 0;
    if (chip.timers[0].overflow) {
        s |= 0x40;
    }
    if (chip.timers[1].overflow) {
        s |= 0x20;
    }
    if (s != 0) {
        s |= 0x80;
    }
    chip.chip_status = s;
}

fn timerStart(chip: *Chip, t: usize) void {
    const tm = &chip.timers[t];
    if (tm.running) return; // a running timer is not restarted, as in DOSBox
    tm.running = true;
    const rate: u64 = @intCast(chip.int_samplerate);
    tm.period = ((@as(u64, 256 - @as(u64, tm.counter)) * timer_scale_us[t] * rate) << 16) / 1000000;
    if (tm.period == 0) {
        tm.period = 1;
    }
    tm.expiry = (chip.chip_frames << 16) + tm.period;
}

fn timersUpdate(chip: *Chip) void {
    const now = chip.chip_frames << 16;
    for (&chip.timers) |*tm| {
        if (tm.running and now >= tm.expiry) {
            const k = (now - tm.expiry) / tm.period + 1;
            tm.expiry += k * tm.period;
            if (!tm.masked) {
                tm.overflow = true;
            }
        }
    }
    statusRefresh(chip);
}

fn timerWrite(chip: *Chip, reg: usize, val: u8) void {
    switch (reg) {
        0x02 => chip.timers[0].counter = val,
        0x03 => chip.timers[1].counter = val,
        0x04 => {
            if ((val & 0x80) != 0) {
                // IRQ-RST: clears the flags. The other bits are ignored, and the timers continue.
                chip.timers[0].overflow = false;
                chip.timers[1].overflow = false;
            } else {
                if ((val & 0x01) != 0) {
                    timerStart(chip, 0);
                } else {
                    chip.timers[0].running = false;
                }
                chip.timers[0].masked = (val & 0x40) != 0;
                if (chip.timers[0].masked) {
                    chip.timers[0].overflow = false;
                }
                if ((val & 0x02) != 0) {
                    timerStart(chip, 1);
                } else {
                    chip.timers[1].running = false;
                }
                chip.timers[1].masked = (val & 0x20) != 0;
                if (chip.timers[1].masked) {
                    chip.timers[1].overflow = false;
                }
            }
        },
        else => {},
    }
    statusRefresh(chip);
}

// --- what a host drives ------------------------------------------------------------------------

/// A register write to bank 0 or 1 (`reg` 0x000..0x1ff). As in DOSBox, the two timer registers
/// and the timer control register do not reach the synthesiser.
pub fn write(chip: *Chip, reg: usize, value: u8) void {
    const r = reg & 0x1ff;
    if (r == 0x02 or r == 0x03 or r == 0x04) {
        timerWrite(chip, r, value);
        return;
    }
    adlibWrite(chip, r, value);
}

/// Renders interleaved stereo frames into `dst` and replaces its contents. `dst` holds two
/// samples for each frame.
pub fn render(chip: *Chip, dst: []i16) void {
    const frames = dst.len / 2;
    if (frames == 0) return;
    @memset(dst, 0);
    getSample(chip, dst, frames);
    chip.chip_frames += frames;
    timersUpdate(chip);
}

const testing = std.testing;

test "a fresh chip is silent and its tables are built" {
    var chip = init(44100);
    var out: [128]i16 = undefined;
    render(&chip, &out);
    for (out) |s| {
        try testing.expectEqual(@as(i16, 0), s);
    }
    // The waveform table is a sine with the value 16384 at a quarter turn.
    try testing.expectEqual(@as(i16, 16384), chip.wavtable[waveprec + (waveprec >> 2)]);
    try testing.expect(chip.generator_add > 0);
    try testing.expectEqual(@as(u8, 0), chip.chip_status);
}

test "the waveform table built at compile time is the one built at run time" {
    var pi = wave_pi;
    std.mem.doNotOptimizeAway(&pi);
    const at_run_time = buildWaveTable(pi);
    try testing.expectEqualSlices(i16, &at_run_time, &wave_table);
}

test "pow2 is pow with a base known only at run time, to the bit" {
    var base: f64 = 2.0;
    std.mem.doNotOptimizeAway(&base);
    const Check = struct {
        fn same(b: f64, x: f64) !void {
            const want: u64 = @bitCast(std.math.pow(f64, b, x));
            const got: u64 = @bitCast(pow2(x));
            if (want != got) {
                std.debug.print("pow2({e}): {x} and not {x}\n", .{ x, got, want });
                return error.TestExpectedEqual;
            }
        }
    };
    // Every exponent of the handlers: the volumes in eighths, the sustain levels in halves, the
    // tremolo tables, and the decay and release rates at the rates that an output can have.
    var eighths: i32 = -8 * 64;
    while (eighths <= 8 * 64) : (eighths += 1) {
        try Check.same(base, @as(f64, @floatFromInt(eighths)) / 8.0);
    }
    for (0..64) |tl| {
        for (kslmul) |m| {
            for (0..64) |level| {
                const vol_in = @as(f64, @floatFromInt(tl)) + m * @as(f64, @floatFromInt(level));
                try Check.same(base, vol_in * -0.125 - 14);
            }
        }
    }
    for (0..15) |level| {
        try Check.same(base, @as(f64, @floatFromInt(level)) * -0.5);
    }
    for (0..tremtab_size) |n| {
        const t: i32 = if (n < 14)
            @as(i32, @intCast(n)) - 13
        else if (n < 41)
            -@as(i32, @intCast(n)) + 14
        else
            @as(i32, @intCast(n)) - 66;
        try Check.same(base, @as(f64, @floatFromInt(t)) * 4.8 / 26.0 / 6.0);
        try Check.same(base, @as(f64, @floatFromInt(@divTrunc(t, 4))) * 1.2 / 6.0 / 6.0);
    }
    for ([_]u32{ 8000, 11025, 22050, 32000, 44100, 48000, 88200, 96000, 192000 }) |rate| {
        const recipsamp = 1.0 / @as(f64, @floatFromInt(rate));
        for (decrelconst) |c| {
            for (0..24) |k| {
                const f = -7.4493 * c * recipsamp;
                try Check.same(base, f * pow2(@floatFromInt(k)));
            }
        }
    }
    // And a sweep of other values.
    var prng = std.Random.DefaultPrng.init(0x5eed_0f_2);
    const random = prng.random();
    for (0..200_000) |_| {
        try Check.same(base, (random.float(f64) - 0.5) * 128.0);
    }
    for (0..20_000) |_| {
        try Check.same(base, (random.float(f64) - 0.5) * 2048.0);
    }
}

test "a note in OPL3 mode needs a panning bit, which is the trap the oracle caught" {
    const script = [_][2]usize{
        .{ 0x105, 0x01 }, .{ 0x20, 0x01 }, .{ 0x40, 0x10 }, .{ 0x60, 0xf0 }, .{ 0x80, 0x77 },
        .{ 0x23, 0x01 },  .{ 0x43, 0x00 }, .{ 0x63, 0xf0 }, .{ 0x83, 0x77 }, .{ 0xa0, 0x98 },
        .{ 0xb0, 0x31 },
    };
    // With no panning bit the channel reaches neither output.
    var muted = init(44100);
    for (script) |w| {
        write(&muted, w[0], @intCast(w[1]));
    }
    write(&muted, 0xc0, 0x01);
    var out: [256]i16 = undefined;
    render(&muted, &out);
    var loud: usize = 0;
    for (out) |s| {
        if (s != 0) {
            loud += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), loud);

    // With both, it sounds.
    var chip = init(44100);
    for (script) |w| {
        write(&chip, w[0], @intCast(w[1]));
    }
    write(&chip, 0xc0, 0x31);
    render(&chip, &out);
    loud = 0;
    for (out) |s| {
        if (s != 0) {
            loud += 1;
        }
    }
    try testing.expect(loud > 64);
}

test "a timer raises its flag on the chip's own clock and a reset clears it" {
    var chip = init(44100);
    write(&chip, 0x02, 0xf0); // timer 1: 16 * 80 us
    write(&chip, 0x04, 0x01); // started, unmasked
    var out: [128]i16 = undefined;
    // 16 * 80 us is 1.28 ms, which is 57 frames at 44.1 kHz: one render of 64 crosses it.
    render(&chip, &out);
    try testing.expectEqual(@as(u8, 0xc0), chip.chip_status);
    write(&chip, 0x04, 0x80); // IRQ-RST
    try testing.expectEqual(@as(u8, 0), chip.chip_status);
    // A masked timer does not set the flag.
    var masked = init(44100);
    write(&masked, 0x02, 0xf0);
    write(&masked, 0x04, 0x41);
    render(&masked, &out);
    try testing.expectEqual(@as(u8, 0), masked.chip_status);
}

/// The digest of the oracle: FNV-1a over the rendered bytes, little-endian, as the C version
/// reads them.
fn fnv1a(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

const fnv_offset: u64 = 1469598103934665603;

const Observation = struct {
    n: []const u8,
    v: []const u8,
};
const ValueFile = struct {
    observations: []Observation,
};

fn obsText(obs: []const Observation, name: []const u8) ![]const u8 {
    for (obs) |o| {
        if (!std.mem.eql(u8, o.n, name)) continue;
        const colon = std.mem.indexOfScalar(u8, o.v, ':') orelse return error.MalformedValue;
        return o.v[colon + 1..];
    }
    return error.MissingObservation;
}

fn obsNumber(obs: []const Observation, name: []const u8) !u64 {
    return std.fmt.parseInt(u64, try obsText(obs, name), 10);
}

// The emulator's own renders of a script of register writes: vpoolz's oracle, a modified DOSBox
// 0.73, made them.
test "the translation is the same chip as the emulator it came from" {
    const gpa = testing.allocator;
    const script = @embedFile("opl_reference/opl-script.txt");
    const text = @embedFile("opl_reference/opl-render.obs.json");
    const parsed = try std.json.parseFromSlice(
        ValueFile,
        gpa,
        text,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const obs = parsed.value.observations;

    const rate: u32 = @intCast(try obsNumber(obs, "sample_rate"));
    var chip = init(rate);
    const buffer = try gpa.alloc(i16, 2 * 4096);
    defer gpa.free(buffer);

    var whole = fnv_offset;
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        var parts = std.mem.tokenizeScalar(u8, line[1..], ' ');
        if (line[0] == 'w') {
            const reg = try std.fmt.parseInt(
                usize,
                parts.next() orelse return error.MalformedScript,
                16,
            );
            const val = try std.fmt.parseInt(
                u8,
                parts.next() orelse return error.MalformedScript,
                16,
            );
            write(&chip, reg, val);
        } else if (line[0] == 'r') {
            const frames = try std.fmt.parseInt(
                usize,
                parts.next() orelse return error.MalformedScript,
                10,
            );
            if (frames == 0 or frames > 4096) return error.MalformedScript;
            const slice = buffer[0..frames * 2];
            render(&chip, slice);
            const bytes = std.mem.sliceAsBytes(slice);

            var name: [48]u8 = undefined;
            try testing.expectEqual(
                @as(u64, frames),
                try obsNumber(obs, try std.fmt.bufPrint(&name, "render[{d}].frames", .{ index })),
            );
            var want: [16]u8 = undefined;
            const got = try std.fmt.bufPrint(&want, "{x:0>16}", .{ fnv1a(fnv_offset, bytes) });
            try testing.expectEqualStrings(
                try obsText(obs, try std.fmt.bufPrint(&name, "render[{d}].digest", .{ index })),
                got,
            );
            try testing.expectEqual(
                @as(u64, chip.chip_status),
                try obsNumber(obs, try std.fmt.bufPrint(&name, "render[{d}].status", .{ index })),
            );
            whole = fnv1a(whole, bytes);
            index += 1;
        }
    }
    try testing.expectEqual(try obsNumber(obs, "renders"), @as(u64, index));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings(
        try obsText(obs, "digest"),
        try std.fmt.bufPrint(&buf, "{x:0>16}", .{ whole }),
    );
    std.debug.print(
        "audio.opl: {d} renders of the emulator's own script reproduced sample for sample -> AGREE\n",
        .{ index },
    );
}
