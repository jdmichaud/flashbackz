//! Immutable musical content. Parts retain their authored order for simultaneous notes.
const std = @import("std");

pub const Percussion = enum(u8) { bass_drum = 6, snare = 7, tom = 8, cymbal = 9, hi_hat = 10 };
pub const Operator = struct {
    characteristics: u8,
    key_scale: u8,
    attenuation: u8,
    attack_decay: u8,
    sustain_release: u8,
    waveform: u2,
};
pub const Instrument = struct {
    percussion: ?Percussion,
    modulator: Operator,
    carrier: Operator,
    feedback_connection: u8,
    scale_modulator: bool,
};
pub const Note = struct { instrument: u4, pitch: u8, velocity: u7 };
pub const Action = union(enum) { play: Note, release: u8, bend: u14 };
pub const Event = struct { tick: u32, action: Action };
pub const Part = struct { events: []const Event, repeat_ticks: ?u32 };
pub const Score = struct {
    instruments: [16]?Instrument,
    parts: []const Part,
    tick_pit_cycles: u32,
    stop_after_ticks: ?u32,
    restart_after_ticks: ?u32,

    pub fn sampleAt(self: Score, tick: u64, rate: u32) u64 {
        return tick * self.tick_pit_cycles * rate / 1_193_182;
    }
};
pub const Owned = struct {
    arena: *std.heap.ArenaAllocator,
    score: Score,
    pub fn deinit(self: *Owned) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }
};
