//! Characters sharing cells: touching checks and messages to touching characters.
//! Contacts are registered at the start of each update, so these checks see where everyone
//! stood then. Two searches read them, as in the original (flashback-re docs/rules, contact
//! cells): most checks walk the whole footprint of the character and meet the character
//! itself; the others look only in the first cell of a footprint. Neither looks at whether a
//! character is awake. Kinds compare on their low byte.
const std = @import("std");
const vocabulary = @import("../vocabulary.zig");
const contacts = @import("../contacts.zig");
const World = @import("../world.zig").World;

// Touching anywhere on the footprint ------------------------------------------------------

/// Touching a character of that kind that faces the other way (back to back counts).
pub fn touchingFacingOpposite(world: *World, actor: u16, kind: vocabulary.Kind) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (isKind(world, other, kind) and !facingSame(world, actor, other)) return true;
    }
    return false;
}

/// Touching a character of that kind that faces the same way; the character itself counts.
pub fn touchingFacingSame(world: *World, actor: u16, kind: vocabulary.Kind) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (isKind(world, other, kind) and facingSame(world, actor, other)) return true;
    }
    return false;
}

/// Touching a character of that kind whose animation has that pose; the character itself
/// counts. The engine reads the operation's own `kind`. The extractor takes it from the
/// argument of the original rule's first condition.
pub fn touchingKindInPose(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "touching_kind_in_pose"),
) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (isKind(world, other, argument.kind) and try inPose(world, other, argument.pose)) {
            return true;
        }
    }
    return false;
}

/// Someone else whose animation has that pose shares a cell.
pub fn touchingInPose(world: *World, actor: u16, pose: i16) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (other != actor and try inPose(world, other, pose)) return true;
    }
    return false;
}

/// Someone else shares a cell, whatever its kind.
pub fn touchingAnyone(world: *World, actor: u16, _: void) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (other != actor) return true;
    }
    return false;
}

/// Touching a character of that kind; the character itself counts. An enemy counts only
/// while its health is not negative.
pub fn touching(world: *World, actor: u16, kind: vocabulary.Kind) !bool {
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (!isKind(world, other, kind)) continue;
        if (kind == .enemy and world.characters[other].health < 0) continue;
        return true;
    }
    return false;
}

/// Sends to everyone else touching that faces the other way. See `sendToTouchingFacing`.
pub fn sendToTouchingFacingOpposite(world: *World, actor: u16, message: vocabulary.Message) !bool {
    return sendToTouchingFacing(world, actor, message, false);
}

/// Sends to everyone else touching that faces the same way. See `sendToTouchingFacing`.
pub fn sendToTouchingFacingSame(world: *World, actor: u16, message: vocabulary.Message) !bool {
    return sendToTouchingFacing(world, actor, message, true);
}

/// Conrad sends only to the first one he meets. Someone sharing several cells gets one
/// message per cell. True when anyone was sent the message, even if it was dropped.
fn sendToTouchingFacing(
    world: *World,
    actor: u16,
    message: vocabulary.Message,
    same: bool,
) bool {
    var sent = false;
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (other == actor or facingSame(world, actor, other) != same) continue;
        world.send(actor, other, message);
        sent = true;
        if (actor == 0) break;
    }
    return sent;
}

/// Sends to everyone else sharing a cell; someone sharing several cells gets one message per
/// cell. True when anyone was sent the message, even if it was dropped.
pub fn broadcast(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var sent = false;
    var mates = cellMates(world, actor);
    while (mates.next()) |other| {
        if (other == actor) continue;
        world.send(actor, other, message);
        sent = true;
    }
    return sent;
}

// Someone in the first cell ---------------------------------------------------------------

/// Sends to the first object (interactive kind) in the character's first cell. True when
/// there was one.
pub fn sendToTouchingObject(world: *World, actor: u16, message: vocabulary.Message) !bool {
    const object = firstCellMate(world, actor, .interactive) orelse return false;
    world.send(actor, object, message);
    return true;
}

/// Sends to a device in the character's first cell, preferring kinds 3, 5 and 9 in that order
/// to anyone else. Never true: as a condition it sends each time it is evaluated and its rule
/// never fires.
pub fn sendToTouchingDevice(world: *World, actor: u16, message: vocabulary.Message) !bool {
    const device = firstCellMate(world, actor, .interactive) orelse
        firstCellMate(world, actor, @fromBackingInt(5)) orelse
        firstCellMate(world, actor, @fromBackingInt(9)) orelse
        firstCellMate(world, actor, .any) orelse return false;
    world.send(actor, device, message);
    return false;
}

