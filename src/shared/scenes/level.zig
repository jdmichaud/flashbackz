//! A level run entirely by the behavior engine (DESIGN.md section 4): every character, Conrad
//! included, follows its behavior table, and the screen shows the engine's state.
const std = @import("std");
const behavior = @import("../behavior/root.zig");
const level_pack = @import("../content/level_pack.zig");
const character_art = @import("../content/character_art.zig");
const artwork = @import("../content/room_artwork.zig");
const palette = @import("../content/palette.zig");
const sprite_renderer = @import("../render/sprite.zig");
const World = behavior.world.World;

pub const width = 256;
pub const height = 224;

/// The playfield for the engine's current state: the view room and the characters in it.
/// `rgba` is optional for callers that only need color indices.
pub fn drawPlayfield(
    pack: *const level_pack.Pack,
    world: *const World,
    indices: []u8,
    rgba: ?[]u8,
) !void {
    if (indices.len != width * height) return error.InvalidFrameLength;
    const room = pack.room(world.view_room) orelse {
        @memset(indices, 0);
        if (rgba) |out| @memset(out, 0);
        return;
    };
    @memcpy(indices, room.image.pixels);
    var next = world.room_lists[world.view_room];
    while (next) |index| : (next = world.characters[index].next_in_room) {
        try drawCharacter(pack, world, room, index, indices);
    }
    if (rgba) |out| try palette.writeRgba(indices, &room.colors, out);
}

fn drawCharacter(
    pack: *const level_pack.Pack,
    world: *const World,
    room: *const artwork.Artwork,
    index: u16,
    indices: []u8,
) !void {
    const character = world.characters[index];
    const definition = world.level.characters[index];
    const look = character.look;
    const frame = pack.characters.get(.{ .sprite = look.sprite, .composed = look.composed }) orelse
        return;
    const bank: u4 = if (definition.kind == .player) 4 else @intCast(definition.palette_bank & 3);
    try sprite_renderer.draw(
        indices,
        width,
        height,
        frame,
        @as(i32, character.x) + 8,
        @as(i32, character.y) + 2,
        .{
            .palette_bank = bank,
            .facing = if (look.mirrored) .mirrored else .original,
            .occlusion = room.foreground,
        },
    );
}
