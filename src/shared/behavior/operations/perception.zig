//! Seeing, shooting and striking along the character's tier, and Conrad's position relative to
//! it. Scans walk cells of the character's tier; "ahead" follows the facing the character had
//! when its update started. Every quirk below is the original's (flashback-re `docs/rules/`,
//! codes 64, 95, 98-100, 106, 107, 118-121 and 134).
const std = @import("std");
const vocabulary = @import("../vocabulary.zig");
const world_module = @import("../world.zig");
const contacts = @import("../contacts.zig");
const grid = @import("../grid.zig");
const World = world_module.World;
const Kind = vocabulary.Kind;
const Message = vocabulary.Message;
const Height = vocabulary.Height;

// Hits ------------------------------------------------------------------------------------

/// A hit from that side is waiting: from behind is a hit by someone facing the same way,
/// from the front one by someone facing it. The height of the hit does not matter.
pub fn hit(world: *World, actor: u16, side: vocabulary.HitSide) !bool {
    var letters = world.mailbox(actor);
    while (letters.nextLetter()) |letter| switch (letter.message) {
        .hit_behind_high, .hit_behind_low => if (side == .from_behind) return true,
        .hit_front_high, .hit_front_low => if (side != .from_behind) return true,
        else => {},
    };
    return false;
}

/// Whether the character's current state has a rule waiting for that hit. Only waiting
/// characters can be shot or struck; an unannounced front hit never counts as waiting.
fn waitsFor(world: *const World, character: u16, message: Message) bool {
    for (world.stateOf(character).rules) |rule| for (rule.when) |check| switch (check) {
        .received => |expected| if (expected == message) return true,
        .hit => |side| switch (side) {
            .from_behind => switch (message) {
                .hit_behind_high, .hit_behind_low => return true,
                else => {},
            },
            .from_front => switch (message) {
                .hit_front_high, .hit_front_low => return true,
                else => {},
            },
            .from_front_unannounced => {},
        },
        else => {},
    };
    return false;
}

/// The hit a blow delivers: from behind when both face the same way, low when crouched.
fn hitMessage(world: *const World, actor: u16, target: u16, height: Height) Message {
    const same = world.characters[actor].facing_right == world.characters[target].facing_right;
    return switch (height) {
        .standing => if (same) .hit_behind_high else .hit_front_high,
        .crouched => if (same) .hit_behind_low else .hit_front_low,
    };
}

/// Fires along the tier up to the `range` number's cells (positive: ahead) from the next
/// cell. The first awake player, enemy or kind-12 character waiting for the hit gets it;
/// others are passed through. True once a hit is sent, even if the send is dropped.
pub fn shoot(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "shoot"),
) !bool {
    const range = world.number(actor, argument.range);
    return traceHit(world, actor, argument.height, range, .shot);
}

/// A close blow, like `shoot` but only players and enemies can be struck.
pub fn strike(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "strike"),
) !bool {
    const range = world.number(actor, argument.range);
    return traceHit(world, actor, argument.height, range, .blow);
}

const Blow = enum { shot, blow };

/// Each cell's characters are tried before its terrain, so a target standing in a wall is
/// hit. Terrain stops the trace unless it is a low gap and the blow is low.
fn traceHit(world: *World, actor: u16, height: Height, range: i16, blow: Blow) bool {
    const shooter = world.characters[actor];
    var room = shooter.room;
    if (room >= 64) return false;
    const tier = @divTrunc(shooter.y -% 8, 72);
    if (tier < 0 or tier > 2) return false;
    const ahead = range > 0;
    const cells: i16 = if (ahead) range else -%range;
    var column: i32 = grid.columnOf(shooter.x);
    const step: i32 = if (ahead == world.updating_facing_right) 1 else -1;
    var distance: i16 = 1;
    while (distance <= cells) : (distance += 1) {
        column += step;
        if (column < 0) {
            room = neighbor(world, room, .left) orelse return false;
            column += 16;
        }
        if (column >= 16) {
            room = neighbor(world, room, .right) orelse return false;
            column -= 16;
        }
        const key: contacts.Key = @intCast(@as(i32, room) * 64 + tier * 16 + column);
        if (slotWithKey(world, key)) |slot| {
            var in_cell = world.contacts.occupants(slot);
            while (in_cell.nextEntry()) |entry| {
                const target = entry.character;
                if (target == actor or !world.characters[target].active) continue;
                const kind = world.level.characters[target].kind;
                const hittable = switch (blow) {
                    .shot => kind == .player or kind == .enemy or @backingInt(kind) == 12,
                    .blow => kind == .player or kind == .enemy,
                };
                if (!hittable) continue;
                const message = hitMessage(world, actor, target, height);
                if (!waitsFor(world, target, message)) continue;
                world.send(actor, target, message);
                return true;
            }
        }
        if (!passes(sampled(world, actor, if (ahead) distance else -distance), height)) {
            return false;
        }
    }
    return false;
}

/// Empty terrain lets a blow through; a low gap only a crouched one.
fn passes(cell: i8, height: Height) bool {
    return cell == 0 or (cell & 2 != 0 and height == .crouched);
}

/// This update's slot for a cell key, as registered at the start of the update.
fn slotWithKey(world: *const World, key: contacts.Key) ?u8 {
    const registered = world.contacts.slots[0..world.contacts.slot_count];
    for (registered, 0..) |head, slot| {
        if (world.contacts.entries[head orelse continue].key == key) return @intCast(slot);
    }
    return null;
}