/// Conrad's first cell holds a character of that kind (`any`: anyone) besides him.
pub fn playerTouching(world: *World, _: u16, kind: vocabulary.Kind) !bool {
    return firstCellMate(world, 0, kind) != null;
}

/// Sends to the device in Conrad's first cell, of the kind a placement number names, when its
/// code (health) is exactly this character's.
pub fn sendToMatchingDevice(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "send_to_matching_device"),
) !bool {
    const kind: vocabulary.Kind = @fromBackingInt(world.number(actor, argument.kind));
    const device = firstCellMate(world, 0, kind) orelse return false;
    if (world.characters[device].health != world.characters[actor].health) return false;
    world.send(actor, device, argument.message);
    return true;
}

/// This purse pays the seller in Conrad's first cell, of the kind a placement number names,
/// when it holds at least the seller's price (health on both): it sends the message and the
/// seller takes the money.
pub fn offerPayment(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "offer_payment"),
) !bool {
    const kind: vocabulary.Kind = @fromBackingInt(world.number(actor, argument.seller));
    const seller = firstCellMate(world, 0, kind) orelse return false;
    if (world.characters[seller].health > world.characters[actor].health) return false;
    world.send(actor, seller, argument.message);
    return true;
}

/// The first object (interactive kind) in the character's first cell, the character itself
/// included, shows that contact icon. Only that object is compared; with none the icon reads
/// as 0, so 0 then holds.
pub fn touchingPickup(world: *World, actor: u16, icon: i16) !bool {
    var shown: i16 = 0;
    const first = world.characters[actor].contact;
    if (first != contacts.no_slot) {
        var occupants = world.contacts.occupants(first);
        while (occupants.nextEntry()) |entry| {
            const placement = world.level.characters[entry.character];
            // The original searches for kind 3 or kind -1, as bytes: kind 255 matches too.
            if (!placement.kind.matches(.interactive) and !placement.kind.matches(.any)) continue;
            shown = placement.contact_icon;
            break;
        }
    }
    return shown == icon;
}

// Messages ---------------------------------------------------------------------------------

/// Moves onto the newest sender of a waiting message with that value: its position, room and
/// facing. A carried item leaves its owner's inventory. The message stays.
pub fn appearAtSender(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var letters = world.mailbox(actor);
    const sender = while (letters.nextLetter()) |letter| {
        if (letter.message == message) break letter.sender;
    } else return false;
    const from = world.characters[sender];
    const character = &world.characters[actor];
    character.x = from.x;
    character.y = from.y;
    character.room = from.room;
    character.facing_right = from.facing_right;
    if (character.owner) |owner| {
        world.unlinkItem(owner, actor);
    }
    return true;
}

// Searches ---------------------------------------------------------------------------------

/// Everyone registered in the character's cells, cell by cell along its footprint and newest
/// arrival first within a cell. The walk starts at `Character.contact` and follows two links:
/// `next` through the entries of a slot, and the `next_slot` of the character's own entry to
/// its next cell, once the current slot ends. So the character meets itself in each of its
/// cells, and someone sharing several cells is met once per cell. A slot without the
/// character's own entry ends the walk.
const CellMates = struct {
    contacts: *const contacts.Contacts,
    actor: u16,
    cell: u8 = contacts.no_slot,
    next_cell: u8,
    entry: ?u16 = null,

    fn next(self: *CellMates) ?u16 {
        while (self.entry == null) {
            if (self.next_cell == contacts.no_slot) return null;
            self.cell = self.next_cell;
            self.next_cell = contacts.no_slot;
            self.entry = self.contacts.slots[self.cell];
        }
        const entry = self.contacts.entries[self.entry.?];
        self.entry = entry.next;
        if (entry.character == self.actor) {
            self.next_cell = entry.next_slot orelse contacts.no_slot;
            // A footprint leading back into the same cell ends the walk, as in the original.
            if (self.next_cell == self.cell) {
                self.entry = null;
                self.next_cell = contacts.no_slot;
            }
        }
        return entry.character;
    }
};

fn cellMates(world: *const World, actor: u16) CellMates {
    return .{
        .contacts = &world.contacts,
        .actor = actor,
        .next_cell = world.characters[actor].contact,
    };
}

