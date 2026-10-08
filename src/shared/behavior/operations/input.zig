//! Conrad's controls. Every character reads them, and "back" and "forward" follow the
//! reading character's facing. The controls must match exactly: another held direction or
//! button makes a check false, unless the check ignores directions.
const vocabulary = @import("../vocabulary.zig");
const World = @import("../world.zig").World;

const up = 0x01;
const down = 0x02;
const left = 0x04;
const right = 0x08;
const buttons = 0xf0;

fn held(world: *World) u8 {
    return @bitCast(world.controls);
}

fn button(which: vocabulary.Button) u8 {
    return switch (which) {
        .shift => 0x40,
        .enter => 0x10,
        .space => 0x20,
    };
}

fn forward(world: *World, actor: u16) u8 {
    return if (world.characters[actor].facing_right) right else left;
}

fn back(world: *World, actor: u16) u8 {
    return if (world.characters[actor].facing_right) left else right;
}

pub fn inputUp(world: *World, _: u16, _: void) !bool {
    return held(world) == up;
}
pub fn inputBack(world: *World, actor: u16, _: void) !bool {
    return held(world) == back(world, actor);
}
pub fn inputDown(world: *World, _: u16, _: void) !bool {
    return held(world) == down;
}
pub fn inputForward(world: *World, actor: u16, _: void) !bool {
    return held(world) == forward(world, actor);
}
pub fn inputUpAnd(world: *World, _: u16, which: vocabulary.Button) !bool {
    return held(world) == up | button(which);
}
pub fn inputBackAnd(world: *World, actor: u16, which: vocabulary.Button) !bool {
    return held(world) == back(world, actor) | button(which);
}
pub fn inputDownAnd(world: *World, _: u16, which: vocabulary.Button) !bool {
    return held(world) == down | button(which);
}
pub fn inputForwardAnd(world: *World, actor: u16, which: vocabulary.Button) !bool {
    return held(world) == forward(world, actor) | button(which);
}
pub fn inputNone(world: *World, _: u16, _: void) !bool {
    return held(world) == 0;
}

/// Exactly that button, with any directions or none.
pub fn inputButton(world: *World, _: u16, which: vocabulary.Button) !bool {
    return held(world) & buttons == button(which);
}

/// Exactly that button and no direction.
pub fn inputButtonsOnly(world: *World, _: u16, which: vocabulary.Button) !bool {
    return held(world) == button(which);
}