// Facing targets that would not accept a hit (98, 99) --------------------------------------

/// An awake character of that kind facing this one within range is not waiting for the hit.
pub fn facingTargetUnhittable(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "facing_target_unhittable"),
) !bool {
    const range = world.number(actor, argument.range);
    return unhittableTargets(world, actor, argument.kind, argument.hit, range, .opposite) != 0;
}

/// An awake character of that kind with its back turned within range is not waiting for the
/// hit.
pub fn backturnedTargetUnhittable(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "backturned_target_unhittable"),
) !bool {
    const range = world.number(actor, argument.range);
    return unhittableTargets(world, actor, argument.kind, argument.hit, range, .same) != 0;
}

const Facing = enum { opposite, same };

fn lowByte(kind: Kind) u8 {
    return @truncate(@as(u16, @bitCast(@backingInt(kind))));
}

/// Counts the awake characters of `kind` facing the way `facing` says relative to the actor
/// and not waiting for `message`, from its own cell to `range` cells (positive: ahead). A cell
/// with any terrain at body height ends the count after its characters. Only the count's low
/// byte matters to a rule.
fn unhittableTargets(
    world: *World,
    actor: u16,
    kind: Kind,
    message: Message,
    range: i16,
    facing: Facing,
) u8 {
    const observer = world.characters[actor];
    var room = observer.room;
    if (room >= 64) return 0;
    // This tier ignores the 8-pixel offset of contact cells; outside the three tiers the
    // original returns an uninitialized count.
    const tier = @divTrunc(observer.y, 72);
    if (tier < 0 or tier > 2) {
        world.unmodeled_reads += 1;
        return 0;
    }
    const ahead = range > 0;
    const cells: i16 = if (ahead) range else -%range;
    var column: i32 = grid.columnOf(observer.x);
    const step: i32 = if (ahead == world.updating_facing_right) 1 else -1;
    var count: u8 = 0;
    var distance: i16 = 0;
    while (distance <= cells) : ({
        distance += 1;
        column += step;
    }) {
        if (column < 0) {
            room = neighbor(world, room, .left) orelse return count;
            column += 16;
        }
        if (column >= 16) {
            room = neighbor(world, room, .right) orelse return count;
            column -= 16;
        }
        const key: contacts.Key = @intCast(@as(i32, room) * 64 + tier * 16 + column);
        if (slotWithKey(world, key)) |slot| {
            var in_cell = world.contacts.occupants(slot);
            while (in_cell.nextEntry()) |entry| {
                const target = entry.character;
                if (target == actor or !world.characters[target].active) continue;
                // The kinds' low bytes are compared.
                const target_kind = world.level.characters[target].kind;
                if (lowByte(target_kind) != lowByte(kind)) continue;
                const same = world.characters[target].facing_right == observer.facing_right;
                if (same != (facing == .same)) continue;
                if (!waitsFor(world, target, message)) count +%= 1;
            }
        }
        if (sampled(world, actor, if (ahead) distance else -distance) != 0) return count;
    }
    return count;
}

// Shots meeting walls (95) -------------------------------------------------------------------

pub fn snapToWallAhead(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "snap_to_wall_ahead"),
) !bool {
    const range = world.number(actor, argument.range);
    return snapToWall(world, actor, argument.through_low_gaps, range);
}

/// Finds the first wall within `range` cells, from the own cell, and moves onto it: x to the
/// wall's column, the room to the room it was found in, y unchanged. The probes always look
/// ahead; the column stored follows the range's sign. Quirks: a wall right past a room edge
/// stores x = 256 or -16 with the old room, and running out of range on a passed low gap
/// (with no room edge on that step) is true without moving.
fn snapToWall(world: *World, actor: u16, passes_low_gaps: bool, range: i16) bool {
    const shot = &world.characters[actor];
    var room = shot.room;
    if (room >= 64) return false;
    const ahead = range > 0;
    const cells: i16 = if (ahead) range else -%range;
    const step: i32 = if (ahead == world.updating_facing_right) 1 else -1;
    var column: i32 = unsignedColumn(shot.x);
    var last: i8 = 0;
    var distance: i16 = 0;
    while (distance <= cells) : (distance += 1) {
        const cell = sampled(world, actor, distance);
        const open = cell == 0 or (cell & 2 != 0 and passes_low_gaps);
        if (!open) {
            shot.room = room;
            shot.x = @bitCast(@as(u16, @truncate(@as(u32, @bitCast(column)) << 4)));
            return true;
        }
        last = cell;
        if (column < 0) {
            last = 0;
            room = neighbor(world, room, .left) orelse return false;
            if (room >= 64) return false;
            column += 16;
        } else if (column > 15) {
            last = 0;
            room = neighbor(world, room, .right) orelse return false;
            if (room >= 64) return false;
            column -= 16;
        }
        column += step;
    }
    return last != 0;
}

// Sight (64) and the line of fire (106) -----------------------------------------------------
//
// Both scans read the window: the contact slots of the view room's left neighbor, the view
// room and its right neighbor, as one strip of 3 rooms x 3 tiers x 16 columns
// (`contacts.window`). Moving along the strip, column 16 of a tier is column 0 of the next
// one. Their terrain reads are direct reads of the room's body row, which also run on into
// the following bytes of the grid.

const strip_length = 3 * 48;

