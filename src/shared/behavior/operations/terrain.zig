//! Terrain around the character. Every check reads cells relative to the character's column
//! and band at the start of its update (`World.column`, `World.band`). The band is the row
//! index of the tier's top row. Rows from the band: 0 is the ceiling slab, 1 the body layer,
//! 2 the floor the character stands on, 4 the floor of the tier below, -1 the body layer of
//! the tier above. "Ahead" follows the character's current facing, not the facing at the
//! start of the update that perception uses. Any nonzero cell is solid.
const world_module = @import("../world.zig");
const original_memory = @import("../original_memory.zig");
const World = world_module.World;

/// The cell on `row` of the character's tier, `ahead` columns ahead (negative: behind).
pub fn cell(world: *World, actor: u16, row: i16, ahead: i16) i8 {
    const character = world.characters[actor];
    const column = world.column + if (character.facing_right) ahead else -ahead;
    return original_memory.read(world, world.grid.probe(character.room, world.band + row, column));
}

fn solid(world: *World, actor: u16, row: i16, ahead: i16) bool {
    return cell(world, actor, row, ahead) != 0;
}

const ceiling = 0;
const body = 1;
const floor = 2;
const body_above = -1;
const floor_below = 4;

pub fn ceilingAhead(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, ceiling, cells);
}
pub fn ceilingHere(world: *World, actor: u16, _: void) !bool {
    return solid(world, actor, ceiling, 0);
}
pub fn ceilingBehind(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, ceiling, -cells);
}
pub fn wallAhead(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, body, cells);
}
pub fn wallHere(world: *World, actor: u16, _: void) !bool {
    return solid(world, actor, body, 0);
}
pub fn wallBehind(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, body, -cells);
}
pub fn floorAhead(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, floor, cells);
}
pub fn floorHere(world: *World, actor: u16, _: void) !bool {
    return solid(world, actor, floor, 0);
}
pub fn floorBehind(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, floor, -cells);
}
pub fn noCeilingAhead(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, ceiling, cells);
}
pub fn noCeilingHere(world: *World, actor: u16, _: void) !bool {
    return !solid(world, actor, ceiling, 0);
}
pub fn noCeilingBehind(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, ceiling, -cells);
}
pub fn noWallAhead(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, body, cells);
}
pub fn noWallHere(world: *World, actor: u16, _: void) !bool {
    return !solid(world, actor, body, 0);
}
pub fn noWallBehind(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, body, -cells);
}
pub fn noFloorAhead(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, floor, cells);
}
pub fn noFloorHere(world: *World, actor: u16, _: void) !bool {
    return !solid(world, actor, floor, 0);
}
pub fn noFloorBehind(world: *World, actor: u16, cells: i16) !bool {
    return !solid(world, actor, floor, -cells);
}

/// A solid ceiling cell with the opening just behind it and room to stand on top.
pub fn ledgeAboveBehind(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, ceiling, k) and
        !solid(world, actor, ceiling, k - 1) and
        !solid(world, actor, body_above, k);
}

/// A solid ceiling cell with the opening just beyond it and room to stand on top.
pub fn ledgeAboveAhead(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, ceiling, k) and
        !solid(world, actor, ceiling, k + 1) and
        !solid(world, actor, body_above, k);
}

/// A floor cell whose near side is a hole, with clear body space above it.
pub fn floorEdgeBehind(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, floor, k) and
        !solid(world, actor, floor, k - 1) and
        !solid(world, actor, body, k);
}

/// A floor cell with a hole just beyond it and clear body space above it.
pub fn floorEdgeAhead(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, floor, k) and
        !solid(world, actor, floor, k + 1) and
        !solid(world, actor, body, k);
}

/// A hole, then a floor edge just beyond it: the ledge to grab ahead.
pub fn grabEdgeAhead(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, floor, k + 1) and
        !solid(world, actor, floor, k) and
        !solid(world, actor, body, k + 1);
}

/// A wall one cell beyond a gap in the floor `k` cells ahead.
pub fn wallBeyondGap(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, body, k + 1) and !solid(world, actor, floor, k);
}

/// The body layer is clear `k` cells ahead and solid in the next.
pub fn wallStarts(world: *World, actor: u16, k: i16) !bool {
    return solid(world, actor, body, k + 1) and !solid(world, actor, body, k);
}

/// The body layer is solid `k` cells ahead and clear in the next.
pub fn wallEnds(world: *World, actor: u16, k: i16) !bool {
    return !solid(world, actor, body, k + 1) and solid(world, actor, body, k);
}

/// Material 2 in the body layer: a passage only a rolling character fits through.
pub fn lowPassageAhead(world: *World, actor: u16, cells: i16) !bool {
    return cell(world, actor, body, cells) & 2 != 0;
}

pub fn floorBelowAhead(world: *World, actor: u16, cells: i16) !bool {
    return solid(world, actor, floor_below, cells);
}

/// The body cell ahead is free and the floor one cell further on exists.
pub fn stepClearAhead(world: *World, actor: u16, cells: i16) !bool {
    if (solid(world, actor, body, cells)) return false;
    return solid(world, actor, floor, cells + 1);
}

/// Shift held (any direction, no other button) with no floor that many cells ahead.
pub fn shiftOverGap(world: *World, actor: u16, cells: i16) !bool {
    const controls: u8 = @bitCast(world.controls);
    if (controls & 0xf0 != 0x40) return false;
    return !solid(world, actor, floor, cells);
}
