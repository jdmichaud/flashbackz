//! Inventory, lifts and riders, transport, and changes to the terrain.
//!
//! Items and riders share one structure: a character's `first_item` is its selected item (or
//! first rider), `next_item` links the items of one owner, and `owner` names the carrier. New
//! items and riders join at the end. A carried item is out of every room (room 0xff).
//! Semantics: flashback-re `docs/rules/` (codes 48-50, 54, 55, 78, 104, 105, 110, 113-115,
//! 127-131, 136).
const std = @import("std");
const vocabulary = @import("../vocabulary.zig");
const world_module = @import("../world.zig");
const grid = @import("../grid.zig");
const contacts = @import("../contacts.zig");
const original_memory = @import("../original_memory.zig");
const World = world_module.World;
const Room = world_module.Room;

// Inventory -------------------------------------------------------------------------------

/// Becomes the last item `owner` carries, leaving any previous owner, and leaves the rooms at
/// once. The room lists only follow when the rule fires. Always true.
pub fn carriedBy(world: *World, actor: u16, owner: vocabulary.Character) !bool {
    attach(world, @backingInt(owner), actor);
    world.characters[actor].room = Room.carried;
    return true;
}

/// Takes the position, room and facing of `place` and leaves its owner's inventory, if it is
/// in it. Also places shots at their shooter. Always true.
pub fn dropAt(world: *World, actor: u16, place: vocabulary.Character) !bool {
    const at = world.characters[@backingInt(place)];
    const item = &world.characters[actor];
    item.x = at.x;
    item.y = at.y;
    item.room = at.room;
    item.facing_right = at.facing_right;
    detach(world, actor);
    return true;
}

/// Conrad's selected item, whoever asks, is that object.
pub fn selectedItemIs(world: *World, _: u16, object: i16) !bool {
    const item = world.characters[0].first_item orelse return false;
    return world.level.characters[item].object == lowByte(object);
}

/// Conrad carries that object, whoever asks.
pub fn playerHasItem(world: *World, _: u16, object: i16) !bool {
    var cursor = world.characters[0].first_item;
    while (cursor) |item| : (cursor = world.characters[item].next_item) {
        if (world.level.characters[item].object == lowByte(object)) return true;
    }
    return false;
}

// Lifts and riders --------------------------------------------------------------------------

/// Moves the character and its direct riders (not theirs) vertically. Always true.
pub fn moveWithRiders(world: *World, actor: u16, dy: i16) !bool {
    world.characters[actor].y +%= dy;
    var cursor = world.characters[actor].first_item;
    while (cursor) |rider| : (cursor = world.characters[rider].next_item) {
        world.characters[rider].y +%= dy;
    }
    return true;
}

/// Becomes the last rider of the sender of the newest waiting message with that value.
pub fn boardSender(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var letters = world.mailbox(actor);
    while (letters.nextLetter()) |letter| if (letter.message == message) {
        attach(world, letter.sender, actor);
        return true;
    };
    return false;
}

/// When a message with that value waits, stops riding (if riding at all) and holds.
pub fn releaseOn(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var letters = world.mailbox(actor);
    while (letters.nextLetter()) |letter| if (letter.message == message) {
        detach(world, actor);
        return true;
    };
    return false;
}

/// Rides the first other character of that kind in its own first cell.
pub fn boardTouching(world: *World, actor: u16, kind: vocabulary.Kind) !bool {
    const carrier = firstTouching(world, actor, kind) orelse return false;
    if (!original_memory.findsCarrier(carrier)) return false;
    attach(world, carrier, actor);
    return true;
}

/// No item (kind 3) sharing one of the character's cells is anything but its own rider.
pub fn noLooseCargo(world: *World, actor: u16, _: void) !bool {
    var slot = world.characters[actor].contact;
    while (slot != contacts.no_slot) {
        // An empty slot ends the check, even with further cells to go.
        if (world.contacts.slots[slot] == null) return true;
        const current = slot;
        var occupants = world.contacts.occupants(slot);
        while (occupants.nextEntry()) |entry| {
            if (entry.character == actor) {
                slot = entry.next_slot orelse contacts.no_slot;
                continue;
            }
            const kind = world.level.characters[entry.character].kind;
            if (kind == .interactive and world.characters[entry.character].owner != actor) {
                return false;
            }
        }
        // The original scans a slot without the character forever; this check gives up.
        if (slot == current) return true;
    }
    return true;
}