/// Sees an awake character of that kind along its tier within `cells` (positive: the way
/// it faces, capped at 16, at least one), stopping at body-height terrain. Only rooms of the
/// window are watched and the own cell never is.
///
/// Looking right, each contact cell is one column beyond the terrain cell checked with it,
/// so a target just past a one-cell wall is seen.
///
/// Looking left, examining any other awake character makes the scan continue from the bytes
/// just before that character's placement record instead of the window (see `Cursor`), and
/// after a room edge the contact cells run one column right of the terrain cells.
pub fn sees(world: *World, actor: u16, argument: @FieldType(vocabulary.Operation, "sees")) !bool {
    const observer = world.characters[actor];
    var room = observer.room;
    if (room >= 64) return false;
    var third = windowThird(world, room) orelse return false;
    var column = unsignedColumn(observer.x);
    const tier = @divTrunc(observer.y, 72);
    if (tier < 0 or tier > 2) return false;
    const row = tier * 2 + 1;
    const cells = if (world.updating_facing_right) -%argument.cells else argument.cells;
    const steps = @max(@min(@abs(cells), 16), 1);
    const own: i32 = third * 48 + tier * 16 + column;

    if (cells < 0) {
        var strip = own + 1;
        for (0..steps) |_| {
            column += 1;
            if (column == 16) {
                third += 1;
                if (third > 2) return false;
                // A missing right neighbor is not noticed; its terrain is read past the grid.
                room = world.grid.rawLink(room, .right);
                column = 0;
                strip += 32;
            }
            strip += 1;
            if (occupants(world, stripSlot(world, strip))) |found| {
                var in_cell = found;
                while (in_cell.nextEntry()) |entry| {
                    const seen = entry.character;
                    if (seen == actor or !world.characters[seen].active) continue;
                    if (world.level.characters[seen].kind == argument.kind) return true;
                }
            }
            if (gridByte(world, room, row, column) != 0) return false;
        }
        return false;
    }

    var read: Cursor = .{ .strip = own };
    var cursor = read;
    for (0..steps) |_| {
        column -= 1;
        if (column < 0) {
            third -= 1;
            if (third < 0) return false;
            room = neighbor(world, room, .left) orelse return false;
            column = 15;
            cursor = read.back(32);
        } else cursor = cursor.back(1);
        read = cursor;
        if (occupants(world, cursorSlot(world, cursor))) |found| {
            var in_cell = found;
            while (in_cell.nextEntry()) |entry| {
                const seen = entry.character;
                if (seen == actor or !world.characters[seen].active) continue;
                if (world.level.characters[seen].kind == argument.kind) return true;
                cursor = .{ .placement = .{ .record = seen, .before = 0 } };
            }
        }
        if (gridByte(world, room, row, column) != 0) return false;
    }
    return false;
}

/// An awake player or enemy with health left is in the line of fire: |cells| + 1 cells along
/// the tier (positive cells: the way it faces; at most 16 + 1), before body-height terrain.
///
/// Looking left, the scan starts with its own cell, leaves the starting room one cell early
/// (its column 0 is never read), and in the next room reads contact cells two columns right
/// of the terrain cells. Looking right, it starts one cell ahead, reads a column 16 (the next
/// tier's column 0) in both the window and the grid before each room edge, and reads contact
/// cells one column ahead of the terrain cells after it.
pub fn enemyInLine(world: *World, actor: u16, cells: i16) !bool {
    const observer = world.characters[actor];
    var room = observer.room;
    if (room >= 64) return false;
    var third = windowThird(world, room) orelse return false;
    const column = unsignedColumn(observer.x);
    const tier = @divTrunc(observer.y, 72);
    if (tier < 0 or tier > 2) return false;
    const row = tier * 2 + 1;
    const toward = if (world.updating_facing_right) -%cells else cells;
    const count = @min(@abs(toward), 16);
    var counter = column;
    var strip: i32 = third * 48 + tier * 16 + column + 1;
    var terrain_column = column + 1;

    if (toward >= 0) {
        for (0..count + 1) |_| {
            counter -= 1;
            if (counter < 0) {
                third -= 1;
                if (third < 0) return false;
                room = neighbor(world, room, .left) orelse return false;
                counter = 15;
                terrain_column = 16;
                strip -= 31;
            }
            strip -= 1;
            terrain_column -= 1;
            if (combatantAt(world, actor, strip)) return true;
            if (gridByte(world, room, row, terrain_column) != 0) return false;
        }
        return false;
    }

    var remaining = count;
    while (true) {
        if (combatantAt(world, actor, strip)) return true;
        if (gridByte(world, room, row, terrain_column) != 0) return false;
        if (remaining == 0) return false;
        remaining -= 1;
        strip += 1;
        terrain_column += 1;
        counter += 1;
        if (counter == 16) {
            third += 1;
            if (third > 2) return false;
            // A missing right neighbor is not noticed; its terrain is read past the grid.
            room = world.grid.rawLink(room, .right);
            counter = 0;
            terrain_column = 0;
            strip += 32;
        }
    }
}

fn combatantAt(world: *World, actor: u16, strip: i32) bool {
    var in_cell = occupants(world, stripSlot(world, strip)) orelse return false;
    while (in_cell.nextEntry()) |entry| {
        const other = world.characters[entry.character];
        if (entry.character == actor or !other.active or other.health < 0) continue;
        const kind = world.level.characters[entry.character].kind;
        if (kind == .player or kind == .enemy) return true;
    }
    return false;
}

