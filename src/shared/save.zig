//! Saves (DESIGN.md 4, PLAN GS-4): a level in play, written as one readable record (ZON) and read
//! back. A save holds the session's state: the level, the difficulty, what is carried between
//! levels, the world and the few parts of the level's play that lead to its updates. Art, sound
//! and pictures are not in it; the level is loaded again and the world put back. A record of
//! another version, or made with another data set, is refused.
const std = @import("std");
const settings = @import("settings.zig");
const content_level = @import("content/level.zig");
const data_set = @import("behavior/data_set.zig");
const world_mod = @import("behavior/world.zig");
const grid = @import("behavior/grid.zig");
const contacts = @import("behavior/contacts.zig");

/// The record's format. Any change to it is a new version, and records of the others are
/// refused.
pub const version = 1;

/// The quick slot (F5, F9) and the eight others, as storage names them.
pub const quick_slot = "QUICK";
pub const slot_count = 8;

pub fn slotName(slot: usize, buffer: *[8]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "SAVE{d}", .{slot + 1}) catch unreachable;
}

pub const Record = struct {
    version: u32,
    /// The data set it was made with: `fingerprint`, in hexadecimal.
    data_set: []const u8,
    level: content_level.Id,
    difficulty: settings.Difficulty,
    /// The flags the characters a level does not place keep from the levels before.
    inherited: []const world_mod.Inherited,
    scene: Scene,
    world: World,

    /// The level's play state outside the world that leads to its next updates.
    pub const Scene = struct {
        /// The last direction held without a diagonal, which a diagonal keeps.
        last_direction: u8,
        inventory_delay: u8,
        catch_up_due: bool,
        requested_scene: ?i16,
    };

    pub const World = struct {
        characters: []const world_mod.Character,
        room_lists: []const ?u16,
        contacts: Contacts,
        letters: []const Letter,
        free_letter: ?u16,
        inbox: []const ?u16,
        random: u32,
        controls: u8,
        view_room: u8,
        view_dirty: bool,
        room_loads: u32,
        checkpoint_saves: u32,
        score: u32,
        entry_score: u32,
        protection: u8,
        hurt: bool,
        defeat_countdown: i16,
        defeat_scene: i16,
        weapon_mode: i16,
        shake: i8,
        /// The collision grid with its terrain changes, in hexadecimal.
        grid: []const u8,
        terrain: Terrain,
        checkpoint: ?Checkpoint,
    };

    pub const Contacts = struct {
        entries: []const contacts.Entry,
        entry_count: u16,
        slots: []const ?u16,
        slot_count: u8,
        /// In hexadecimal.
        window: []const u8,
    };

    /// A message in the pool; its message by number, as the data set's are not all named.
    pub const Letter = struct { sender: u16, message: u16, next: ?u16 };

    pub const Terrain = struct {
        changes: []const world_mod.TerrainHistory.Change,
        used_words: u16,
        /// The cells the changes replaced, in hexadecimal.
        saved: []const u8,
    };

    pub const Checkpoint = struct {
        characters: []const world_mod.Character,
        score: u32,
        grid: []const u8,
        terrain: Terrain,
    };
};

pub const Error = error{ InvalidSave, OtherVersion, OtherDataSet, OutOfMemory };