/// Takes the carrier's x, if riding. Always true.
pub fn alignWithCarrier(world: *World, actor: u16, _: void) !bool {
    const carrier = world.characters[actor].owner orelse return true;
    world.characters[actor].x = world.characters[carrier].x;
    return true;
}

/// With r the carrier's x modulo 256 (keeping its sign): takes r when r is at or past its
/// own x, else adds r. After `align_with_carrier` this changes nothing. Always true.
pub fn followCarrierX(world: *World, actor: u16, _: void) !bool {
    const carrier = world.characters[actor].owner orelse return true;
    const r = @rem(world.characters[carrier].x, 256);
    const rider = &world.characters[actor];
    if (r >= rider.x) rider.x = r else rider.x +%= r;
    return true;
}

/// Makes `item` the last of `owner`'s items or riders, leaving any previous owner first.
fn attach(world: *World, owner: u16, item: u16) void {
    detach(world, item);
    const characters = world.characters;
    var last: ?u16 = null;
    var cursor = characters[owner].first_item;
    while (cursor) |current| : (cursor = characters[current].next_item) last = current;
    characters[item].owner = owner;
    characters[item].next_item = null;
    if (last) |tail| characters[tail].next_item = item else characters[owner].first_item = item;
}

/// Leaves the owner's list, if the character is in it.
fn detach(world: *World, item: u16) void {
    const owner = world.characters[item].owner orelse return;
    world.unlinkItem(owner, item);
}

/// The first other character of `kind` in the character's first cell, newest registration
/// first, active or not. The original indexes its slot table with a byte, so slots from 128
/// on read slot - 128.
fn firstTouching(world: *World, actor: u16, kind: vocabulary.Kind) ?u16 {
    const slot = world.characters[actor].contact;
    if (slot == contacts.no_slot) return null;
    var occupants = world.contacts.occupants(slot & 0x7f);
    while (occupants.nextEntry()) |entry| {
        if (entry.character == actor) continue;
        const other = world.level.characters[entry.character].kind;
        if (kind == .any or kindByte(other) == kindByte(kind)) return entry.character;
    }
    return null;
}

fn kindByte(kind: vocabulary.Kind) u8 {
    return lowByte(@backingInt(kind));
}

fn lowByte(value: i16) u8 {
    return @truncate(@as(u16, @bitCast(value)));
}

// Transport ---------------------------------------------------------------------------------

/// Moves the character `move` names to the position and room of the template `to` names,
/// if that is a real room. A character sharing the template's behavior also takes its
/// state and facing. Moving Conrad shows his new room at once. Carrier links, riders,
/// health and messages stay. Always true. (The original's copy protection, run when Conrad
/// is moved, is left out.)
pub fn transport(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "transport"),
) !bool {
    const moved = world.link(actor, argument.move) orelse return true;
    const template = world.link(actor, argument.to) orelse return true;
    const to = world.characters[template];
    if (to.room >= 64) return true;
    const character = &world.characters[moved];
    const from_room = character.room;
    character.x = to.x;
    character.y = to.y;
    character.room = to.room;
    if (to.room != from_room) world.moveBetweenRooms(moved, from_room, to.room);
    const definition = world.level.characters[moved];
    if (definition.behavior == world.level.characters[template].behavior) {
        character.facing_right = to.facing_right;
        character.state = to.state;
        character.cursor = 0;
    }
    // Only the view changes: no room wakes, and the contact window waits for the next update.
    if (definition.kind == .player) {
        world.view_room = character.room;
        world.room_loads +%= 1;
    }
    world.showFrame(moved) catch return error.InvalidAnimation;
    return true;
}

// Terrain -----------------------------------------------------------------------------------

/// Fills the character's width of cells on `row` of its tier (1 body, 2 floor) with solid
/// terrain, remembering what was there. Always true.
pub fn makeSolid(world: *World, actor: u16, row: i16) !bool {
    changeTerrain(world, actor, row, 1);
    return true;
}

/// Clears those cells, remembering what was there. Always true.
pub fn makeEmpty(world: *World, actor: u16, row: i16) !bool {
    changeTerrain(world, actor, row, 0);
    return true;
}