/// Which third of the window strip shows the room: 0 for the view room's left neighbor, 1
/// for the view room, 2 for its right neighbor.
fn windowThird(world: *const World, room: u8) ?i32 {
    if (room == world.view_room) return 1;
    if (room == world.grid.rawLink(world.view_room, .left)) return 0;
    if (room == world.grid.rawLink(world.view_room, .right)) return 2;
    return null;
}

/// Where the leftward sight scan reads its next contact cell. Normally a position of the
/// window strip. After it examines another awake character, the original keeps reading
/// backward from the start of that character's placement record: each byte below 128 is
/// taken as a contact slot (records are 32 bytes; before the first one lies the wake list,
/// see `placementByte`). A room edge then moves back 32 bytes from the last cell read.
const Cursor = union(enum) {
    strip: i32,
    placement: struct { record: u16, before: i32 },

    fn back(self: Cursor, cells: i32) Cursor {
        return switch (self) {
            .strip => |index| .{ .strip = index - cells },
            .placement => |at| .{
                .placement = .{ .record = at.record, .before = at.before + cells },
            },
        };
    }
};

fn cursorSlot(world: *World, cursor: Cursor) ?u8 {
    return switch (cursor) {
        .strip => |index| stripSlot(world, index),
        .placement => |at| {
            const byte = placementByte(world, at.record, at.before) orelse {
                world.unmodeled_reads += 1;
                return null;
            };
            return slotIn(byte);
        },
    };
}

/// The slot a strip position holds. Past the strip lie the mailboxes, one word per character,
/// zero while empty; other places are not modeled.
fn stripSlot(world: *World, index: i32) ?u8 {
    if (index >= 0 and index < strip_length) {
        return slotIn(world.contacts.window[@intCast(index)]);
    }
    const mailbox = index - strip_length;
    if (mailbox >= 0 and mailbox < 2 * 256) {
        const owner: usize = @intCast(@divTrunc(mailbox, 2));
        if (owner >= world.characters.len or world.inbox[owner] == null) return 0;
    }
    world.unmodeled_reads += 1;
    return null;
}

/// Bytes of 128 and above (including the window's empty mark) name no slot.
fn slotIn(byte: u8) ?u8 {
    return if (byte < 0x80) byte else null;
}

/// A slot's characters, if a slot is named. A slot never filled in this level holds no list
/// the engine models.
fn occupants(world: *World, named: ?u8) ?contacts.Contacts.Occupants {
    const slot = named orelse return null;
    if (world.contacts.slots[slot] == null) {
        world.unmodeled_reads += 1;
        return null;
    }
    return world.contacts.occupants(slot);
}

/// The byte `before` bytes ahead of a placement's record in the original's placement table
/// (32 bytes per placement), rebuilt from the data set. Before the first record lies the wake
/// list: a word per character, zero while it sleeps, else the address of its live record.
/// Null for bytes 2-17, which a scan of 16 cells never reaches.
fn placementByte(world: *const World, record: u16, before: i32) ?u8 {
    const position = @as(i32, record) * 32 - before;
    if (position >= 0) {
        return recordByte(world, @intCast(@divTrunc(position, 32)), @intCast(@mod(position, 32)));
    }
    const wake_list = 2 * 256 + position;
    if (wake_list < 0) return null;
    const sleeper: u16 = @intCast(@divTrunc(wake_list, 2));
    if (sleeper >= world.characters.len or !world.characters[sleeper].active) return 0;
    const live_records = 0x6ad0;
    const live_record_size = 26;
    const address: u16 = @intCast(live_records + @as(u32, sleeper) * live_record_size);
    return @truncate(if (@mod(wake_list, 2) == 0) address else address >> 8);
}

fn recordByte(world: *const World, index: u16, offset: u5) ?u8 {
    const placement = world.level.characters[index];
    const state = world.behaviorOf(index).states[placement.start].animation;
    return switch (offset) {
        0 => @truncate(state),
        1 => @truncate(state >> 8),
        18 => lowByte(placement.kind),
        19 => placement.room orelse world_module.Room.outside,
        20 => @intFromBool(placement.active),
        21 => placement.palette_bank | @as(u8, @intFromBool(placement.behind_player)) << 3 |
            placement.other_visual_flags,
        22 => placement.contact_icon,
        23 => placement.inventory_icon,
        24 => placement.object,
        25 => @backingInt(placement.minimum_difficulty),
        26 => @intFromBool(placement.facing == .right),
        27 => @as(u8, @intFromBool(placement.wakes_on_message)) |
            @as(u8, @intFromBool(placement.wakes_on_contact)) << 1 |
            @as(u8, @intFromBool(placement.wakes_when_near)) << 2 | placement.other_flags,
        28 => placement.width,
        29 => placement.unknown_byte_29,
        30 => @truncate(placement.label_number),
        31 => @truncate(placement.label_number >> 8),
        else => null,
    };
}

// Conrad's position --------------------------------------------------------------------------
//
// Tiers compare the character's y / 72 with Conrad's (y - 8) / 72.

fn tierOf(y: i16) i16 {
    return @divTrunc(y, 72);
}

fn playerTier(world: *const World) i16 {
    return @divTrunc(world.characters[0].y -% 8, 72);
}

