//! The original's memory, where play depends on it (PLAN D1). The engine models the game's
//! rules, not the original's machine state, except here: in these places the original reads
//! or tests memory as its data segment lays it out, and what it finds changes play. Each is
//! reproduced exactly, here and nowhere else:
//!
//! - The collision grid (`grid.Grid.bytes`): four 64-entry neighbor tables, then 64 rooms of 7
//!   rows by 16 columns, from DS:0x3d46. A read past a room's last row or column reads the next
//!   room's cells (`grid.Grid.cell`); one past the grid reads the variables that follow it,
//!   where the updating character's facing, column and tier sit (`outsideByte`). The terrain
//!   writers return a cell's address, and rules test its low byte (`addressLowByte`).
//! - The leftward sight scan: after examining another awake character, the original keeps
//!   reading backward through that character's 32-byte placement record and the wake list
//!   before the table (`placementByte`), and past the contact window into the mailboxes
//!   (`mailboxSlot`). The data set keeps `other_flags`, `unknown_byte_29` and `label_number`
//!   for these records only.
//! - Boarding: the original tests only the low byte of a carrier's live record's address
//!   (`findsCarrier`).
//!
//! Other reads of memory are not modeled: they count in `World.unmodeled_reads`, so that a run
//! that depends on one shows.
const std = @import("std");
const world_module = @import("world.zig");
const grid = @import("grid.zig");
const World = world_module.World;

// The collision grid ------------------------------------------------------------------------

/// The data-segment address of the grid's first byte.
const grid_address = 0x3d46;

/// The data-segment address of byte `offset` of the grid.
pub fn gridAddress(offset: i32) u16 {
    return @truncate(@as(u32, @bitCast(grid_address + offset)));
}

/// What a probe reads: a cell, or the byte the original finds past the grid.
pub fn read(world: *World, probe: grid.Read) i8 {
    return switch (probe) {
        .value => |v| v,
        .outside => |address| outsideByte(world, address),
    };
}

/// A byte the original reads past the grid: the updating character's facing, column and tier
/// sit there. Other addresses are counted, so a run that depends on them is visible.
pub fn outsideByte(world: *World, address: u16) i8 {
    const facing: u16 = if (world.updating_facing_right) 0xffff else 0;
    const word: ?u16 = switch (address & 0xfffe) {
        0xae26 => facing,
        0xae2a => @bitCast(world.column),
        0xae2c => @bitCast(world.band),
        else => null,
    };
    const value = word orelse {
        world.unmodeled_reads += 1;
        return 0;
    };
    const b: u8 = @truncate(if (address & 1 == 0) value else value >> 8);
    return @bitCast(b);
}

/// The position in the grid of the cell `offset` bytes into `room`'s cells, after the four
/// 64-entry neighbor tables.
pub fn roomCell(room: u8, offset: i16) i32 {
    const cells_per_room = grid.Grid.rows * grid.Grid.columns;
    return 4 * 64 + @as(i32, room) * cells_per_room + offset;
}

/// The grid's byte at `position`. The original reaches other memory outside the grid, which
/// is not modeled: such an access is counted in `unmodeled_reads` and skipped.
pub fn gridByte(world: *World, position: i32) ?*u8 {
    if (position >= 0 and position < grid.Grid.layout_size) {
        return &world.grid.bytes[@intCast(position)];
    }
    world.unmodeled_reads += 1;
    return null;
}

/// The low byte of the address of the grid's byte at `position`.
pub fn addressLowByte(position: i32) u8 {
    return @truncate(@as(u32, @bitCast(position + grid_address)));
}

// The characters' records -------------------------------------------------------------------

/// The live records: one per character, from this address.
const live_records = 0x6ad0;
const live_record_size = 26;
/// The placement records, read from the level's file: 32 bytes per character.
const placement_record_size = 32;

/// Whether the original finds `carrier` to board: it tests only the low byte of the carrier's
/// live record's address, which is zero for placements 120 and 248.
pub fn findsCarrier(carrier: u16) bool {
    const address = live_records + @as(u32, carrier) * live_record_size;
    return address & 0xff != 0;
}

/// The slot that the mailbox word at `index` bytes past the contact window names: zero while
/// the mailbox is empty. Other places are not modeled.
pub fn mailboxSlot(world: *World, index: i32) ?u8 {
    if (index >= 0 and index < 2 * 256) {
        const owner: usize = @intCast(@divTrunc(index, 2));
        if (owner >= world.characters.len or world.inbox[owner] == null) return 0;
    }
    world.unmodeled_reads += 1;
    return null;
}

/// The byte `before` bytes ahead of a placement's record in the original's placement table,
/// rebuilt from the data set. Before the first record lies the wake list: a word per character,
/// zero while it sleeps, else the address of its live record. Null for bytes 2-17, which a scan
/// of 16 cells never reaches.
pub fn placementByte(world: *const World, record: u16, before: i32) ?u8 {
    const position = @as(i32, record) * placement_record_size - before;
    if (position >= 0) {
        return recordByte(
            world,
            @intCast(@divTrunc(position, placement_record_size)),
            @intCast(@mod(position, placement_record_size)),
        );
    }
    const wake_list = 2 * 256 + position;
    if (wake_list < 0) return null;
    const sleeper: u16 = @intCast(@divTrunc(wake_list, 2));
    if (sleeper >= world.characters.len or !world.characters[sleeper].active) return 0;
    const address: u16 = @intCast(live_records + @as(u32, sleeper) * live_record_size);
    return @truncate(if (@mod(wake_list, 2) == 0) address else address >> 8);
}

fn recordByte(world: *const World, index: u16, offset: u5) ?u8 {
    const placement = world.level.characters[index];
    const state = world.behaviorOf(index).states[placement.start].animation;
    return switch (offset) {
        0 => @truncate(state),
        1 => @truncate(state >> 8),
        18 => @truncate(@as(u16, @bitCast(@backingInt(placement.kind)))),
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

test "the original misses exactly the carriers at placements 120 and 248" {
    for (0..256) |carrier| {
        const missed = carrier == 120 or carrier == 248;
        try std.testing.expectEqual(!missed, findsCarrier(@intCast(carrier)));
    }
}

test "a read past the grid lands on the variables after it" {
    // Room 1's missing right neighbor: 0x3e46 + 0xff * 0x70 + 5 * 16.
    try std.testing.expectEqual(@as(u16, 0xae26), gridAddress(4 * 64 + 0xff * 112 + 5 * 16));
}