/// The data set's fingerprint: its files, in name order, hashed.
pub fn fingerprint(files: *const data_set.Files) u64 {
    var names_buffer: [1024][]const u8 = undefined;
    const count = @min(files.count(), names_buffer.len);
    const names = names_buffer[0..count];
    @memcpy(names, files.keys()[0..count]);
    std.sort.pdq([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var hash = std.hash.Wyhash.init(0);
    for (names) |name| {
        hash.update(name);
        hash.update(&.{0});
        hash.update(files.get(name).?);
        hash.update(&.{0});
    }
    return hash.final();
}

/// The world as a record; its strings are allocated in `arena`, its lists are the world's own.
pub fn captureWorld(arena: std.mem.Allocator, world: *const world_mod.World) !Record.World {
    const letters = try arena.alloc(Record.Letter, world.letters.len);
    for (letters, world.letters) |*record, letter| record.* = .{
        .sender = letter.sender,
        .message = @backingInt(letter.message),
        .next = letter.next,
    };
    return .{
        .characters = world.characters,
        .room_lists = &world.room_lists,
        .contacts = .{
            .entries = &world.contacts.entries,
            .entry_count = world.contacts.entry_count,
            .slots = &world.contacts.slots,
            .slot_count = world.contacts.slot_count,
            .window = try hex(arena, &world.contacts.window),
        },
        .letters = letters,
        .free_letter = world.free_letter,
        .inbox = world.inbox,
        .random = world.random.state,
        .controls = @bitCast(world.controls),
        .view_room = world.view_room,
        .view_dirty = world.view_dirty,
        .room_loads = world.room_loads,
        .checkpoint_saves = world.checkpoint_saves,
        .score = world.score,
        .entry_score = world.entry_score,
        .protection = world.protection,
        .hurt = world.hurt,
        .defeat_countdown = world.defeat_countdown,
        .defeat_scene = world.defeat_scene,
        .weapon_mode = world.weapon_mode,
        .shake = world.shake,
        .grid = try hex(arena, &world.grid.bytes),
        .terrain = try captureTerrain(arena, &world.terrain_history),
        .checkpoint = if (world.checkpoint) |*checkpoint| .{
            .characters = checkpoint.characters[0..world.characters.len],
            .score = checkpoint.score,
            .grid = try hex(arena, &checkpoint.grid.bytes),
            .terrain = try captureTerrain(arena, &checkpoint.terrain_history),
        } else null,
    };
}

fn captureTerrain(arena: std.mem.Allocator, history: *const world_mod.TerrainHistory) !Record.Terrain {
    return .{
        .changes = history.changes[0..history.change_count],
        .used_words = history.used_words,
        .saved = try hex(arena, history.saved[0..history.saved_len]),
    };
}

/// Puts the world back as `record` has it. The world must be the record's level, loaded again
/// at its difficulty.
pub fn restoreWorld(world: *world_mod.World, record: Record.World) Error!void {
    if (record.characters.len != world.characters.len or record.inbox.len != world.inbox.len or
        record.room_lists.len != world.room_lists.len or record.letters.len != world.letters.len or
        record.contacts.entries.len != world.contacts.entries.len or
        record.contacts.slots.len != world.contacts.slots.len) return error.InvalidSave;
    @memcpy(world.characters, record.characters);
    @memcpy(&world.room_lists, record.room_lists);
    @memcpy(&world.contacts.entries, record.contacts.entries);
    world.contacts.entry_count = record.contacts.entry_count;
    @memcpy(&world.contacts.slots, record.contacts.slots);
    world.contacts.slot_count = record.contacts.slot_count;
    try unhex(&world.contacts.window, record.contacts.window);
    for (&world.letters, record.letters) |*letter, saved| letter.* = .{
        .sender = saved.sender,
        .message = @fromBackingInt(saved.message),
        .next = saved.next,
    };
    world.free_letter = record.free_letter;
    @memcpy(world.inbox, record.inbox);
    world.random.state = record.random;
    world.controls = @bitCast(record.controls);
    world.view_room = record.view_room;
    world.view_dirty = record.view_dirty;
    world.room_loads = record.room_loads;
    world.checkpoint_saves = record.checkpoint_saves;
    world.score = record.score;
    world.entry_score = record.entry_score;
    world.protection = record.protection;
    world.hurt = record.hurt;
    world.defeat_countdown = record.defeat_countdown;
    world.defeat_scene = record.defeat_scene;
    world.weapon_mode = record.weapon_mode;
    world.shake = record.shake;
    try unhex(&world.grid.bytes, record.grid);
    try restoreTerrain(&world.terrain_history, record.terrain);
    if (record.checkpoint) |saved| {
        if (saved.characters.len != world.characters.len) return error.InvalidSave;
        var checkpoint: world_mod.Checkpoint = undefined;
        @memcpy(checkpoint.characters[0..saved.characters.len], saved.characters);
        checkpoint.score = saved.score;
        try unhex(&checkpoint.grid.bytes, saved.grid);
        checkpoint.terrain_history = .{};
        try restoreTerrain(&checkpoint.terrain_history, saved.terrain);
        world.checkpoint = checkpoint;
    } else world.checkpoint = null;
}

fn restoreTerrain(history: *world_mod.TerrainHistory, record: Record.Terrain) Error!void {
    if (record.changes.len > history.changes.len or record.saved.len % 2 != 0 or
        record.saved.len / 2 > history.saved.len) return error.InvalidSave;
    history.* = .{};
    @memcpy(history.changes[0..record.changes.len], record.changes);
    history.change_count = @intCast(record.changes.len);
    history.used_words = record.used_words;
    history.saved_len = @intCast(record.saved.len / 2);
    try unhex(history.saved[0..history.saved_len], record.saved);
}

fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const text = try arena.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        text[2 * i] = digits[byte >> 4];
        text[2 * i + 1] = digits[byte & 15];
    }
    return text;
}

fn unhex(bytes: []u8, text: []const u8) Error!void {
    if (text.len != bytes.len * 2) return error.InvalidSave;
    _ = std.fmt.hexToBytes(bytes, text) catch return error.InvalidSave;
}