/// Marks those cells as a low passage (material 2), remembering what was there. Always true.
pub fn makeLowPassage(world: *World, actor: u16, row: i16) !bool {
    changeTerrain(world, actor, row, 2);
    return true;
}

/// Puts back the cells first replaced by the newest change starting at the character's
/// column on `row`. Unlike the writers it ignores the facing, so it misses a change made
/// facing right by a character wider than one cell. The original returns the cell's memory
/// address, or with no history at all the cell's offset in its room; rules test only the low
/// byte, so the check is false at some positions.
pub fn restoreTerrain(world: *World, actor: u16, row: i16) !bool {
    const character = world.characters[actor];
    const offset = spanOffset(character, row);
    const start = original_memory.roomCell(character.room, offset);
    const history = &world.terrain_history;
    if (history.change_count == 0) return lowByte(offset) != 0;
    // The original gives up after 256 changes; the pool never holds that many.
    if (history.find(start, false)) |change| {
        const saved = history.savedCells(change.*);
        for (0..change.width) |k| {
            const cell = original_memory.gridByte(world, start + @as(i32, @intCast(k))) orelse continue;
            // A later write at this start made the change wider than what was saved; the
            // original then copies unrelated memory.
            if (k < saved.len) cell.* = saved[k] else world.unmodeled_reads += 1;
        }
    }
    return original_memory.addressLowByte(start) != 0;
}

/// The writer behind `make_solid`, `make_empty` and `make_low_passage`. Characters outside
/// the 64 rooms change nothing. The span runs from the character's column toward its back,
/// with the facing it had at the start of its update, and continues into the next row or
/// room. A start already in the history is refilled without saving again; a new start is
/// saved only while the history has room, and otherwise nothing is written.
fn changeTerrain(world: *World, actor: u16, row: i16, material: u8) void {
    const character = world.characters[actor];
    if (character.room >= 64) return;
    const width = world.level.characters[actor].width;
    const facing_right = world.updating_facing_right;
    const behind: i32 = if (facing_right) @as(i32, width) - 1 else 0;
    const start = original_memory.roomCell(character.room, spanOffset(character, row)) - behind;
    const history = &world.terrain_history;
    // The original's search ends after the newest change for a writer one cell wide facing
    // right, so such a writer can save a start a second time.
    if (history.find(start, facing_right and width == 1)) |change| {
        change.width = width;
        for (0..width) |k| {
            if (original_memory.gridByte(world, start + @as(i32, @intCast(k)))) |cell| cell.* = material;
        }
        return;
    }
    if (!history.admitsMore()) return;
    for (history.add(start, width), 0..) |*saved, k| {
        const cell = original_memory.gridByte(world, start + @as(i32, @intCast(k))) orelse {
            saved.* = 0;
            continue;
        };
        saved.* = cell.*;
        cell.* = material;
    }
}

/// The offset in its room of the cell `row` rows below the top of the character's tier, in
/// its column, as the terrain writers compute it: from the character's current position,
/// with y read as unsigned (a negative y gives a row far below the room).
fn spanOffset(character: world_module.Character, row: i16) i16 {
    const tier: i16 = @intCast((@as(u16, @bitCast(character.y)) / 36) & 0xfffe);
    return (tier +% row) *% grid.Grid.columns +% grid.columnOf(character.x);
}

/// Remembers where a continue resumes: every character, the score, the grid and the terrain
/// history (`world_module.Checkpoint`). The original writes this to a file and shows a
/// notice on success; here the save cannot fail. Always true.
pub fn checkpoint(world: *World, _: u16, _: void) !bool {
    // The loader holds a level to `data_set.max_characters`.
    world.checkpoint = @as(world_module.Checkpoint, undefined);
    const saved = &world.checkpoint.?;
    @memcpy(saved.characters[0..world.characters.len], world.characters);
    saved.score = world.score;
    saved.grid = world.grid;
    saved.terrain_history = world.terrain_history;
    world.checkpoint_saves +%= 1;
    return true;
}

// Positioning -------------------------------------------------------------------------------

/// Floors x to a multiple of 16 and puts y on the floor line of its 72-pixel tier
/// (70, 142 or 214 inside a room). Always true.
pub fn snapToGrid(world: *World, actor: u16, _: void) !bool {
    const character = &world.characters[actor];
    character.x &= ~@as(i16, 15);
    character.y = (@divTrunc(character.y, 72) + 1) *% 72 -% 2;
    return true;
}