/// Conrad is on a higher tier of the same room, or anywhere in the room above.
pub fn playerAbove(world: *World, actor: u16, _: void) !bool {
    const character = world.characters[actor];
    const player = world.characters[0];
    if (player.room == character.room) return playerTier(world) < tierOf(character.y);
    return character.room < 64 and world.grid.rawLink(character.room, .up) == player.room;
}

/// Conrad is on a lower tier of the same room, or anywhere in the room below.
pub fn playerBelow(world: *World, actor: u16, _: void) !bool {
    const character = world.characters[actor];
    const player = world.characters[0];
    if (player.room == character.room) return playerTier(world) > tierOf(character.y);
    return character.room < 64 and world.grid.rawLink(character.room, .down) == player.room;
}

/// Conrad is on this tier and ahead by more than 0 and less than `cells` cells of 16 pixels;
/// with 0, anywhere ahead in this room, or on this tier of the next room ahead.
pub fn playerAhead(world: *World, actor: u16, cells: i16) !bool {
    return playerToward(world, actor, cells, world.updating_facing_right, false);
}

/// Like `player_ahead`, behind. With 0 in the same room, a left-facing character also counts
/// Conrad at its own x as behind.
pub fn playerBehind(world: *World, actor: u16, cells: i16) !bool {
    const right = !world.updating_facing_right;
    return playerToward(world, actor, cells, right, right);
}

/// Conrad on the actor's tier toward that side. `same_x_counts`: with 0 in the same room,
/// Conrad at the actor's own x counts.
fn playerToward(world: *World, actor: u16, cells: i16, right: bool, same_x_counts: bool) bool {
    const character = world.characters[actor];
    const player = world.characters[0];
    if (playerTier(world) != tierOf(character.y)) return false;
    if (player.room != character.room) {
        if (cells != 0 or character.room >= 64) return false;
        return world.grid.rawLink(character.room, if (right) .right else .left) == player.room;
    }
    // Conrad is that way when `near < far`.
    const near = if (right) character.x else player.x;
    const far = if (right) player.x else character.x;
    if (cells == 0) return if (same_x_counts) near <= far else near < far;
    if (far <= near) return false;
    const limit: i16 = @bitCast(@as(u16, @bitCast(cells)) << 4);
    return far -% near < limit;
}

// Terrain reads -------------------------------------------------------------------------------

/// The body-row terrain `ahead` cells ahead (negative: behind), relative to the column, tier
/// and facing the character had when its update started, as terrain checks probe it.
fn sampled(world: *World, actor: u16, ahead: i16) i8 {
    const offset: i32 = if (world.updating_facing_right) ahead else -@as(i32, ahead);
    const room = world.characters[actor].room;
    return switch (world.grid.probe(room, world.band + 1, world.column + offset)) {
        .value => |v| v,
        .outside => |address| world.outsideByte(address),
    };
}

/// A grid byte read directly; rows and columns outside the room run on into the next bytes.
fn gridByte(world: *World, room: u8, row: i32, column: i32) i8 {
    return switch (world.grid.cell(room, row, column)) {
        .value => |v| v,
        .outside => |address| world.outsideByte(address),
    };
}

/// The neighbor on that side, or null where the link is negative (no room).
fn neighbor(world: *const World, room: u8, side: grid.Side) ?u8 {
    const link = world.grid.rawLink(room, side);
    return if (link >= 0x80) null else link;
}

/// The column the sight and wall scans start from: `(x + 8) >> 4` with a logical shift, so a
/// position just left of the room gives a column far to the right.
fn unsignedColumn(x: i16) i32 {
    return @as(u16, @bitCast(x +% 8)) >> 4;
}

// Tests ----------------------------------------------------------------------------------------