/// The newest character other than `who`, of that kind (`any`: anyone), in `who`'s first
/// cell. The original finds that cell with a byte-wide offset, so a first cell numbered 128 or
/// more reads the cell numbered 128 below it.
fn firstCellMate(world: *const World, who: u16, kind: vocabulary.Kind) ?u16 {
    const first = world.characters[who].contact;
    if (first == contacts.no_slot) return null;
    var occupants = world.contacts.occupants(first & 0x7f);
    while (occupants.nextEntry()) |entry| {
        if (entry.character == who) continue;
        if (kind == .any or isKind(world, entry.character, kind)) return entry.character;
    }
    return null;
}

fn isKind(world: *const World, character: u16, kind: vocabulary.Kind) bool {
    return world.level.characters[character].kind.matches(kind);
}

fn facingSame(world: *const World, a: u16, b: u16) bool {
    return world.characters[a].facing_right == world.characters[b].facing_right;
}

/// The pose tag of the character's current animation is the low byte of `pose`.
fn inPose(world: *const World, character: u16, pose: i16) !bool {
    const animation = world.animationOf(character) catch return error.InvalidAnimation;
    return animation.pose == vocabulary.lowByte(pose);
}

// Tests ------------------------------------------------------------------------------------

const testing = struct {
    const data_set = @import("../data_set.zig");
    const grid = @import("../grid.zig");
    const animations = @import("../../content/animations.zig");

    /// Animation 0 has pose 0 and animation 1 pose 4; each is one still frame.
    const animation_bytes = [_]u8{ 2, 0, 4, 0, 14, 0 } ++
        [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++
        [_]u8{ 1, 0, 0, 4, 0, 0, 0, 0, 0, 0 };
    const states = [_]vocabulary.State{
        .{ .name = "standing", .animation = 0, .rules = &.{} },
        .{ .name = "posing", .animation = 1, .rules = &.{} },
    };
    const behaviors = [_]vocabulary.Behavior{.{
        .name = "test",
        .links = &.{},
        .numbers = &.{ "seller", "device" },
        .states = &states,
    }};
    const call: vocabulary.Message = @fromBackingInt(300);

    /// On the bottom tier of room 0; x 100 covers column 6, x 116 column 7.
    fn character(
        kind: vocabulary.Kind,
        x: i16,
        width: u8,
        facing: data_set.Facing,
    ) data_set.Character {
        return .{
            .name = "c",
            .placement = 0,
            .kind = kind,
            .behavior = 0,
            .start = 0,
            .room = 0,
            .x = x,
            .y = 214,
            .facing = facing,
            .health = 2,
            .width = width,
            .active = true,
            .minimum_difficulty = .easy,
        };
    }

    fn level(characters: []const data_set.Character) data_set.Level {
        return .{ .behaviors = &behaviors, .characters = characters, .message_names = &.{} };
    }

    /// A world with its contacts registered, as at the start of an update.
    fn world(of: *const data_set.Level) !World {
        var layout: [grid.Grid.layout_size]u8 = @splat(0);
        @memset(layout[0..256], 0xff);
        var w = try World.init(
            std.testing.allocator,
            of,
            try animations.Animations.init(&animation_bytes),
            try grid.Grid.init(&layout),
            .{},
        );
        errdefer w.deinit();
        try register(&w);
        return w;
    }

    /// Every character registers its cells in placement order.
    fn register(w: *World) !void {
        w.contacts.begin();
        for (w.characters, w.level.characters, 0..) |*c, placement, i| {
            var shared: contacts.Shared = .{};
            const first = w.contacts.register(
                &w.grid,
                @intCast(i),
                c.room,
                c.x,
                c.y,
                placement.width,
                &shared,
            );
            if (first) |slot| {
                c.contact = slot;
            }
        }
    }

    fn waiting(w: *const World, index: u16) usize {
        var count: usize = 0;
        var letters = w.mailbox(index);
        while (letters.nextLetter()) |_| {
            count += 1;
        }
        return count;
    }

    fn kindOf(value: i16) vocabulary.Kind {
        return @fromBackingInt(value);
    }
};

test "the footprint walk meets everyone cell by cell, the character itself included" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 100, 2, .right), // columns 6 and 7
        testing.character(.interactive, 100, 1, .left), // column 6
        testing.character(.enemy, 100, 2, .right), // columns 6 and 7
        testing.character(.enemy, 200, 1, .left), // column 13, alone
    };
    const level = testing.level(&characters);
    var w = try testing.world(&level);
    defer w.deinit();

    var met: [8]u16 = undefined;
    var count: usize = 0;
    var mates = cellMates(&w, 0);
    while (mates.next()) |other| : (count += 1) {
        met[count] = other;
    }
    try std.testing.expectEqualSlices(u16, &.{ 2, 1, 0, 2, 0 }, met[0..count]);

    try std.testing.expect(try touchingAnyone(&w, 0, {}));
    try std.testing.expect(!try touchingAnyone(&w, 3, {}));
    try std.testing.expect(try touching(&w, 0, .enemy));
    try std.testing.expect(try touching(&w, 1, .player));
    // Alone, a character still touches its own kind; an enemy only while its health holds.
    try std.testing.expect(try touching(&w, 3, .enemy));
    try std.testing.expect(try touchingFacingSame(&w, 3, .enemy));
    try std.testing.expect(!try touchingFacingOpposite(&w, 3, .enemy));
    w.characters[3].health = -1;
    try std.testing.expect(!try touching(&w, 3, .enemy));

    try std.testing.expect(try touchingFacingOpposite(&w, 0, .interactive));
    try std.testing.expect(!try touchingFacingSame(&w, 0, .interactive));
    try std.testing.expect(try touchingFacingSame(&w, 0, .enemy));
    try std.testing.expect(!try touchingFacingOpposite(&w, 0, .enemy));

    // Someone sharing both cells hears a broadcast twice.
    try std.testing.expect(try broadcast(&w, 0, testing.call));
    try std.testing.expectEqual(@as(usize, 2), testing.waiting(&w, 2));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 1));
    try std.testing.expectEqual(@as(usize, 0), testing.waiting(&w, 0));
    try std.testing.expect(!try broadcast(&w, 3, testing.call));
}