// Tests ----------------------------------------------------------------------------------------

const testing = struct {
    const data_set = @import("../data_set.zig");
    const animations = @import("../../content/animations.zig");

    // State 0 plays a one-frame animation, state 1 a three-frame one.
    const states = [_]vocabulary.State{
        .{ .name = "still", .animation = 0, .rules = &.{} },
        .{ .name = "moving", .animation = 1, .rules = &.{} },
    };
    const behaviors = [_]vocabulary.Behavior{
        .{ .name = "a", .links = &.{ "move", "to" }, .numbers = &.{}, .states = &states },
        .{ .name = "b", .links = &.{ "move", "to" }, .numbers = &.{}, .states = &states },
    };
    const animation_bytes = [_]u8{ 2, 0, 4, 0, 14, 0 } ++
        [_]u8{ 1, 0, 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 0, 0 } ++
        [_]u8{ 3, 0, 0, 0, 0, 0 } ++ @as([12]u8, @splat(0));

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
            .facing = .left,
            .health = 1,
            .width = 1,
            .active = true,
            .minimum_difficulty = .easy,
        };
    }

    /// Rooms 0 and 1 side by side, no other links; every cell empty.
    fn world(level: *const data_set.Level) !World {
        var layout: [grid.Grid.layout_size]u8 = @splat(0);
        @memset(layout[0..256], 0xff);
        layout[128 + 0] = 1;
        layout[192 + 1] = 0;
        return World.init(
            std.testing.allocator,
            level,
            try animations.Animations.init(&animation_bytes),
            try grid.Grid.init(&layout),
            .{},
        );
    }

    /// Registers the characters' cells as the update does before the walk.
    fn register(w: *World, indices: []const u16) !void {
        var shared: std.ArrayList(u16) = .empty;
        defer shared.deinit(std.testing.allocator);
        w.contacts.begin();
        for (indices) |i| {
            const c = w.characters[i];
            const first = try w.contacts.register(
                &w.grid,
                i,
                c.room,
                c.x,
                c.y,
                w.level.characters[i].width,
                &shared,
                std.testing.allocator,
            );
            w.characters[i].contact = first orelse contacts.no_slot;
        }
    }

    fn items(w: *const World, owner: u16, buffer: []u16) []u16 {
        var n: usize = 0;
        var cursor = w.characters[owner].first_item;
        while (cursor) |item| : (cursor = w.characters[item].next_item) {
            buffer[n] = item;
            n += 1;
        }
        return buffer[0..n];
    }

    fn characterAt(index: u16) vocabulary.Character {
        return @fromBackingInt(index);
    }

    fn cell(w: *const World, room: u8, row: u8, column: u8) u8 {
        return w.grid.bytes[256 + @as(usize, room) * 112 + @as(usize, row) * 16 + column];
    }
};

test "items join the end of the inventory, are selected from the front and dropped" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 1),
        testing.character(2, .interactive, 1),
        testing.character(3, .enemy, 1),
    };
    characters[1].object = 2;
    characters[2].object = 7;
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    var buffer: [4]u16 = undefined;

    try std.testing.expect(try carriedBy(&w, 1, testing.characterAt(0)));
    try std.testing.expect(try carriedBy(&w, 2, testing.characterAt(0)));
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, testing.items(&w, 0, &buffer));
    try std.testing.expectEqual(Room.carried, w.characters[1].room);
    try std.testing.expectEqual(@as(?u16, 0), w.characters[2].owner);
    try std.testing.expect(try selectedItemIs(&w, 3, 2));
    try std.testing.expect(!try selectedItemIs(&w, 3, 7));
    try std.testing.expect(try playerHasItem(&w, 3, 7));
    try std.testing.expect(!try playerHasItem(&w, 3, 5));
    // Taking an item again moves it to the end.
    try std.testing.expect(try carriedBy(&w, 1, testing.characterAt(0)));
    try std.testing.expectEqualSlices(u16, &.{ 2, 1 }, testing.items(&w, 0, &buffer));
    try std.testing.expect(try selectedItemIs(&w, 3, 7));

    w.characters[3].x = 50;
    w.characters[3].y = 70;
    w.characters[3].facing_right = true;
    try std.testing.expect(try dropAt(&w, 2, testing.characterAt(3)));
    try std.testing.expectEqualSlices(u16, &.{1}, testing.items(&w, 0, &buffer));
    try std.testing.expectEqual(@as(?u16, null), w.characters[2].owner);
    try std.testing.expectEqual(@as(?u16, null), w.characters[2].next_item);
    try std.testing.expectEqual(@as(i16, 50), w.characters[2].x);
    try std.testing.expectEqual(@as(i16, 70), w.characters[2].y);
    try std.testing.expectEqual(@as(u8, 1), w.characters[2].room);
    try std.testing.expect(w.characters[2].facing_right);
    // An item nobody carries is only moved.
    try std.testing.expect(try dropAt(&w, 2, testing.characterAt(0)));
    try std.testing.expectEqualSlices(u16, &.{1}, testing.items(&w, 0, &buffer));
}

