//! English floppy PRF/INS/MIDI import, recovered from the supplied executable.
//! Binary layouts, track bindings and DOS filename truncation end here.
const std = @import("std");
const platform = @import("../platform.zig");
const score = @import("score.zig");

fn word(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}
fn terminated(bytes: []const u8) ![]const u8 {
    return bytes[0..std.mem.indexOfScalar(u8, bytes, 0) orelse return error.UnterminatedMusicName];
}
/// Reads `DATA/<name><extension>` in capitals; when it is not there, the same file at the root.
fn read(
    source: platform.AssetSource,
    name: []const u8,
    extension: []const u8,
    maximum: usize,
) !platform.OwnedBytes {
    if (name.len == 0) return error.EmptyMusicName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and
            c != '_' and
            c != '.' and
            c != '-') {
            return error.InvalidMusicName;
        }
    }
    var path: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&path, "DATA/{s}{s}", .{ name, extension });
    for (filename) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }
    return source.readAll(filename, maximum) catch |err| switch (err) {
        error.NotFound => source.readAll(filename[5..], maximum),
        else => err,
    };
}
/// An operator in an instrument file (the AdLib INS layout): thirteen words, at these offsets.
const OperatorField = enum(u5) {
    key_scale_level = 0,
    multiple = 2,
    feedback = 4,
    attack = 6,
    sustain_level = 8,
    sustaining = 10,
    decay = 12,
    release = 14,
    total_level = 16,
    tremolo = 18,
    vibrato = 20,
    envelope_scaling = 22,
    connection = 24,
};

fn field(bytes: []const u8, which: OperatorField) u16 {
    return word(bytes, @backingInt(which));
}

fn operator(bytes: []const u8, waveform: u16) score.Operator {
    return .{
        .characteristics = @as(u8, if (field(bytes, .tremolo) != 0) 0x80 else 0) |
            @as(u8, if (field(bytes, .vibrato) != 0) 0x40 else 0) |
            @as(u8, if (field(bytes, .sustaining) != 0) 0x20 else 0) |
            @as(u8, if (field(bytes, .envelope_scaling) != 0) 0x10 else 0) |
            @as(u8, @intCast(field(bytes, .multiple) & 15)),
        .key_scale = @truncate(field(bytes, .key_scale_level) << 6),
        .attenuation = @intCast(field(bytes, .total_level) & 63),
        .attack_decay = @truncate((field(bytes, .attack) << 4) | (field(bytes, .decay) & 15)),
        .sustain_release = @truncate(
            (field(bytes, .sustain_level) << 4) | (field(bytes, .release) & 15),
        ),
        .waveform = @truncate(waveform),
    };
}

/// An instrument file: the percussion mode and voice, the modulator, the carrier, then their
/// waveforms at bytes 74 and 76.
pub fn instrument(bytes: []const u8) !score.Instrument {
    if (bytes.len != 80) return error.InvalidInstrumentSize;
    const percussion: ?score.Percussion = if (bytes[0] == 0)
        null
    else
        std.enums.fromInt(score.Percussion, bytes[1]) orelse
            return error.InvalidPercussionInstrument;
    const modulator = bytes[2..28];
    return .{
        .percussion = percussion,
        .modulator = operator(modulator, word(bytes, 74)),
        .carrier = operator(bytes[28..54], word(bytes, 76)),
        // The supplied instruments hold a connection word of 0 or 1 and a feedback word of 0 to
        // 7 (measured for PLAN FX-6). The two tests below read the connection word differently
        // (whole, low byte), and a larger feedback reaches bits 4 to 7: other values are not
        // checked against the original.
        .feedback_connection = @truncate(
            (field(modulator, .feedback) << 1) |
                @as(u16, if (field(modulator, .connection) == 0) 1 else 0),
        ),
        .scale_modulator = modulator[@backingInt(OperatorField.connection)] == 0,
    };
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.at) return error.TruncatedMidi;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn vlq(self: *Reader) !u32 {
        var result: u32 = 0;
        for (0..4) |_| {
            const b = try self.byte();
            result = (result << 7) | (b & 127);
            if (b < 128) return result;
        }
        return error.InvalidMidiVlq;
    }
    fn chunk(self: *Reader, tag: []const u8) ![]const u8 {
        if (!std.mem.eql(u8, try self.take(4), tag)) return error.InvalidMidiChunk;
        const size = std.mem.readInt(u32, (try self.take(4))[0..4], .big);
        return self.take(size);
    }
};

