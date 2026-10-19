//! Saves (DESIGN.md 4, PLAN GS-4, SV-1): a level in play, written as one readable record (ZON)
//! and read back. A save holds the session's state: the level, the difficulty, what is carried
//! between levels, the world and the few parts of the level's play that lead to its updates. Art,
//! sound and pictures are not in it; the level is loaded again and the world put back.
//!
//! The world's numbers point into the level's data: a character by its place in the level, its
//! state by its place in its behavior. A save keeps the level's shape (`levelShape`), and a record
//! of another version, or of a level whose shape changed, is refused. Comments, names, rules and
//! the other files of the data set do not change the shape.
const std = @import("std");
const settings = @import("settings.zig");
const content_level = @import("content/level.zig");
const data_set = @import("behavior/data_set.zig");
const world_mod = @import("behavior/world.zig");
const grid = @import("behavior/grid.zig");
const contacts = @import("behavior/contacts.zig");
const palette = @import("content/palette.zig");
const platform = @import("platform.zig");

/// The record's format. Any change to it is a new version, and records of the others are
/// refused.
pub const version = 3;

/// The quick slot (F5, F9) and the eight others, as storage names them.
pub const quick_slot = "QUICK";
pub const slot_count = 8;

/// The storage name of slot `slot`, counted from 0: slot 0 is SAVE1. The slots page shows
/// QUICK on row 0, so its row r is slot r - 1 (`save_slots.slotName`).
pub fn slotName(slot: usize, buffer: *[8]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "SAVE{d}", .{ slot + 1 }) catch unreachable;
}