test "riders board the sender, move with their carrier and leave on a message" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 0),
        testing.character(2, .interactive, 0),
    };
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    var buffer: [4]u16 = undefined;
    const go: vocabulary.Message = @fromBackingInt(130);

    try std.testing.expect(!try boardSender(&w, 0, .acknowledged));
    w.send(1, 0, .acknowledged);
    w.send(2, 0, .acknowledged);
    // The newest message's sender carries.
    try std.testing.expect(try boardSender(&w, 0, .acknowledged));
    try std.testing.expectEqual(@as(?u16, 2), w.characters[0].owner);
    w.send(1, 2, .acknowledged);
    try std.testing.expect(try boardSender(&w, 2, .acknowledged));
    // Conrad leaves carrier 2 for carrier 1 and rides behind character 2.
    const call: vocabulary.Message = @fromBackingInt(21);
    w.send(1, 0, call);
    try std.testing.expect(try boardSender(&w, 0, call));
    try std.testing.expectEqualSlices(u16, &.{ 2, 0 }, testing.items(&w, 1, &buffer));
    try std.testing.expectEqual(@as(?u16, null), w.characters[2].first_item);

    try std.testing.expect(try moveWithRiders(&w, 1, -2));
    try std.testing.expectEqual(@as(i16, 212), w.characters[1].y);
    try std.testing.expectEqual(@as(i16, 212), w.characters[2].y);
    try std.testing.expectEqual(@as(i16, 212), w.characters[0].y);

    w.characters[1].x = 300;
    w.characters[0].x = 100;
    try std.testing.expect(try followCarrierX(&w, 0, {}));
    try std.testing.expectEqual(@as(i16, 144), w.characters[0].x);
    w.characters[1].x = -20;
    w.characters[0].x = -30;
    try std.testing.expect(try followCarrierX(&w, 0, {}));
    try std.testing.expectEqual(@as(i16, -20), w.characters[0].x);
    w.characters[1].x = 77;
    try std.testing.expect(try alignWithCarrier(&w, 0, {}));
    try std.testing.expectEqual(@as(i16, 77), w.characters[0].x);

    try std.testing.expect(!try releaseOn(&w, 0, go));
    w.send(1, 0, go);
    try std.testing.expect(try releaseOn(&w, 0, go));
    try std.testing.expectEqualSlices(u16, &.{2}, testing.items(&w, 1, &buffer));
    try std.testing.expectEqual(@as(?u16, null), w.characters[0].owner);
    // Not riding: still true, x stays.
    try std.testing.expect(try releaseOn(&w, 0, go));
    try std.testing.expect(try alignWithCarrier(&w, 0, {}));
    try std.testing.expectEqual(@as(i16, 77), w.characters[0].x);
}