test "messages to touching characters by facing" {
    var characters = [_]testing.data_set.Character{
        testing.character(.player, 100, 1, .right),
        testing.character(.enemy, 100, 1, .right),
        testing.character(.enemy, 100, 1, .right), // asleep and deaf to messages
        testing.character(.interactive, 100, 1, .left),
        testing.character(.enemy, 200, 1, .left), // alone
    };
    characters[2].active = false;
    const level = testing.level(&characters);
    var w = try testing.world(&level);
    defer w.deinit();

    // Conrad stops at the first one he meets, even though the message was dropped.
    try std.testing.expect(try sendToTouchingFacingSame(&w, 0, testing.call));
    try std.testing.expectEqual(@as(usize, 0), testing.waiting(&w, 1));
    // Others send to every match.
    try std.testing.expect(try sendToTouchingFacingSame(&w, 1, testing.call));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 0));
    try std.testing.expect(try sendToTouchingFacingOpposite(&w, 3, testing.call));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 1));
    try std.testing.expectEqual(@as(usize, 2), testing.waiting(&w, 0));
    try std.testing.expectEqual(@as(usize, 0), testing.waiting(&w, 2));
    try std.testing.expect(try sendToTouchingFacingOpposite(&w, 1, testing.call));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 3));
    try std.testing.expect(!try sendToTouchingFacingSame(&w, 4, testing.call));
}