pub const Record = struct {
    version: u32,
    /// The shape of its level when it was made (`levelShape`), in hexadecimal.
    level_shape: []const u8,
    level: content_level.Id,
    difficulty: settings.Difficulty,
    /// The walks played in the game so far, which its play time counts.
    play_walks: u64,
    /// The flags the characters a level does not place keep from the levels before.
    inherited: []const world_mod.Inherited,
    play_state: PlayState,
    world: World,

    /// The level's play state outside the world that leads to its next updates. A film that a
    /// rule asked for is never waiting in a save: the game does not save then.
    pub const PlayState = struct {
        /// The last direction held without a diagonal, which a diagonal keeps.
        last_direction: u8,
        inventory_delay: u8,
        catch_up_due: bool,
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
    pub const Letter = struct {
        sender: u16,
        message: u16,
        next: ?u16,
    };

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

pub const Error = error{ InvalidSave, OtherVersion, OtherLevelShape, OutOfMemory };

/// What a slot list shows of a save, kept beside it (`infoName`): small, so that a list reads
/// fast.
pub const Info = struct {
    version: u32,
    /// As in the save record.
    level_shape: []const u8,
    level: content_level.Id,
    play_walks: u64,
    /// The local date and time of the save, as the host gave it, or empty.
    date: []const u8,
    /// The picture of the moment, `picture_width` by `picture_height` RGB, in hexadecimal.
    picture: []const u8,
};

pub const picture_width = 64;
pub const picture_height = 56;
pub const Picture = [picture_width * picture_height * 3]u8;

/// The info record of save `slot`. A slot name longer than the storage allows for this name is
/// refused, so that a save is never written without its info record.
pub fn infoName(slot: []const u8, buffer: *[platform.max_name_len]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.INFO", .{ slot }) catch error.InvalidName;
}

/// The game's picture (`width` by `height` palette indices), a quarter of its size each way: each
/// pixel the mean of the 4 by 4 it stands for.
pub fn picture(
    indices: []const u8,
    width: usize,
    colors: *const palette.Palette,
    out: *Picture,
) void {
    for (0..picture_height) |y| {
        for (0..picture_width) |x| {
            var sum: [3]u32 = @splat(0);
            for (0..4) |dy| {
                for (0..4) |dx| {
                    const color = colors[indices[(y * 4 + dy) * width + x * 4 + dx]];
                    sum[0] += color.r;
                    sum[1] += color.g;
                    sum[2] += color.b;
                }
            }
            for (0..3) |c| {
                out[(y * picture_width + x) * 3 + c] = @intCast(sum[c] / 16);
            }
        }
    }
}

pub fn encodeInfo(allocator: std.mem.Allocator, info: Info) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.zon.stringify.serialize(info, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// What a slot holds, as its list shows it.
pub const Slot = union(enum) {
    empty,
    /// A save of another version: shown, not loaded.
    other_version,
    /// A save that does not read.
    broken,
    /// A save, `loadable` unless the shape of its level changed since.
    save: struct {
        level: content_level.Id,
        play_walks: u64,
        date: []const u8,
        picture: ?Picture,
        loadable: bool,
    },
};

/// The slot of info record `bytes` (none: `empty`), its strings in `arena`. `shapes` gives the
/// shape of its level in the data set in use.
pub fn readSlot(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    bytes: ?[]const u8,
    shapes: *LevelShapes,
) !Slot {
    const text = bytes orelse return .empty;
    const source = try arena.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const Versioned = struct {
        version: u32,
    };
    const versioned = std.zon.parse.fromSlice(Versioned, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else .broken;
    if (versioned.version != version) return .other_version;
    const info = std.zon.parse.fromSlice(Info, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else .broken;
    var shown: ?Picture = null;
    if (info.picture.len == @sizeOf(Picture) * 2) {
        var pixels: Picture = undefined;
        if (std.fmt.hexToBytes(&pixels, info.picture)) |_| {
            shown = pixels;
        } else |_| {}
    }
    return .{
        .save = .{
            .level = info.level,
            .play_walks = info.play_walks,
            .date = info.date,
            .picture = shown,
            .loadable = matches(info.level_shape, try shapes.of(gpa, info.level)),
        },
    };
}

/// The shape of a level: what the numbers of a save point into. Its characters in order, each by
/// its original placement, and for each character its behavior's states in order, each by its
/// animation. Names, rules and comments are not in it.
pub fn levelShape(level: *const data_set.Level) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (level.characters) |character| {
        const states = level.behaviors[character.behavior].states;
        hashNumber(&hash, character.placement);
        hashNumber(&hash, @intCast(states.len));
        for (states) |state| {
            hashNumber(&hash, state.animation);
        }
    }
    return hash.final();
}

/// A number hashed little-endian: the same shape on every machine.
fn hashNumber(hash: *std.hash.Wyhash, number: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, number, .little);
    hash.update(&bytes);
}

/// `shape` in the hexadecimal of a record.
pub fn shapeText(shape: u64, buffer: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{ shape }) catch unreachable;
}

/// Whether a record's `level_shape` is `shape`; a level that has none (no data set, or a level
/// that does not load) matches no record.
fn matches(recorded: []const u8, shape: ?u64) bool {
    var buffer: [16]u8 = undefined;
    return std.mem.eql(u8, recorded, shapeText(shape orelse return false, &buffer));
}

/// The shapes of the levels of the data set in use, each worked out from its files when first
/// asked for.
pub const LevelShapes = struct {
    files: ?*const data_set.Files,
    shapes: [level_count]?u64 = @splat(null),

    const level_count = @typeInfo(content_level.Id).@"enum".field_names.len;

    pub fn init(files: ?*const data_set.Files) LevelShapes {
        return .{ .files = files };
    }

    /// The shape of `level`, or null without a data set or when the level does not load.
    pub fn of(self: *LevelShapes, gpa: std.mem.Allocator, level: content_level.Id) !?u64 {
        const known = &self.shapes[@backingInt(level)];
        if (known.*) |shape| return shape;
        const files = self.files orelse return null;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var diagnostic: data_set.Diagnostic = .{};
        const parsed = data_set.loadLevel(
            gpa,
            arena.allocator(),
            files,
            @tagName(level),
            &diagnostic,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return null;
        };
        known.* = levelShape(&parsed);
        return known.*;
    }
};

/// The world as a record; its strings are allocated in `arena`, its lists are the world's own.
pub fn captureWorld(arena: std.mem.Allocator, world: *const world_mod.World) !Record.World {
    const letters = try arena.alloc(Record.Letter, world.letters.len);
    for (letters, world.letters) |*record, letter| {
        record.* = .{
            .sender = letter.sender,
            .message = @backingInt(letter.message),
            .next = letter.next,
        };
    }
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

fn captureTerrain(
    arena: std.mem.Allocator,
    history: *const world_mod.TerrainHistory,
) !Record.Terrain {
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
        record.contacts.slots.len != world.contacts.slots.len) {
        return error.InvalidSave;
    }
    try checkIndices(world, record);
    @memcpy(world.characters, record.characters);
    @memcpy(&world.room_lists, record.room_lists);
    @memcpy(&world.contacts.entries, record.contacts.entries);
    world.contacts.entry_count = record.contacts.entry_count;
    @memcpy(&world.contacts.slots, record.contacts.slots);
    world.contacts.slot_count = record.contacts.slot_count;
    try unhex(&world.contacts.window, record.contacts.window);
    for (&world.letters, record.letters) |*letter, saved| {
        letter.* = .{
            .sender = saved.sender,
            .message = @fromBackingInt(saved.message),
            .next = saved.next,
        };
    }
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
    } else {
        world.checkpoint = null;
    }
}

/// Refuses a record whose values point outside the world: an index past its list, or a state
/// that the character's behavior does not have. The game never writes one; an edited record can,
/// and the engine trusts these values.
fn checkIndices(world: *const world_mod.World, record: Record.World) Error!void {
    const characters = world.characters.len;
    try checkCharacters(world, record.characters);
    for (record.room_lists) |first| {
        try within(first, characters);
    }
    if (record.contacts.entry_count > contacts.capacity) return error.InvalidSave;
    for (record.contacts.entries) |entry| {
        try within(entry.next, contacts.capacity);
        try within(entry.character, characters);
    }
    for (record.contacts.slots) |head| {
        try within(head, contacts.capacity);
    }
    for (record.letters) |letter| {
        try within(letter.sender, characters);
        try within(letter.next, world_mod.letter_capacity);
    }
    try within(record.free_letter, world_mod.letter_capacity);
    for (record.inbox) |first| {
        try within(first, world_mod.letter_capacity);
    }
    if (record.checkpoint) |saved| {
        if (saved.characters.len != characters) return error.InvalidSave;
        try checkCharacters(world, saved.characters);
    }
}

fn checkCharacters(world: *const world_mod.World, saved: []const world_mod.Character) Error!void {
    for (saved, 0..) |character, i| {
        const states = world.behaviorOf(@intCast(i)).states.len;
        if (character.state >= states) return error.InvalidSave;
        try within(character.owner, saved.len);
        try within(character.first_item, saved.len);
        try within(character.next_item, saved.len);
        try within(character.next_in_room, saved.len);
    }
}

fn within(index: ?u16, limit: usize) Error!void {
    if (index) |value| {
        if (value >= limit) return error.InvalidSave;
    }
}

fn restoreTerrain(history: *world_mod.TerrainHistory, record: Record.Terrain) Error!void {
    if (record.changes.len > history.changes.len or record.saved.len % 2 != 0 or
        record.saved.len / 2 > history.saved.len) {
        return error.InvalidSave;
    }
    // What the history keeps true, so that the engine can trust it: each change's saved cells
    // lie in the saved bytes, and every change cost at least 3 words and 1 word for each 2
    // cells saved (`TerrainHistory.add`). The last keeps the next change inside the pools.
    const saved_len = record.saved.len / 2;
    for (record.changes) |change| {
        if (@as(usize, change.saved_from) + change.saved_count > saved_len) {
            return error.InvalidSave;
        }
    }
    if (record.changes.len * 3 > record.used_words or
        saved_len > 2 * @as(usize, record.used_words)) {
        return error.InvalidSave;
    }
    history.* = .{};
    @memcpy(history.changes[0..record.changes.len], record.changes);
    history.change_count = @intCast(record.changes.len);
    history.used_words = record.used_words;
    history.saved_len = @intCast(record.saved.len / 2);
    try unhex(history.saved[0..history.saved_len], record.saved);
}

pub fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
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
/// and its level has the same shape in the data set in use (`shapes`).
pub fn decode(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    bytes: []const u8,
    shapes: *LevelShapes,
) Error!Record {
    const source = try arena.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    // The version first, so that another version's record is told apart from a broken one.
    const Versioned = struct {
        version: u32,
    };
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
    if (!matches(record.level_shape, try shapes.of(gpa, record.level))) {
        return error.OtherLevelShape;
    }
    return record;
}

const synthetic = struct {
    const vocabulary = @import("behavior/vocabulary.zig");
    const animations = @import("content/animations.zig");

    const states = [_]vocabulary.State{.{ .name = "idle", .animation = 0, .rules = &.{} }};
    const behaviors = [_]vocabulary.Behavior{.{
        .name = "test",
        .links = &.{ "friend" },
        .numbers = &.{ "delay" },
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

    fn shape() u64 {
        return levelShape(&level);
    }

    /// The shapes of a data set whose jungle has `jungle`.
    fn shapes(jungle: ?u64) LevelShapes {
        var result: LevelShapes = .init(null);
        result.shapes[@backingInt(content_level.Id.jungle)] = jungle;
        return result;
    }

    /// The world's record as text, which compares the whole of its state.
    fn text(arena: std.mem.Allocator, w: *const world_mod.World) ![]u8 {
        var buffer: [16]u8 = undefined;
        return encode(arena, .{
            .version = version,
            .level_shape = shapeText(shape(), &buffer),
            .level = .jungle,
            .difficulty = .normal,
            .play_walks = 0,
            .inherited = &.{},
            .play_state = .{ .last_direction = 0, .inventory_delay = 0, .catch_up_due = false },
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
    var shapes = synthetic.shapes(synthetic.shape());
    const record = try decode(std.testing.allocator, arena, saved, &shapes);
    var copy = try synthetic.world();
    defer copy.deinit();
    try restoreWorld(&copy, record.world);
    for (0..20) |i| {
        try std.testing.expectEqualStrings(
            try synthetic.text(arena, &original),
            try synthetic.text(arena, &copy),
        );
        const controls: world_mod.Controls = @bitCast(@as(u8, @truncate(i * 37)));
        _ = try original.update(controls, if (i % 5 == 4) .catch_up else .only);
        _ = try copy.update(controls, if (i % 5 == 4) .catch_up else .only);
    }
}

test "a save of another version or level shape, or that does not read, is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w = try synthetic.world();
    defer w.deinit();
    const saved = try synthetic.text(arena, &w);
    var shapes = synthetic.shapes(synthetic.shape());
    var other = synthetic.shapes(synthetic.shape() +% 1);
    try std.testing.expectError(
        error.OtherLevelShape,
        decode(std.testing.allocator, arena, saved, &other),
    );
    // Without a data set, the level has no shape.
    var none = synthetic.shapes(null);
    try std.testing.expectError(
        error.OtherLevelShape,
        decode(std.testing.allocator, arena, saved, &none),
    );
    const other_version = try std.mem.replaceOwned(
        u8,
        arena,
        saved,
        ".version = 3,",
        ".version = 2,",
    );
    try std.testing.expectError(
        error.OtherVersion,
        decode(std.testing.allocator, arena, other_version, &shapes),
    );
    try std.testing.expectError(
        error.InvalidSave,
        decode(std.testing.allocator, arena, saved[0..saved.len / 2], &shapes),
    );
    // A world of another size.
    const record = try decode(std.testing.allocator, arena, saved, &shapes);
    var shorter = record.world;
    shorter.characters = shorter.characters[0..2];
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, shorter));
    // Values that point outside the world.
    const characters = try arena.dupe(world_mod.Character, record.world.characters);
    var edited = record.world;
    edited.characters = characters;
    characters[1].state = 999;
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, edited));
    characters[1] = record.world.characters[1];
    characters[1].next_item = 999;
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, edited));
    characters[1] = record.world.characters[1];
    edited.free_letter = 999;
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, edited));
    edited.free_letter = record.world.free_letter;
    const change: world_mod.TerrainHistory.Change = .{
        .start = 0,
        .width = 2,
        .saved_from = 1700,
        .saved_count = 2,
    };
    edited.terrain = .{ .changes = &.{ change }, .used_words = 4, .saved = "0102" };
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, edited));
    edited.terrain = .{ .changes = &.{}, .used_words = 0, .saved = "0102" };
    try std.testing.expectError(error.InvalidSave, restoreWorld(&w, edited));
    edited.terrain = record.world.terrain;
    try restoreWorld(&w, edited);
}