/// The record as text.
pub fn encode(allocator: std.mem.Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.zon.stringify.serialize(record, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// The record in `bytes`, its lists and strings allocated in `arena`, if it is of this version
/// and made with the data set of fingerprint `data_set_print`.
pub fn decode(gpa: std.mem.Allocator, arena: std.mem.Allocator, bytes: []const u8, data_set_print: u64) Error!Record {
    const source = try arena.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    // The version first, so that another version's record is told apart from a broken one.
    const Versioned = struct { version: u32 };
    const versioned = std.zon.parse.fromSlice(Versioned, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSave;
    if (versioned.version != version) return error.OtherVersion;
    const record = std.zon.parse.fromSlice(Record, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidSave;
    var print_text: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&print_text, "{x:0>16}", .{data_set_print}) catch unreachable;
    if (!std.mem.eql(u8, record.data_set, &print_text)) return error.OtherDataSet;
    return record;
}

const synthetic = struct {
    const vocabulary = @import("behavior/vocabulary.zig");
    const animations = @import("behavior/animations.zig");

    const states = [_]vocabulary.State{.{ .name = "idle", .animation = 0, .rules = &.{} }};
    const behaviors = [_]vocabulary.Behavior{.{
        .name = "test",
        .links = &.{"friend"},
        .numbers = &.{"delay"},
        .states = &states,
    }};
    fn character(placement: u16, kind: vocabulary.Kind, room: u8) data_set.Character {
        return .{
            .name = "c",
            .placement = placement,
            .kind = kind,
            .behavior = 0,
            .start = 0,
            .room = room,
            .x = 112,
            .y = 214,
            .facing = .right,
            .health = 2,
            .width = 1,
            .active = true,
            .minimum_difficulty = .easy,
            .links = .{ @fromBackingInt(0), null, null, null },
            .numbers = .{ 30, 0, 0, 0 },
        };
    }
    const characters = [_]data_set.Character{
        character(0, .player, 0),
        character(1, .enemy, 0),
        character(2, .interactive, 1),
    };
    const level: data_set.Level = .{
        .behaviors = &behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    const animation_bytes = [_]u8{ 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    fn world() !world_mod.World {
        var layout: [grid.Grid.layout_size]u8 = @splat(0);
        @memset(layout[0..256], 0xff);
        layout[192] = 1;
        return world_mod.World.init(
            std.testing.allocator,
            &level,
            try animations.Animations.init(&animation_bytes),
            try grid.Grid.init(&layout),
            .{},
        );
    }

    /// The world's record as text, which compares the whole of its state.
    fn text(arena: std.mem.Allocator, w: *const world_mod.World) ![]u8 {
        return encode(arena, .{
            .version = version,
            .data_set = "0000000000000000",
            .level = .jungle,
            .difficulty = .normal,
            .inherited = &.{},
            .scene = .{ .last_direction = 0, .inventory_delay = 0, .catch_up_due = false, .requested_scene = null },
            .world = try captureWorld(arena, w),
        });
    }
};

test "a world saved and read back is the same world, and goes on the same" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var original = try synthetic.world();
    defer original.deinit();
    // What a level changes: positions, health, the score, the random state, a message waiting,
    // a terrain change and a checkpoint.
    original.characters[1].x = 80;
    original.characters[1].health = 1;
    original.score = 1234;
    original.random.state = 0xdeadbeef;
    original.send(1, 0, @fromBackingInt(300));
    const replaced = original.terrain_history.add(256 + 5 * 16 + 3, 2);
    replaced[0] = 7;
    replaced[1] = 9;
    original.grid.bytes[256 + 5 * 16 + 3] = 1;
    var checkpoint: world_mod.Checkpoint = undefined;
    @memcpy(checkpoint.characters[0..original.characters.len], original.characters);
    checkpoint.score = 1000;
    checkpoint.grid = original.grid;
    checkpoint.terrain_history = original.terrain_history;
    original.checkpoint = checkpoint;
    _ = try original.update(.{ .right = true }, .only);

    const saved = try synthetic.text(arena, &original);
    const record = try decode(std.testing.allocator, arena, saved, 0);
    var copy = try synthetic.world();
    defer copy.deinit();
    try restoreWorld(&copy, record.world);
    for (0..20) |i| {
        try std.testing.expectEqualStrings(try synthetic.text(arena, &original), try synthetic.text(arena, &copy));
        const controls: world_mod.Controls = @bitCast(@as(u8, @truncate(i * 37)));
        _ = try original.update(controls, if (i % 5 == 4) .catch_up else .only);
        _ = try copy.update(controls, if (i % 5 == 4) .catch_up else .only);
    }
}

test "a save of another version or data set, or that does not read, is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try synthetic.world();
    defer w.deinit();
    const saved = try synthetic.text(arena, &w);
    try std.testing.expectError(error.OtherDataSet, decode(std.testing.allocator, arena, saved, 1));
    const other_version = try std.mem.replaceOwned(u8, arena, saved, ".version = 1,", ".version = 2,");
    try std.testing.expectError(error.OtherVersion, decode(std.testing.allocator, arena, other_version, 0));
    try std.testing.expectError(error.InvalidSave, decode(std.testing.allocator, arena, saved[0 .. saved.len / 2], 0));
    // A world of another size.
    const record = try decode(std.testing.allocator, arena, saved, 0);
    var shorter = record.world;
    shorter.characters = shorter.characters[0..2];
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, shorter));
}
