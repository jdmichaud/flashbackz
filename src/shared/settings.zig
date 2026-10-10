//! The player's settings: one value the game owns and passes to what reads it, kept between runs
//! as one record. A record of another version, or one that does not read, gives the defaults
//! (docs/lessons.md: one save format).
const std = @import("std");
const platform = @import("platform.zig");
const memory = @import("memory.zig");

pub const Difficulty = enum { easy, normal, expert };

pub const Zoom = enum { off, on, auto };

pub const Settings = struct {
    /// The master volume, in percent.
    volume: u8 = 100,
    sound_fx: bool = true,
    music: bool = true,
    /// The original's Joystick option: the pads drive Conrad.
    joystick: bool = false,
    /// The zoom view (flashback-re engine-presentation 4.3). Only the automatic zoom lasts
    /// beyond a level: a permanent zoom does not survive a new game or a continue.
    zoom: Zoom = .off,
};

pub const record_name = "SETTINGS";

/// The record's format. Any change to it is a new version, and records of the others are
/// refused.
const version = 1;

/// The record as written: its version, then every setting, none left out.
const Record = struct {
    version: u32,
    volume: u8,
    sound_fx: bool,
    music: bool,
    joystick: bool,
    zoom: Zoom,
};

const max_record = 256;

/// The settings kept in `storage`, or the defaults.
pub fn load(storage: ?platform.Storage) Settings {
    const source = storage orelse return .{};
    var record = source.load(record_name) catch return .{};
    defer record.deinit();
    return decode(record.bytes) orelse .{};
}

pub fn save(storage: ?platform.Storage, settings: Settings) platform.StorageError!void {
    const destination = storage orelse return;
    var buffer: [max_record]u8 = undefined;
    try destination.save(record_name, encode(settings, &buffer));
}

fn encode(settings: Settings, buffer: *[max_record]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const record: Record = .{
        .version = version,
        .volume = settings.volume,
        .sound_fx = settings.sound_fx,
        .music = settings.music,
        .joystick = settings.joystick,
        .zoom = settings.zoom,
    };
    std.zon.stringify.serialize(record, .{}, &writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return writer.buffered();
}

fn decode(bytes: []const u8) ?Settings {
    var source: [max_record:0]u8 = undefined;
    if (bytes.len > max_record) return null;
    @memcpy(source[0..bytes.len], bytes);
    source[bytes.len] = 0;
    var scratch: [4096]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&scratch);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const record = std.zon.parse.fromSliceNoAlloc(Record, .{
        .gpa = allocator.allocator(),
        .arena = allocator.allocator(),
        .source = source[0..bytes.len :0],
        .diagnostics = &diagnostics,
    }) catch return null;
    if (record.version != version or record.volume > 100) return null;
    return .{
        .volume = record.volume,
        .sound_fx = record.sound_fx,
        .music = record.music,
        .joystick = record.joystick,
        .zoom = record.zoom,
    };
}

test "settings come back as saved, and a record of another version or that does not read gives the defaults" {
    var store = memory.MemoryStorage.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(Settings{}, load(store.storage()));
    try std.testing.expectEqual(Settings{}, load(null));
    const chosen: Settings = .{ .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto };
    try save(store.storage(), chosen);
    try std.testing.expectEqual(chosen, load(store.storage()));

    const refused = [_][]const u8{
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto }",
        ".{ .version = 1, .volume = 140, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto }",
        ".{ .version = 1, .volume = 40, .sound_fx = false, .music = false, .zoom = .auto }",
        ".{ .version = 1, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .extra = 1 }",
        "50\n",
        "",
    };
    for (refused) |record| {
        try store.storage().save(record_name, record);
        try std.testing.expectEqual(Settings{}, load(store.storage()));
    }
}
