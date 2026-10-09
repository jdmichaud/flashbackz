//! The Mega Drive edition's cartridge, whose tunes play during play when the user names it
//! (PLAN MD-B; flashback-re docs/megadrive-music.md). Its file is read at run time and reaches
//! the game through the asset source, under `asset`; nothing of it is in the repository.
const std = @import("std");

/// The cartridge the tunes are read from: `Flashback (Europe) (En,Fr)`. Where its tunes are
/// depends on the edition, so only this one is accepted.
pub const sha256 = "ff8a315882db2bb01fdc876fb5cffb245ae6a999cde063c63ff5ea312e455c67";
pub const size = 2 * 1024 * 1024;

/// The cartridge's name in the asset source.
pub const asset = "MEGADRIVE.MD";

/// Whether `bytes` are the accepted cartridge.
pub fn isCartridge(bytes: []const u8) bool {
    if (bytes.len != size) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, sha256) catch unreachable;
    return std.mem.eql(u8, &digest, &expected);
}

/// The tunes the cartridge plays during play: its effects 68-75 (flashback-re
/// docs/megadrive-music.md 2 and 3). Each is three channels of rows, with up to 15 instruments.
pub const first_tune = 68;
pub const tune_count = 8;
pub const channels = 3;

/// An instrument as the cartridge stores it: the YM2612 values of a channel (bytes 0-30), two
/// bytes the note's frequency replaces, the note's length in frames, the key-on operator mask.
pub const Instrument = [35]u8;

/// One row: an instrument (1-based, 0 to keep the channel's) and a note (1-based, 0 for none)
/// for each channel.
pub const Row = [2 * channels]u8;

pub const Tune = struct {
    rows: []const Row,
    frames_per_row: u16,
    instruments: [15]Instrument,
    /// Added to the note table's word for each instrument.
    detune: [15]i16,
};

pub const Tunes = struct {
    allocator: std.mem.Allocator,
    tunes: [tune_count]Tune,
    /// The note table: a block and frequency number for each note, from note 1.
    pitches: [255]u16,

    pub const ReadError = error{ InvalidCartridge, OutOfMemory };

    /// Reads the tunes of the accepted cartridge's bytes. Every table is bounds-checked.
    pub fn read(allocator: std.mem.Allocator, bytes: []const u8) ReadError!Tunes {
        // Cartridge addresses (flashback-re docs/megadrive-music.md 2, 3): the effect table
        // (address.l and length.w for each effect) and the note table.
        const effects = 0x163CAC;
        const note_table = 0x179D08;
        var result: Tunes = .{ .allocator = allocator, .tunes = undefined, .pitches = undefined };
        for (&result.pitches, 0..) |*pitch, i| pitch.* = try word(bytes, note_table + 2 * i);
        var done: usize = 0;
        errdefer for (result.tunes[0..done]) |tune| allocator.free(tune.rows);
        for (&result.tunes, 0..) |*tune, i| {
            const entry = effects + 6 * (first_tune + i);
            const base = try long(bytes, entry);
            if (try word(bytes, entry + 4) != 0xFFFF) return error.InvalidCartridge;
            const row_count = try word(bytes, base + 60);
            const frames_per_row = try word(bytes, base + 62);
            const rows_at = base + 94;
            const rows_end = rows_at + @as(usize, row_count) * @sizeOf(Row);
            if (rows_end > bytes.len) return error.InvalidCartridge;
            const rows = try allocator.alloc(Row, row_count);
            for (rows, 0..) |*row, r| {
                row.* = bytes[rows_at + r * @sizeOf(Row) ..][0..@sizeOf(Row)].*;
            }
            tune.* = .{
                .rows = rows,
                .frames_per_row = frames_per_row,
                .instruments = undefined,
                .detune = undefined,
            };
            done += 1;
            for (&tune.instruments, &tune.detune, 0..) |*instrument, *detune, k| {
                const at = try long(bytes, base + 4 * k);
                if (at + @sizeOf(Instrument) > bytes.len) return error.InvalidCartridge;
                instrument.* = bytes[at..][0..@sizeOf(Instrument)].*;
                detune.* = @bitCast(try word(bytes, base + 64 + 2 * k));
            }
        }
        return result;
    }

    pub fn deinit(self: *Tunes) void {
        for (self.tunes) |tune| self.allocator.free(tune.rows);
        self.* = undefined;
    }

    fn word(bytes: []const u8, at: usize) error{InvalidCartridge}!u16 {
        if (at + 2 > bytes.len) return error.InvalidCartridge;
        return std.mem.readInt(u16, bytes[at..][0..2], .big);
    }

    fn long(bytes: []const u8, at: usize) error{InvalidCartridge}!u32 {
        if (at + 4 > bytes.len) return error.InvalidCartridge;
        return std.mem.readInt(u32, bytes[at..][0..4], .big);
    }
};

test "only the accepted cartridge is recognised" {
    const other: [size]u8 = @splat(0);
    try std.testing.expect(!isCartridge(&other));
    try std.testing.expect(!isCartridge("short"));
}

test "a cartridge too short for its tables is refused" {
    try std.testing.expectError(error.InvalidCartridge, Tunes.read(std.testing.allocator, "short"));
}