/// A PRF profile: 752 or 753 bytes (flashback-re docs/floppy-music.md). The game reads these
/// fields:
/// - 0: 16 instrument names, 30 bytes each, each ended by a zero.
/// - 480 and 512: 16 words each, the pitch and the velocity to add to the notes of a part or of
///   a binding.
/// - 544: the interrupts in one tick; 548: the ticks in one bar.
/// - 550: the name of the MIDI file, 20 bytes, ended by a zero.
/// - 570: a word; when it is not zero, program changes select a binding from the words at 572.
/// - 572: 16 words, the program of each binding.
/// - 732: a byte for each part; when it is not zero, the part plays once.
/// - 748: the limit, a signed dword. A positive limit stops the cue; a negative one restarts it.
pub const Profile = struct {
    bytes: []const u8,
    interval: u16,
    bar_ticks: u16,
    limit: i32,
    // The timing fields. `importPart` and `load` read the other fields from `bytes`.
    const interval_at = 544;
    const bar_ticks_at = 548;
    const limit_at = 748;

    pub fn parse(bytes: []const u8) !Profile {
        if (bytes.len != 752 and bytes.len != 753) return error.InvalidMusicProfileSize;
        const interval = word(bytes, interval_at);
        const bar_ticks = word(bytes, bar_ticks_at);
        const limit = std.mem.readInt(i32, bytes[limit_at..][0..4], .little);
        if (interval == 0 or
            interval > 1000 or
            bar_ticks == 0 or
            limit == std.math.minInt(i32)) {
            return error.InvalidMusicTiming;
        }
        return .{ .bytes = bytes, .interval = interval, .bar_ticks = bar_ticks, .limit = limit };
    }
};

/// Imports the MIDI track of `part` as timed events. The notes of a part play the instrument of
/// its binding, which starts as the part's index. An event's tick is 1 plus the sum of the
/// deltas up to it. When byte 732 + part is zero, the part repeats. Its period is the first
/// multiple of `bar_ticks` above its length (the sum of all its deltas).
fn importPart(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    profile: Profile,
    part: usize,
) !score.Part {
    var events: std.ArrayList(score.Event) = .empty;
    var reader: Reader = .{ .bytes = bytes };
    var tick: u32 = 1; // The first callback advances the score clock before handling tracks.
    var binding: usize = part;
    var running: u8 = 0;
    var ended = false;
    while (reader.at < bytes.len) {
        tick = try std.math.add(u32, tick, try reader.vlq());
        if (tick > 10_000_000 or events.items.len >= 100_000) return error.MusicTooLarge;
        var status = try reader.byte();
        if (status < 0x80) {
            if (running == 0) return error.InvalidMidiStatus;
            reader.at -= 1;
            status = running;
        } else if (status < 0xf0) {
            running = status;
        }
        if (status == 0xff) {
            const kind = try reader.byte();
            const payload = try reader.take(try reader.vlq());
            if (kind == 0x2f) {
                if (payload.len != 0) return error.InvalidMidiEnd;
                ended = true;
                break;
            }
            continue;
        }
        if (status == 0xf0 or status == 0xf7) {
            _ = try reader.take(try reader.vlq());
            continue;
        }
        if (status >= 0xf0) return error.InvalidMidiStatus;
        const first = try reader.byte();
        const kind = status >> 4;
        const second = if (kind == 0xc or kind == 0xd) 0 else try reader.byte();
        if (first >= 128 or second >= 128) return error.InvalidMidiData;
        // Without program binding (word 570 at zero), the part selects the additions; else the
        // binding does. The additions wrap at 8 bits, then the velocity stops at 127.
        const adjustment = if (word(profile.bytes, 570) == 0) part else binding;
        const pitch = first +% @as(u8, @truncate(word(profile.bytes, 480 + adjustment * 2)));
        const velocity = @min(
            127,
            second +% @as(u8, @truncate(word(profile.bytes, 512 + adjustment * 2))),
        );
        const action: ?score.Action = switch (kind) {
            0x8 => .{ .release = pitch },
            0x9 => if (second == 0)
                .{ .release = pitch }
            else
                .{
                    .play = .{
                        .instrument = @intCast(binding),
                        .pitch = pitch,
                        .velocity = @intCast(velocity),
                    },
                },
            0xe => .{ .bend = @as(u14, second) << 7 | first },
            // A program change binds the part to the first slot at 572 with that program. With
            // no such slot, the binding stays.
            0xc => change: {
                if (word(profile.bytes, 570) != 0) {
                    for (0..16) |i| {
                        if (word(profile.bytes, 572 + i * 2) == first) {
                            binding = i;
                            break;
                        }
                    }
                }
                break :change null;
            },
            else => null, // Original AdLib playback ignores pressure and controller changes.
        };
        if (action) |value| {
            try events.append(allocator, .{ .tick = tick, .action = value });
        }
    }
    if (!ended or reader.at != bytes.len) return error.InvalidMidiEnd;
    const duration = tick - 1;
    const repeat_ticks = if (profile.bytes[732 + part] != 0)
        null
    else
        duration + profile.bar_ticks - duration % profile.bar_ticks;
    return .{ .events = try events.toOwnedSlice(allocator), .repeat_ticks = repeat_ticks };
}

