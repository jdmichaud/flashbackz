//! Readers of the original files. File layouts stop at this boundary: the game sees images,
//! palettes, glyphs, sounds and films; the extractor sees placements, rules and texts.
const std = @import("std");

// The levels and the executable's tables.
pub const level = @import("level.zig");
pub const floppy_interface = @import("floppy_interface.zig");
pub const level_codes = @import("level_codes.zig");
pub const demo = @import("demo.zig");
pub const archive = @import("archive.zig");
pub const backward_stream = @import("backward_stream.zig");

// What the extractor reads.
pub const placement = @import("placement.zig");
pub const rule_table = @import("rule_table.zig");
pub const string_table = @import("string_table.zig");
pub const world_messages = @import("world_messages.zig");

// Images.
pub const level_pack = @import("level_pack.zig");
pub const room_source = @import("room_source.zig");
pub const room_artwork = @import("room_artwork.zig");
pub const floppy_rooms = @import("floppy_rooms.zig");
pub const character_art = @import("character_art.zig");
pub const sprite = @import("sprite.zig");
pub const art_bank = @import("art_bank.zig");
pub const object_artwork = @import("object_artwork.zig");
pub const bitmap = @import("bitmap.zig");
pub const palette = @import("palette.zig");
pub const font = @import("font.zig");
pub const inventory_artwork = @import("inventory_artwork.zig");
pub const menu_artwork = @import("menu_artwork.zig");
pub const continue_artwork = @import("continue_artwork.zig");

// Films and sound.
pub const vector_cinematic = @import("vector_cinematic.zig");
pub const cinematic_text = @import("cinematic_text.zig");
pub const cinematic_transform = @import("cinematic_transform.zig");
pub const music = @import("music.zig");
pub const sound_effects = @import("sound_effects.zig");

test {
    std.testing.refAllDecls(@This());
}