test "board_touching rides the first touching character of the kind, except placement 120" {
    var characters: [121]testing.data_set.Character = undefined;
    for (&characters, 0..) |*c, i| c.* = testing.character(@intCast(i), .enemy, 64);
    characters[0] = testing.character(0, .player, 0);
    characters[5] = testing.character(5, .interactive, 0);
    characters[6] = testing.character(6, .interactive, 0);
    characters[120] = testing.character(120, .enemy, 0);
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 5, 120, 6, 0 });

    // Character 6 registered after 5, so it comes first in the shared cell.
    try std.testing.expect(try boardTouching(&w, 0, .interactive));
    try std.testing.expectEqual(@as(?u16, 6), w.characters[0].owner);
    try std.testing.expect(!try boardTouching(&w, 0, .enemy));
    try std.testing.expectEqual(@as(?u16, 6), w.characters[0].owner);
    try std.testing.expect(!try boardTouching(&w, 0, .player));
    try std.testing.expect(try boardTouching(&w, 0, .any));
    // The slot table is indexed with a byte: slot 128 reads slot 0.
    w.characters[5].contact +%= 128;
    try std.testing.expect(try boardTouching(&w, 5, .player));
    try std.testing.expectEqual(@as(?u16, 0), w.characters[5].owner);
    w.characters[0].contact = contacts.no_slot;
    try std.testing.expect(!try boardTouching(&w, 0, .any));
}

test "no_loose_cargo: items in the carrier's cells must ride it" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .enemy, 0),
        testing.character(2, .interactive, 0),
    };
    characters[1].width = 2;
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    // The lift covers columns 7 and 8; the item and Conrad stand in column 8.
    w.characters[2].x = 128;
    w.characters[0].x = 128;
    try testing.register(&w, &.{ 1, 2, 0 });
    try std.testing.expect(!try noLooseCargo(&w, 1, {}));
    attach(&w, 1, 2);
    try std.testing.expect(try noLooseCargo(&w, 1, {}));
    // An item riding another carrier also blocks; Conrad never does.
    attach(&w, 0, 2);
    try std.testing.expect(!try noLooseCargo(&w, 1, {}));
    w.characters[2].x = 200;
    try testing.register(&w, &.{ 1, 2, 0 });
    try std.testing.expect(try noLooseCargo(&w, 1, {}));
}

test "terrain changes remember what they replace and restore it" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 0),
        testing.character(2, .interactive, 0),
    };
    characters[1].width = 2;
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    // Character 1 stands in column 7 of the bottom tier: row 5 is its body row.
    w.grid.set(0, 5, 8, 2);
    try std.testing.expect(try makeSolid(&w, 1, 1));
    try std.testing.expectEqual(@as(u8, 1), testing.cell(&w, 0, 5, 7));
    try std.testing.expectEqual(@as(u8, 1), testing.cell(&w, 0, 5, 8));
    try std.testing.expectEqual(@as(u16, 4), w.terrain_history.used_words);
    // The same start is refilled without saving again.
    try std.testing.expect(try makeEmpty(&w, 1, 1));
    try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 0, 5, 8));
    try std.testing.expectEqual(@as(u16, 1), w.terrain_history.change_count);
    // Facing right, the span starts one column back, a new start.
    w.updating_facing_right = true;
    try std.testing.expect(try makeLowPassage(&w, 1, 1));
    try std.testing.expectEqual(@as(u8, 2), testing.cell(&w, 0, 5, 6));
    try std.testing.expectEqual(@as(u8, 2), testing.cell(&w, 0, 5, 7));
    try std.testing.expectEqual(@as(u16, 2), w.terrain_history.change_count);
    // The restore ignores the facing: it finds the change starting at column 7.
    try std.testing.expect(try restoreTerrain(&w, 1, 1));
    try std.testing.expectEqual(@as(u8, 2), testing.cell(&w, 0, 5, 6));
    try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 0, 5, 7));
    try std.testing.expectEqual(@as(u8, 2), testing.cell(&w, 0, 5, 8));

    // A one-cell writer facing right only compares the newest change: writing column 7
    // again after column 3 saves column 7 a second time, with the material it then holds.
    w.characters[2].x = 48;
    try std.testing.expect(try makeSolid(&w, 2, 1));
    w.characters[2].x = 112;
    try std.testing.expect(try makeSolid(&w, 2, 1));
    try std.testing.expectEqual(@as(u16, 4), w.terrain_history.change_count);
    try std.testing.expect(try makeSolid(&w, 2, 1));
    try std.testing.expectEqual(@as(u16, 4), w.terrain_history.change_count);
    // The restore finds the newest change at column 7, saved while it held 0.
    try std.testing.expect(try restoreTerrain(&w, 2, 1));
    try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 0, 5, 7));
    // Solid again (the newest change), then column 3 and column 7 once more: the third change
    // at column 7 saves the solid cell, and the restore puts that back.
    try std.testing.expect(try makeSolid(&w, 2, 1));
    try std.testing.expectEqual(@as(u16, 4), w.terrain_history.change_count);
    w.characters[2].x = 48;
    try std.testing.expect(try makeSolid(&w, 2, 1));
    w.characters[2].x = 112;
    try std.testing.expect(try makeEmpty(&w, 2, 1));
    try std.testing.expectEqual(@as(u16, 6), w.terrain_history.change_count);
    try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 0, 5, 7));
    try std.testing.expect(try restoreTerrain(&w, 2, 1));
    try std.testing.expectEqual(@as(u8, 1), testing.cell(&w, 0, 5, 7));
}

