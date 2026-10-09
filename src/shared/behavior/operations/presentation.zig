//! Requests to the rest of the game: films, world messages, sounds, level exits and the
//! screen shake, plus the shared weapon mode.
const vocabulary = @import("../vocabulary.zig");
const World = @import("../world.zig").World;

/// Ignored while a defeat countdown runs.
pub fn playScene(world: *World, _: u16, scene: i16) !bool {
    if (world.defeat_countdown & 0xff == 0) world.requests.scene = scene;
    return true;
}

pub fn showMessage(world: *World, _: u16, message: i16) !bool {
    world.requests.world_message = message;
    return true;
}

/// Plays the sound wherever the character is, awake or not.
pub fn playSound(world: *World, actor: u16, sound: i16) !bool {
    world.playSoundAnywhere(actor, sound);
    return true;
}

/// Plays the sound a placement number names, wherever the character is.
pub fn playSoundFrom(world: *World, actor: u16, number: vocabulary.Number) !bool {
    world.playSoundAnywhere(actor, world.number(actor, number));
    return true;
}

/// The level (counted from 1) loads after this update. The original's result is the low
/// byte of the level index, so level 1 reads as false even though it is requested.
pub fn exitLevel(world: *World, _: u16, level: i16) !bool {
    const index: u8 = @truncate(@as(u16, @bitCast(level -% 1)));
    world.requests.level = index;
    return index != 0;
}

/// One random draw picks the view's vertical offset; it stays until the game sets it again.
pub fn shakeScreen(world: *World, _: u16, _: void) !bool {
    world.shake = @as(i8, @intCast(world.random.next() & 3)) - 1;
    return true;
}

pub fn setWeaponMode(world: *World, _: u16, value: i16) !bool {
    world.weapon_mode = value;
    return true;
}

pub fn weaponModeIs(world: *World, _: u16, value: i16) !bool {
    return world.weapon_mode == value;
}

pub fn startDefeat(world: *World, _: u16, steps: i16) !bool {
    if (world.defeat_countdown == 0) world.defeat_countdown = steps;
    return true;
}

pub fn startDefeatWithScene(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "start_defeat_with_scene"),
) !bool {
    if (world.defeat_countdown != 0) return true;
    world.defeat_countdown = world.number(actor, argument.delay) +% 1;
    world.defeat_scene = argument.scene;
    return true;
}