const testing = struct {
    const data_set = @import("../data_set.zig");
    const animations = @import("../animations.zig");

    const waits_for_front = [_]vocabulary.Rule{.{ .when = &.{.{ .hit = .from_front }}, .next = 0 }};
    const waits_for_behind_low = [_]vocabulary.Rule{.{
        .when = &.{.{ .received = .hit_behind_low }},
        .next = 0,
    }};
    const waits_unannounced = [_]vocabulary.Rule{.{
        .when = &.{.{ .hit = .from_front_unannounced }},
        .next = 0,
    }};
    const states = [_]vocabulary.State{
        .{ .name = "idle", .animation = 0, .rules = &.{} },
        .{ .name = "guarding", .animation = 0, .rules = &waits_for_front },
        .{ .name = "ducking", .animation = 0, .rules = &waits_for_behind_low },
        .{ .name = "surprised", .animation = 0, .rules = &waits_unannounced },
    };
    const behaviors = [_]vocabulary.Behavior{.{
        .name = "test",
        .links = &.{},
        .numbers = &.{"range"},
        .states = &states,
    }};
    const idle: u16 = 0;
    const guarding: u16 = 1;
    const ducking: u16 = 2;
    const surprised: u16 = 3;
    const range: vocabulary.Number = @fromBackingInt(0);

    /// Rooms 0, 1 and 2 side by side, room 3 above room 1.
    fn layout() [grid.Grid.layout_size]u8 {
        var bytes: [grid.Grid.layout_size]u8 = @splat(0);
        @memset(bytes[0..256], 0xff);
        bytes[0 * 64 + 1] = 3; // up
        bytes[1 * 64 + 3] = 1; // down
        bytes[2 * 64 + 0] = 1; // right
        bytes[2 * 64 + 1] = 2;
        bytes[3 * 64 + 1] = 0; // left
        bytes[3 * 64 + 2] = 1;
        return bytes;
    }

    /// Sets the body-row cell (row 2 * tier + 1) of a room.
    fn wall(w: *World, room: u8, tier: u8, column: u8, value: u8) void {
        w.grid.set(room, tier * 2 + 1, column, value);
    }

    fn character(kind: Kind, room: u8, column: i16, y: i16, right: bool) data_set.Character {
        return .{
            .name = "c",
            .placement = 0,
            .kind = kind,
            .behavior = 0,
            .start = idle,
            .room = room,
            .x = column * 16,
            .y = y,
            .facing = if (right) .right else .left,
            .health = 1,
            .width = 1,
            .active = true,
            .minimum_difficulty = .easy,
            .numbers = .{ 10, 0, 0, 0 },
        };
    }

    const animation_bytes = [_]u8{ 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    /// The view is Conrad's room.
    fn world(level: *const data_set.Level) !World {
        return World.init(
            std.testing.allocator,
            level,
            try animations.Animations.init(&animation_bytes),
            try grid.Grid.init(&layout()),
            .{},
        );
    }

    fn levelOf(characters: []const data_set.Character) data_set.Level {
        return .{ .behaviors = &behaviors, .characters = characters, .message_names = &.{} };
    }

    /// Registers the characters' cells in that order and builds the window, as an update does.
    fn register(w: *World, order: []const u16) !void {
        w.contacts.begin();
        for (order) |index| {
            const c = w.characters[index];
            const first = try w.contacts.register(
                &w.grid,
                index,
                c.room,
                c.x,
                c.y,
                w.level.characters[index].width,
                &w.scratch,
                w.allocator,
            );
            if (first) |slot| w.characters[index].contact = slot;
        }
        w.contacts.buildWindow(&w.grid, w.view_room);
    }

    /// What a character's update sets before its rules run.
    fn begin(w: *World, actor: u16) void {
        const c = w.characters[actor];
        w.updating_facing_right = c.facing_right;
        w.column = grid.columnOf(c.x);
        w.band = grid.bandOf(c.y);
    }

    fn look(w: *World, actor: u16, kind: Kind, cells: i16) !bool {
        begin(w, actor);
        return sees(w, actor, .{ .kind = kind, .cells = cells });
    }

    fn unhittable(w: *World, actor: u16, facing: Facing) u8 {
        return unhittableTargets(w, actor, .player, .hit_front_high, 3, facing);
    }
};

test "hit reads the side of a waiting hit" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 7, 214, true),
        testing.character(.enemy, 1, 9, 214, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    w.send(0, 1, .hit_behind_low);
    try std.testing.expect(try hit(&w, 1, .from_behind));
    try std.testing.expect(!try hit(&w, 1, .from_front));
    w.send(0, 1, .hit_front_high);
    try std.testing.expect(try hit(&w, 1, .from_front));
    try std.testing.expect(try hit(&w, 1, .from_front_unannounced));
    try std.testing.expect(!try hit(&w, 0, .from_behind));
}

test "Conrad above, below, ahead and behind" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 0, 214, true),
        testing.character(.enemy, 1, 0, 214, true),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    w.characters[0].x = 100;
    w.characters[1].x = 50;
    testing.begin(&w, 1);
    try std.testing.expect(try playerAhead(&w, 1, 0));
    try std.testing.expect(!try playerBehind(&w, 1, 0));
    try std.testing.expect(try playerAhead(&w, 1, 4)); // 50 < 64
    try std.testing.expect(!try playerAhead(&w, 1, 3)); // 50 >= 48
    try std.testing.expect(!try playerAhead(&w, 1, -1));
    // Equal x is never ahead; it is behind only for a left-facing character.
    w.characters[1].x = 100;
    try std.testing.expect(!try playerAhead(&w, 1, 0));
    try std.testing.expect(!try playerBehind(&w, 1, 0));
    w.characters[1].facing_right = false;
    testing.begin(&w, 1);
    try std.testing.expect(try playerBehind(&w, 1, 0));
    try std.testing.expect(!try playerAhead(&w, 1, 0));
    // Conrad's tier subtracts 8 from his y: 79 is tier 0 for him, tier 1 for others.
    w.characters[0].y = 79;
    w.characters[1].y = 79;
    try std.testing.expect(try playerAbove(&w, 1, {}));
    try std.testing.expect(!try playerBelow(&w, 1, {}));
    try std.testing.expect(!try playerBehind(&w, 1, 0));
    // In the next room: distance 0 only, and the tier still has to match.
    w.characters[0].y = 214;
    w.characters[1].y = 214;
    w.characters[0].room = 0;
    try std.testing.expect(try playerAhead(&w, 1, 0));
    try std.testing.expect(!try playerAhead(&w, 1, 5));
    try std.testing.expect(!try playerBehind(&w, 1, 0));
    w.characters[0].room = 3;
    try std.testing.expect(try playerAbove(&w, 1, {}));
    try std.testing.expect(!try playerBelow(&w, 1, {}));
}