test "names and rules leave a level's shape; its characters' and states' order changes it" {
    const vocabulary = synthetic.vocabulary;
    const shape = synthetic.shape();
    // Other names, another rule: the same shape.
    const rule: vocabulary.Rule = .{ .turn = true, .forward = 4, .next = 0 };
    const renamed_states = [_]vocabulary.State{.{
        .name = "waiting",
        .animation = 0,
        .rules = &.{ rule },
    }};
    const renamed_behaviors = [_]vocabulary.Behavior{.{
        .name = "guard",
        .links = &.{ "partner" },
        .numbers = &.{ "pause" },
        .states = &renamed_states,
    }};
    var renamed = synthetic.level;
    renamed.behaviors = &renamed_behaviors;
    try std.testing.expectEqual(shape, levelShape(&renamed));
    // A state more, or another animation for a state: another shape.
    const more_states = [_]vocabulary.State{
        .{ .name = "idle", .animation = 0, .rules = &.{} },
        .{ .name = "alert", .animation = 1, .rules = &.{} },
    };
    var more_behaviors = synthetic.behaviors;
    more_behaviors[0].states = &more_states;
    var more = synthetic.level;
    more.behaviors = &more_behaviors;
    try std.testing.expect(levelShape(&more) != shape);
    const other_states = [_]vocabulary.State{.{ .name = "idle", .animation = 1, .rules = &.{} }};
    more_behaviors[0].states = &other_states;
    try std.testing.expect(levelShape(&more) != shape);
    // The characters in another order: another shape.
    var swapped_characters = synthetic.characters;
    std.mem.swap(data_set.Character, &swapped_characters[1], &swapped_characters[2]);
    var swapped = synthetic.level;
    swapped.characters = &swapped_characters;
    try std.testing.expect(levelShape(&swapped) != shape);
}

