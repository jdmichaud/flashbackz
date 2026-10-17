//! Messages between characters. A message waits in the recipient's mailbox until the end of
//! the recipient's next update.
const vocabulary = @import("../vocabulary.zig");
const World = @import("../world.zig").World;

/// A message with that value is waiting, from any sender.
pub fn received(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var letters = world.mailbox(actor);
    while (letters.nextLetter()) |letter| {
        if (letter.message == message) return true;
    }
    return false;
}

/// Send to the character a link names. True even when the message is dropped.
pub fn send(world: *World, actor: u16, argument: @FieldType(vocabulary.Operation, "send")) !bool {
    const recipient = world.link(actor, argument.to) orelse return true;
    world.send(actor, recipient, argument.message);
    return true;
}

pub fn sendToSelectedItem(world: *World, actor: u16, message: vocabulary.Message) !bool {
    const item = world.characters[actor].first_item orelse return true;
    world.send(actor, item, message);
    return true;
}

/// Reply `acknowledged` to the sender of the first waiting message with that value.
pub fn acknowledge(world: *World, actor: u16, message: vocabulary.Message) !bool {
    var letters = world.mailbox(actor);
    while (letters.nextLetter()) |letter| {
        if (letter.message == message) {
            world.send(actor, letter.sender, .acknowledged);
            return true;
        }
    }
    return false;
}