test "the terrain history admits changes while under 762 words" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 0),
    };
    characters[1].width = 4;
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    // Each four-cell change costs 5 words: 152 fit below 762 and the 153rd crosses it.
    var admitted: u16 = 0;
    var room: u8 = 0;
    outer: while (room < 64) : (room += 1) {
        for ([_]i16{ 0, 2, 4 }) |row| for ([_]i16{ 16, 80, 144, 208 }) |x| {
            w.characters[1].room = room;
            w.characters[1].x = x - 8;
            w.characters[1].y = 0;
            const before = w.terrain_history.change_count;
            try std.testing.expect(try makeSolid(&w, 1, row + 1));
            if (w.terrain_history.change_count == before) break :outer;
            admitted += 1;
        };
    }
    try std.testing.expectEqual(@as(u16, 153), admitted);
    try std.testing.expectEqual(@as(u16, 765), w.terrain_history.used_words);
    // The refused change (room 12, row 5, columns 5 to 8) wrote nothing, but a known start
    // can still be rewritten.
    try std.testing.expectEqual(@as(u8, 12), w.characters[1].room);
    try std.testing.expectEqual(@as(u8, 1), testing.cell(&w, 12, 5, 4));
    for (5..9) |column| {
        try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 12, 5, @intCast(column)));
    }
    w.characters[1].room = 0;
    w.characters[1].x = 8;
    try std.testing.expectEqual(@as(u8, 1), testing.cell(&w, 0, 1, 1));
    try std.testing.expect(try makeEmpty(&w, 1, 1));
    try std.testing.expectEqual(@as(u8, 0), testing.cell(&w, 0, 1, 1));
}

test "restore_terrain is false where the cell's address has a zero low byte" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 1),
    };
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    // With no history, the result is the cell's offset in its room: row 0, column 0 is false.
    w.characters[1].x = 0;
    w.characters[1].y = 0;
    try std.testing.expect(!try restoreTerrain(&w, 1, 0));
    try std.testing.expect(try restoreTerrain(&w, 1, 1));
    try std.testing.expect(try makeSolid(&w, 1, 1));
    // With a history, room 1, row 4, column 10 sits at DS:0x3f00.
    w.characters[1].x = 160;
    w.characters[1].y = 144;
    try std.testing.expect(!try restoreTerrain(&w, 1, 0));
    try std.testing.expect(try restoreTerrain(&w, 1, 1));
    try std.testing.expectEqual(@as(u32, 0), w.unmodeled_reads);
}