test "a slot's info reads back; another version is shown, another level shape not loadable" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pixels: Picture = @splat(7);
    const info = try encodeInfo(arena, .{
        .version = version,
        .level_shape = "00000000000000ff",
        .level = .city,
        .play_walks = 3505,
        .date = "2026-10-10 14:32",
        .picture = try hex(arena, &pixels),
    });
    var shapes: LevelShapes = .init(null);
    shapes.shapes[@backingInt(content_level.Id.city)] = 0xff;
    const shown = try readSlot(std.testing.allocator, arena, info, &shapes);
    try std.testing.expect(shown.save.loadable);
    try std.testing.expectEqual(content_level.Id.city, shown.save.level);
    try std.testing.expectEqualStrings("2026-10-10 14:32", shown.save.date);
    try std.testing.expectEqual(pixels, shown.save.picture.?);
    shapes.shapes[@backingInt(content_level.Id.city)] = 1;
    try std.testing.expect(
        !(try readSlot(std.testing.allocator, arena, info, &shapes)).save.loadable,
    );
    // Without a data set, no level has a shape: the save shows, but does not load.
    var none: LevelShapes = .init(null);
    try std.testing.expect(
        !(try readSlot(std.testing.allocator, arena, info, &none)).save.loadable,
    );
    try std.testing.expectEqual(
        Slot.empty,
        try readSlot(std.testing.allocator, arena, null, &none),
    );
    const old = try std.mem.replaceOwned(u8, arena, info, ".version = 3,", ".version = 2,");
    try std.testing.expectEqual(
        Slot.other_version,
        try readSlot(std.testing.allocator, arena, old, &none),
    );
    try std.testing.expectEqual(
        Slot.broken,
        try readSlot(std.testing.allocator, arena, "nonsense", &none),
    );
}

test "a slot name whose info name the storage would refuse is refused before any write" {
    var buffer: [platform.max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("SAVE1.INFO", try infoName("SAVE1", &buffer));
    const longest: [platform.max_name_len - ".INFO".len]u8 = @splat('A');
    try platform.validateName(try infoName(&longest, &buffer));
    const too_long: [longest.len + 1]u8 = @splat('A');
    try std.testing.expectError(error.InvalidName, infoName(&too_long, &buffer));
}

test "the picture is the game's, a quarter of its size, each pixel a 4 by 4 mean" {
    var colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    colors[1] = .{ .r = 160, .g = 80, .b = 40 };
    var indices: [256 * 224]u8 = @splat(0);
    // The top-left 4 by 4: half in color 1.
    for (0..4) |y| {
        for (0..2) |x| {
            indices[y * 256 + x] = 1;
        }
    }
    var out: Picture = undefined;
    picture(&indices, 256, &colors, &out);
    try std.testing.expectEqualSlices(u8, &.{ 80, 40, 20 }, out[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[3..6]);
}