test "a shot hits the first character waiting for it and is stopped by walls" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 6, 214, false),
        testing.character(@fromBackingInt(7), 1, 2, 214, true),
        testing.character(.enemy, 1, 4, 214, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    const standing: @FieldType(vocabulary.Operation, "shoot") = .{
        .height = .standing,
        .range = testing.range,
    };
    const crouched: @FieldType(vocabulary.Operation, "shoot") = .{
        .height = .crouched,
        .range = testing.range,
    };
    try testing.register(&w, &.{ 0, 1, 2 });
    w.characters[0].state = testing.guarding;
    testing.begin(&w, 1);
    // The enemy at column 4 is not waiting and is passed through; Conrad faces the shot.
    try std.testing.expect(try shoot(&w, 1, standing));
    try std.testing.expect(w.inbox[2] == null);
    var letters = w.mailbox(0);
    const letter = letters.nextLetter().?;
    try std.testing.expectEqual(Message.hit_front_high, letter.message);
    try std.testing.expectEqual(@as(u16, 1), letter.sender);
    // A low gap before Conrad stops a standing shot but not a crouched one.
    testing.wall(&w, 1, 2, 5, 2);
    try std.testing.expect(!try shoot(&w, 1, standing));
    try std.testing.expect(try shoot(&w, 1, crouched));
    letters = w.mailbox(0);
    try std.testing.expectEqual(Message.hit_front_low, letters.nextLetter().?.message);
    // Out of range (11 cells for 10).
    w.characters[0].x = 13 * 16;
    try testing.register(&w, &.{ 0, 1, 2 });
    try std.testing.expect(!try shoot(&w, 1, crouched));
    // A target that waits only for an unannounced hit is passed.
    w.characters[0].x = 6 * 16;
    try testing.register(&w, &.{ 0, 1, 2 });
    w.characters[0].state = testing.surprised;
    try std.testing.expect(!try shoot(&w, 1, crouched));
}

test "a blow behind reaches only players and enemies" {
    var characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 7, 214, false),
        testing.character(.enemy, 1, 5, 214, false),
        testing.character(@fromBackingInt(12), 1, 6, 214, false),
    };
    characters[1].numbers = .{ -2, 0, 0, 0 };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1, 2 });
    w.characters[0].state = testing.ducking;
    w.characters[2].state = testing.ducking;
    testing.begin(&w, 1);
    // A negative range looks behind. Conrad faces the same way: the hit comes from behind.
    try std.testing.expect(!try strike(&w, 1, .{ .height = .standing, .range = testing.range }));
    try std.testing.expect(try strike(&w, 1, .{ .height = .crouched, .range = testing.range }));
    try std.testing.expect(w.inbox[2] == null);
    var letters = w.mailbox(0);
    try std.testing.expectEqual(Message.hit_behind_low, letters.nextLetter().?.message);
    // A shot also reaches kind 12.
    try std.testing.expect(try shoot(&w, 1, .{ .height = .crouched, .range = testing.range }));
    letters = w.mailbox(2);
    try std.testing.expectEqual(Message.hit_behind_low, letters.nextLetter().?.message);
}

test "the line of fire includes the own cell leftward and one cell more rightward" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 7, 214, false),
        testing.character(.enemy, 1, 7, 214, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1 });
    testing.begin(&w, 1);
    try std.testing.expect(try enemyInLine(&w, 1, 0));
    w.characters[0].health = -1;
    try std.testing.expect(!try enemyInLine(&w, 1, 0));
    w.characters[0].health = 1;
    // Facing right with 1 cell: columns 8 and 9 are read.
    w.characters[1].facing_right = true;
    w.characters[0].x = 9 * 16;
    try testing.register(&w, &.{ 0, 1 });
    testing.begin(&w, 1);
    try std.testing.expect(try enemyInLine(&w, 1, 1));
    w.characters[0].x = 10 * 16;
    try testing.register(&w, &.{ 0, 1 });
    try std.testing.expect(!try enemyInLine(&w, 1, 1));
    try std.testing.expect(try enemyInLine(&w, 1, 2));
    // Terrain in column 8 ends the line there.
    testing.wall(&w, 1, 2, 8, 1);
    try std.testing.expect(!try enemyInLine(&w, 1, 4));
}

test "the line of fire leaves a room one cell early and reads two columns to the right" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 0, 15, 142, false),
        testing.character(.enemy, 1, 1, 142, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    w.view_room = 1;
    try testing.register(&w, &.{ 0, 1 });
    testing.begin(&w, 1);
    // Column 15 of the left room is checked for terrain, but its contacts are read from
    // column 1 of the tier below.
    try std.testing.expect(!try enemyInLine(&w, 1, 2));
    w.characters[0].x = 16;
    w.characters[0].y = 214;
    try testing.register(&w, &.{ 0, 1 });
    try std.testing.expect(try enemyInLine(&w, 1, 1));
}

test "sight to the right reads contacts one column beyond the terrain" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 10, 214, true),
        testing.character(.enemy, 1, 7, 214, true),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1 });
    try std.testing.expect(try testing.look(&w, 1, .player, 5));
    try std.testing.expect(try testing.look(&w, 1, .player, 2));
    try std.testing.expect(!try testing.look(&w, 1, .player, 1));
    try std.testing.expect(!try testing.look(&w, 1, .enemy, 5));
    // Conrad just beyond a one-cell wall is still seen; a wall one cell nearer hides him.
    testing.wall(&w, 1, 2, 9, 1);
    try std.testing.expect(try testing.look(&w, 1, .player, 5));
    testing.wall(&w, 1, 2, 8, 1);
    try std.testing.expect(!try testing.look(&w, 1, .player, 5));
    testing.wall(&w, 1, 2, 8, 0);
    testing.wall(&w, 1, 2, 9, 0);
    // A sleeping Conrad is not seen, nor one in the observer's own cell.
    w.characters[0].active = false;
    try std.testing.expect(!try testing.look(&w, 1, .player, 5));
    w.characters[0].active = true;
    w.characters[0].x = 7 * 16;
    try testing.register(&w, &.{ 0, 1 });
    try std.testing.expect(!try testing.look(&w, 1, .player, 5));
}

