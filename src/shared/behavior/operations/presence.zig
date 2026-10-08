//! Whether a character is in the world, on screen and awake.
const vocabulary = @import("../vocabulary.zig");
const world_module = @import("../world.zig");
const World = world_module.World;
const Room = world_module.Room;

pub fn inView(world: *World, actor: u16, _: void) !bool {
    return world.characters[actor].room == world.view_room;
}

pub fn outOfView(world: *World, actor: u16, _: void) !bool {
    return world.characters[actor].room != world.view_room;
}

/// Stays awake only if it wakes when near and is in or beside the view room. Either way the
/// animation this update starts plays without its entry sound.
pub fn sleepUnlessNearPlayer(world: *World, actor: u16, _: void) !bool {
    world.entry_sound = false;
    const room = world.characters[actor].room;
    const wakes = world.level.characters[actor].wakes_when_near;
    // The original's tests for rooms past 127 never trigger, so such a room is compared
    // with the neighbor links, where a missing link (0xff) matches room 0xff.
    const near = room == world.view_room or for (std.enums.values(grid.Side)) |side| {
        if (world.grid.rawLink(world.view_room, side) == room) break true;
    } else false;
    if (!(wakes and near and (room < 0x40 or room >= 0x80))) world.deactivate(actor);
    return true;
}

/// Leaves the world; an enemy awards 200 points.
pub fn remove(world: *World, actor: u16, _: void) !bool {
    world.characters[actor].room = Room.removed;
    world.deactivate(actor);
    if (world.level.characters[actor].kind == .enemy) world.score +%= 200;
    return true;
}

/// An item leaves the world and the inventory of `owner`, if it is there. No points.
pub fn useUp(world: *World, actor: u16, owner: vocabulary.Character) !bool {
    world.characters[actor].room = Room.removed;
    world.deactivate(actor);
    world.unlinkItem(@backingInt(owner), actor);
    return true;
}

/// Moves to the room a placement number names and shows its current frame. Revealing Conrad
/// moves the view after the update.
pub fn reveal(world: *World, actor: u16, number: vocabulary.Number) !bool {
    world.characters[actor].room = @truncate(@as(u16, @bitCast(world.number(actor, number))));
    if (world.level.characters[actor].kind == .player) world.view_dirty = true;
    world.showFrame(actor) catch return error.InvalidAnimation;
    return true;
}

const std = @import("std");
const grid = @import("../grid.zig");