/// Returns the score of a MIDI file of format 0 or 1, with one part for each track (16 at most).
pub fn decode(
    allocator: std.mem.Allocator,
    midi: []const u8,
    profile: Profile,
    instruments: [16]?score.Instrument,
) !score.Score {
    var reader: Reader = .{ .bytes = midi };
    const header = try reader.chunk("MThd");
    if (header.len != 6 or
        std.mem.readInt(u16, header[0..2], .big) > 1) {
        return error.InvalidMidiHeader;
    }
    const count = std.mem.readInt(u16, header[2..4], .big);
    if (count == 0 or count > 16) return error.TooManyMusicParts;
    const parts = try allocator.alloc(score.Part, count);
    var done: usize = 0;
    errdefer {
        for (parts[0..done]) |part| {
            allocator.free(part.events);
        }
        allocator.free(parts);
    }
    for (parts, 0..) |*part, i| {
        part.* = try importPart(allocator, try reader.chunk("MTrk"), profile, i);
        done += 1;
    }
    if (reader.at != midi.len) return error.TrailingMidiData;
    return .{
        .instruments = instruments,
        .parts = parts,
        // The music interrupt runs at 1,193,182 / 532 Hz (a calibrated PIT divisor); a tick is
        // `interval` interrupts.
        .tick_pit_cycles = 532 * @as(u32, profile.interval),
        // A positive limit stops the events and a negative one restarts every part; 0 sets
        // neither. The sums are in i64, so a limit at either end of its range still fits.
        .stop_after_ticks = if (profile.limit > 0) @intCast(@as(i64, profile.limit) + 1) else null,
        .restart_after_ticks = if (profile.limit < 0)
            @intCast(-@as(i64, profile.limit) + 2)
        else
            null,
    };
}

/// Loads the cue `name`: its profile (`name`.PRF), the MIDI file that it names and its
/// instruments. As in DOS, an instrument's file name keeps only its first 8 characters.
pub fn load(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    name: []const u8,
) !score.Owned {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var file = try read(source, name, ".PRF", 753);
    defer file.deinit();
    const profile = try Profile.parse(file.bytes);
    var midi = try read(source, try terminated(file.bytes[550..570]), "", 1024 * 1024);
    defer midi.deinit();
    var instruments: [16]?score.Instrument = @splat(null);
    for (&instruments, 0..) |*destination, i| {
        const full_name = try terminated(file.bytes[i * 30..][0..30]);
        if (full_name.len == 0) continue;
        var ins = try read(source, full_name[0..@min(8, full_name.len)], ".INS", 80);
        defer ins.deinit();
        destination.* = try instrument(ins.bytes);
    }
    return .{
        .arena = arena,
        .score = try decode(arena.allocator(), midi.bytes, profile, instruments),
    };
}

test "music profile rejects truncated and impossible timing; instruments require valid drums" {
    const t = std.testing;
    var bytes: [753]u8 = @splat(0);
    try t.expectError(error.InvalidMusicProfileSize, Profile.parse(bytes[0..751]));
    try t.expectError(error.InvalidMusicTiming, Profile.parse(&bytes));
    bytes[544] = 7;
    bytes[549] = 12;
    _ = try Profile.parse(&bytes);
    var ins: [80]u8 = @splat(0);
    ins[0] = 1;
    ins[1] = 3;
    try t.expectError(error.InvalidPercussionInstrument, instrument(&ins));
    ins[1] = 9;
    try t.expectEqual(score.Percussion.cymbal, (try instrument(&ins)).percussion.?);
}

test "track import preserves adjustment wrap, zero-velocity release, order and loop alignment" {
    var bytes: [753]u8 = @splat(0);
    bytes[544] = 7;
    bytes[548] = 16;
    bytes[480] = 244;
    bytes[512] = 128;
    const part = try importPart(
        std.testing.allocator,
        &.{ 0, 0x90, 60, 100, 4, 0x90, 60, 0, 0, 0xff, 0x2f, 0 },
        try Profile.parse(&bytes),
        0,
    );
    defer std.testing.allocator.free(part.events);
    try std.testing.expectEqual(@as(u32, 1), part.events[0].tick);
    try std.testing.expectEqual(@as(u8, 48), part.events[0].action.play.pitch);
    try std.testing.expectEqual(@as(u7, 127), part.events[0].action.play.velocity);
    try std.testing.expectEqual(@as(u8, 48), part.events[1].action.release);
    try std.testing.expectEqual(@as(u32, 16), part.repeat_ticks.?);
}