test "transport moves a character to a template, taking its state in the same behavior" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 0),
        testing.character(2, .interactive, 1),
        testing.character(3, .interactive, 0),
        testing.character(4, .interactive, 64),
    };
    characters[1].behavior = 1;
    characters[1].links = .{
        testing.characterAt(0),
        testing.characterAt(2),
        testing.characterAt(4),
        null,
    };
    characters[2].x = 40;
    characters[2].y = 142;
    characters[2].facing = .right;
    characters[2].start = 1;
    characters[3].behavior = 1;
    characters[3].links = .{
        testing.characterAt(3),
        testing.characterAt(2),
        testing.characterAt(4),
        null,
    };
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    const first: vocabulary.Link = @fromBackingInt(0);
    const second: vocabulary.Link = @fromBackingInt(1);
    const third: vocabulary.Link = @fromBackingInt(2);

    w.characters[0].cursor = 1;
    try std.testing.expect(try transport(&w, 1, .{ .move = first, .to = second }));
    const conrad = w.characters[0];
    try std.testing.expectEqual(@as(i16, 40), conrad.x);
    try std.testing.expectEqual(@as(i16, 142), conrad.y);
    try std.testing.expectEqual(@as(u8, 1), conrad.room);
    try std.testing.expectEqual(@as(u16, 1), conrad.state);
    try std.testing.expect(conrad.facing_right);
    try std.testing.expectEqual(@as(u8, 0), conrad.cursor);
    try std.testing.expectEqual(@as(u8, 1), w.view_room);
    try std.testing.expectEqual(@as(?u16, 0), w.room_lists[1]);
    try std.testing.expectEqual(@as(?u16, 3), w.room_lists[0]);

    // Another behavior keeps its state; an unfinished animation restarts, a finished one not.
    w.characters[3].state = 1;
    w.characters[3].cursor = 2;
    try std.testing.expect(try transport(&w, 3, .{ .move = first, .to = second }));
    try std.testing.expectEqual(@as(u8, 0), w.characters[3].cursor);
    try std.testing.expect(!w.characters[3].facing_right);
    try std.testing.expectEqual(@as(?u16, 3), w.room_lists[1]);
    w.characters[3].cursor = 3;
    try std.testing.expect(try transport(&w, 3, .{ .move = first, .to = second }));
    try std.testing.expectEqual(@as(u8, 3), w.characters[3].cursor);
    try std.testing.expectEqual(@as(?u16, 3), w.room_lists[1]);

    // A template outside the rooms moves nobody.
    try std.testing.expect(try transport(&w, 1, .{ .move = first, .to = third }));
    try std.testing.expectEqual(@as(u8, 1), w.characters[0].room);
}

test "snap_to_grid floors x to 16 and puts y on its tier's floor line" {
    var characters = [_]testing.data_set.Character{testing.character(0, .player, 0)};
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    const cases = [_][4]i16{
        .{ 23, 100, 16, 142 },
        .{ 15, 214, 0, 214 },
        .{ -3, -5, -16, 70 },
        .{ 0, -72, 0, -2 },
        .{ 32, 70, 32, 70 },
    };
    for (cases) |case| {
        w.characters[0].x = case[0];
        w.characters[0].y = case[1];
        try std.testing.expect(try snapToGrid(&w, 0, {}));
        try std.testing.expectEqual(case[2], w.characters[0].x);
        try std.testing.expectEqual(case[3], w.characters[0].y);
    }
}

test "checkpoint saves the characters, score, grid and terrain history" {
    var characters = [_]testing.data_set.Character{
        testing.character(0, .player, 0),
        testing.character(1, .interactive, 0),
    };
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    w.score = 1500;
    try std.testing.expect(try makeSolid(&w, 1, 1));
    try std.testing.expect(try checkpoint(&w, 1, {}));
    w.score = 0;
    w.characters[0].x = 5;
    try std.testing.expect(try makeEmpty(&w, 1, 1));
    const saved = &w.checkpoint.?;
    try std.testing.expectEqual(@as(u32, 1500), saved.score);
    try std.testing.expectEqual(@as(i16, 112), saved.characters[0].x);
    try std.testing.expectEqual(@as(u8, 1), saved.grid.bytes[256 + 5 * 16 + 7]);
    try std.testing.expectEqual(@as(u16, 1), saved.terrain_history.change_count);

    // A continue restores them, rebuilds the room lists and restarts.
    w.characters[1].room = 3;
    w.room_lists = @splat(null);
    w.protection = 9;
    try std.testing.expect(w.restoreCheckpoint());
    try std.testing.expectEqual(@as(u32, 1500), w.score);
    try std.testing.expectEqual(@as(i16, 112), w.characters[0].x);
    try std.testing.expectEqual(@as(u8, 1), w.grid.bytes[256 + 5 * 16 + 7]);
    try std.testing.expectEqual(@as(?u16, 1), w.room_lists[w.characters[1].room]);
    try std.testing.expectEqual(@as(u8, 0), w.protection);
    try std.testing.expect(w.view_dirty);
}

test "a continue without a checkpoint restores nothing" {
    var characters = [_]testing.data_set.Character{testing.character(0, .player, 0)};
    const level: testing.data_set.Level = .{
        .behaviors = &testing.behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    var w = try testing.world(&level);
    defer w.deinit();
    try std.testing.expect(!w.restoreCheckpoint());
}