test "searches in the first cell" {
    var characters = [_]testing.data_set.Character{
        testing.character(.player, 100, 2, .right), // columns 6 and 7
        testing.character(testing.kindOf(5), 100, 1, .left), // a seller
        testing.character(.interactive, 100, 1, .left), // a pickup
        testing.character(testing.kindOf(9), 100, 1, .left), // a device
        testing.character(.enemy, 116, 1, .left), // in Conrad's second cell only
        testing.character(testing.kindOf(7), 200, 1, .left), // a purse, alone
    };
    characters[1].health = 500;
    characters[2].contact_icon = 5;
    characters[3].health = 7;
    characters[5].health = 600;
    characters[5].numbers = .{ 5, 9, 0, 0 };
    const level = testing.level(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    const seller: vocabulary.Number = @fromBackingInt(0);
    const device: vocabulary.Number = @fromBackingInt(1);

    try std.testing.expect(!try playerTouching(&w, 5, .enemy));
    try std.testing.expect(try playerTouching(&w, 5, testing.kindOf(9)));
    try std.testing.expect(!try playerTouching(&w, 5, .player));
    try std.testing.expect(try playerTouching(&w, 5, .any));

    try std.testing.expect(try touchingPickup(&w, 0, 5));
    try std.testing.expect(!try touchingPickup(&w, 0, 4));

    try std.testing.expect(try sendToTouchingObject(&w, 0, testing.call));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 2));
    try std.testing.expect(!try sendToTouchingDevice(&w, 0, testing.call));
    try std.testing.expectEqual(@as(usize, 2), testing.waiting(&w, 2));

    const pay: @FieldType(vocabulary.Operation, "offer_payment") = .{
        .message = testing.call,
        .seller = seller,
    };
    try std.testing.expect(try offerPayment(&w, 5, pay));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 1));
    w.characters[5].health = 499;
    try std.testing.expect(!try offerPayment(&w, 5, pay));
    w.characters[5].health = 500;
    try std.testing.expect(try offerPayment(&w, 5, pay));
    try std.testing.expectEqual(@as(usize, 2), testing.waiting(&w, 1));

    const unlock: @FieldType(vocabulary.Operation, "send_to_matching_device") = .{
        .message = testing.call,
        .kind = device,
    };
    try std.testing.expect(!try sendToMatchingDevice(&w, 5, unlock));
    w.characters[5].health = 7;
    try std.testing.expect(try sendToMatchingDevice(&w, 5, unlock));
    try std.testing.expectEqual(@as(usize, 1), testing.waiting(&w, 3));

    // Without the pickup, kind 5 is preferred over the newer kind 9 and no icon reads as 0.
    w.characters[2].x = 200;
    try testing.register(&w);
    try std.testing.expect(!try sendToTouchingDevice(&w, 0, testing.call));
    try std.testing.expectEqual(@as(usize, 3), testing.waiting(&w, 1));
    try std.testing.expect(try touchingPickup(&w, 0, 0));
    try std.testing.expect(!try touchingPickup(&w, 0, 5));

    // A first cell numbered 128 or more is read as the one 128 below it, but only here.
    w.characters[0].contact += 128;
    try std.testing.expect(try playerTouching(&w, 5, testing.kindOf(9)));
    try std.testing.expect(!try touchingAnyone(&w, 0, {}));
}

test "poses of touching characters" {
    var characters = [_]testing.data_set.Character{
        testing.character(.player, 100, 1, .right),
        testing.character(.interactive, 100, 1, .left),
    };
    characters[1].start = 1;
    const level = testing.level(&characters);
    var w = try testing.world(&level);
    defer w.deinit();

    try std.testing.expect(!try touchingInPose(&w, 1, 4));
    try std.testing.expect(try touchingInPose(&w, 0, 4));
    try std.testing.expect(try touchingKindInPose(&w, 1, .{ .kind = .interactive, .pose = 4 }));
    try std.testing.expect(!try touchingKindInPose(&w, 0, .{ .kind = .player, .pose = 4 }));
    try std.testing.expect(try touchingKindInPose(&w, 0, .{ .kind = .player, .pose = 0 }));
}

test "appearing at the newest sender leaves the owner's inventory" {
    var characters = [_]testing.data_set.Character{
        testing.character(.player, 100, 1, .right),
        testing.character(.interactive, 10, 1, .left),
        testing.character(.enemy, 50, 1, .left),
        testing.character(.enemy, 70, 1, .right),
    };
    characters[3].room = 2;
    characters[3].y = 50;
    const level = testing.level(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    w.characters[0].first_item = 1;
    w.characters[1].owner = 0;

    w.send(2, 1, testing.call);
    w.send(3, 1, testing.call);
    w.send(2, 1, @fromBackingInt(301));
    try std.testing.expect(!try appearAtSender(&w, 1, @fromBackingInt(302)));
    try std.testing.expectEqual(@as(i16, 10), w.characters[1].x);
    try std.testing.expect(try appearAtSender(&w, 1, testing.call));
    const item = w.characters[1];
    try std.testing.expectEqual(@as(i16, 70), item.x);
    try std.testing.expectEqual(@as(i16, 50), item.y);
    try std.testing.expectEqual(@as(u8, 2), item.room);
    try std.testing.expect(item.facing_right);
    try std.testing.expectEqual(@as(?u16, null), item.owner);
    try std.testing.expectEqual(@as(?u16, null), w.characters[0].first_item);
}
