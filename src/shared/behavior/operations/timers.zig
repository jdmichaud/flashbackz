//! A character's counter, its health (which items use as a charge), purses and chance.
const vocabulary = @import("../vocabulary.zig");
const World = @import("../world.zig").World;

pub fn setTimer(world: *World, actor: u16, steps: i16) !bool {
    world.characters[actor].counter = steps;
    return true;
}

/// Counts down by one each time it is checked, true exactly when the count reaches `value`.
pub fn timerReaches(world: *World, actor: u16, value: i16) !bool {
    const character = &world.characters[actor];
    character.counter -%= 1;
    return character.counter == value;
}

pub fn setTimerFrom(world: *World, actor: u16, number: vocabulary.Number) !bool {
    world.characters[actor].counter = world.number(actor, number);
    return true;
}

/// Health at or below zero. An enemy found defeated adds 100 points each time.
pub fn defeated(world: *World, actor: u16, _: void) !bool {
    if (world.characters[actor].health > 0) return false;
    if (world.level.characters[actor].kind == .enemy) world.score +%= 100;
    return true;
}

pub fn setCharge(world: *World, actor: u16, value: i16) !bool {
    world.characters[actor].health = value;
    return true;
}

pub fn addCharge(world: *World, actor: u16, amount: i16) !bool {
    world.characters[actor].health +%= amount;
    return true;
}

pub fn copyHealthTo(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "copy_health_to"),
) !bool {
    world.characters[@backingInt(argument.character)].health = world.number(actor, argument.health);
    return true;
}

pub fn mirrorHealth(world: *World, actor: u16, source: vocabulary.Character) !bool {
    world.characters[actor].health = world.characters[@backingInt(source)].health -% 1;
    return true;
}

pub fn credit(
    world: *World,
    actor: u16,
    argument: @FieldType(vocabulary.Operation, "credit"),
) !bool {
    const purse = world.link(actor, argument.purse) orelse return true;
    world.characters[purse].health +%= world.number(actor, argument.amount);
    return true;
}

pub fn debit(world: *World, actor: u16, argument: @FieldType(vocabulary.Operation, "debit")) !bool {
    const purse = world.link(actor, argument.purse) orelse return true;
    world.characters[purse].health -%= world.number(actor, argument.amount);
    return true;
}

/// One random draw, true when the drawn value (read as signed) is divisible by `one_in`.
/// Zero never draws.
pub fn chance(world: *World, _: u16, one_in: i16) !bool {
    if (one_in == 0) return false;
    const value: i16 = @bitCast(world.random.next());
    return @rem(value, one_in) == 0;
}