test "sight to the left continues through the placement bytes before a passed character" {
    var characters = [_]testing.data_set.Character{
        // Conrad stands behind the observer.
        testing.character(.player, 1, 14, 214, true),
        testing.character(.enemy, 1, 12, 214, false),
        testing.character(.interactive, 1, 0, 70, false),
        // An awake character in the line.
        testing.character(.interactive, 1, 10, 214, false),
    };
    characters[2].active = false;
    characters[2].label_number = 0x8180; // Both bytes name no slot.
    characters[2].unknown_byte_29 = 0; // Conrad registers first: slot 0.
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1, 2, 3 });
    // Columns 11 and 10 (the awake character), then placement 2's bytes 31 and 30 (its
    // label's text number) and 29, which names slot 0.
    try std.testing.expect(!try testing.look(&w, 1, .player, 4));
    try std.testing.expectEqual(@as(u32, 0), w.unmodeled_reads);
    try std.testing.expect(try testing.look(&w, 1, .player, 5));
    characters[2].unknown_byte_29 = 0x80;
    try std.testing.expect(!try testing.look(&w, 1, .player, 5));
    w.characters[3].active = false;
    try std.testing.expect(!try testing.look(&w, 1, .player, 5));
}

test "passing Conrad sends sight to the left into the wake list" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 10, 214, false),
        testing.character(.enemy, 1, 12, 214, false),
        // An enemy on the top tier, out of the line, whose cell registers first.
        testing.character(.enemy, 1, 3, 70, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 2, 0, 1 });
    // After Conrad at column 10 the scan reads the wake list's last word: zero, slot 0.
    try std.testing.expect(!try testing.look(&w, 1, .enemy, 2));
    try std.testing.expect(try testing.look(&w, 1, .enemy, 3));
    w.characters[0].active = false;
    try std.testing.expect(!try testing.look(&w, 1, .enemy, 3));
    try std.testing.expectEqual(@as(u32, 0), w.unmodeled_reads);
}

test "sight to the right from the right room reads Conrad's mailbox past the window" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 2, 214, true),
        testing.character(.enemy, 2, 13, 214, true),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1 });
    // With terrain column 15 comes a contact cell past the window: Conrad's empty mailbox,
    // which reads as slot 0, his own cell.
    try std.testing.expect(try testing.look(&w, 1, .player, 2));
    w.send(1, 0, @fromBackingInt(300));
    try std.testing.expect(!try testing.look(&w, 1, .player, 2));
    try std.testing.expectEqual(@as(u32, 1), w.unmodeled_reads);
}

test "targets that would not accept a hit are counted from the own cell" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 9, 214, false),
        testing.character(.enemy, 1, 7, 214, true),
        testing.character(.player, 1, 7, 214, false),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    try testing.register(&w, &.{ 0, 1, 2 });
    testing.begin(&w, 1);
    try std.testing.expectEqual(@as(u8, 2), testing.unhittable(&w, 1, .opposite));
    try std.testing.expectEqual(@as(u8, 0), testing.unhittable(&w, 1, .same));
    w.characters[0].state = testing.guarding;
    try std.testing.expectEqual(@as(u8, 1), testing.unhittable(&w, 1, .opposite));
    // Terrain ends the count after the blocking cell's characters.
    w.characters[0].state = testing.idle;
    testing.wall(&w, 1, 2, 8, 1);
    try std.testing.expectEqual(@as(u8, 1), testing.unhittable(&w, 1, .opposite));
}

test "a shot snaps to the wall ahead" {
    const characters = [_]testing.data_set.Character{
        testing.character(.player, 1, 2, 214, true),
        testing.character(@fromBackingInt(7), 1, 14, 214, true),
    };
    const level = testing.levelOf(&characters);
    var w = try testing.world(&level);
    defer w.deinit();
    w.characters[1].x = 14 * 16 + 3;
    testing.wall(&w, 2, 2, 1, 1);
    testing.begin(&w, 1);
    // The wall is in the next room; the room changes only on the step after its edge.
    try std.testing.expect(snapToWall(&w, 1, false, 4));
    try std.testing.expectEqual(@as(u8, 2), w.characters[1].room);
    try std.testing.expectEqual(@as(i16, 16), w.characters[1].x);
    // A low gap at the end of the range lets a low shot through and still reads as true.
    w.characters[1].room = 1;
    w.characters[1].x = 3 * 16;
    testing.begin(&w, 1);
    testing.wall(&w, 1, 2, 5, 2);
    try std.testing.expect(!snapToWall(&w, 1, true, 1));
    try std.testing.expect(snapToWall(&w, 1, true, 2));
    try std.testing.expectEqual(@as(i16, 3 * 16), w.characters[1].x);
    try std.testing.expect(snapToWall(&w, 1, false, 2));
    try std.testing.expectEqual(@as(i16, 5 * 16), w.characters[1].x);
}
