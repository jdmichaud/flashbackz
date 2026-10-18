//! The shared module: the game without a host. It links nothing and needs no libc. The SDL host
//! and the headless agent host run the same game.
//!
//! How the parts join, from the outside in:
//! - A host gives a `platform.Platform` and calls `Game.update` (`game.zig`).
//! - `Game` owns the scene in play (`scenes/`). It starts the next scene when one ends.
//! - A level scene (`scenes/level.zig`) runs the world (`behavior/world.zig`). The world runs
//!   the characters' rule tables from the data set (`behavior/data_set.zig`).
//! - The scenes read the original's files with `content/` and draw with `render/`.
//! - `audio/output.zig` mixes the music and the effects of the scene for the host.
const std = @import("std");

pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const version = @import("version.zig");
pub const floppy = @import("floppy.zig");
pub const asset_pack = @import("asset_pack.zig");
pub const settings = @import("settings.zig");
pub const save = @import("save.zig");
pub const random = @import("random.zig");
pub const step_clock = @import("step_clock.zig");
pub const key_latch = @import("key_latch.zig");
pub const input = @import("input.zig");

// What the game is made of: the original files' content, the behavior engine and the scenes.
pub const content = @import("content/root.zig");
pub const behavior = @import("behavior/root.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;
pub const level_scene = @import("scenes/level.zig");
pub const ending = @import("scenes/ending.zig");
pub const front_end = @import("scenes/front_end.zig");
pub const menu = @import("scenes/menu.zig");
pub const continue_game = @import("scenes/continue_game.zig");
pub const inventory_menu = @import("scenes/inventory_menu.zig");
pub const save_slots = @import("scenes/save_slots.zig");
pub const vector_player = @import("scenes/vector_player.zig");
pub const vector_film = @import("vector_film.zig");
pub const pad_notice = @import("pad_notice.zig");
pub const info_overlay = @import("info_overlay.zig");

// Drawing and sound.
pub const indexed_shapes = @import("render/indexed_shapes.zig");
pub const sprite_renderer = @import("render/sprite.zig");
pub const rgba_text = @import("render/rgba_text.zig");
pub const music_player = @import("audio/music_player.zig");
pub const score = @import("content/score.zig");
pub const opl = @import("audio/opl.zig");
pub const sound_effects_player = @import("audio/effects.zig");
pub const audio_output = @import("audio/output.zig");
pub const soundtrack = @import("audio/soundtrack.zig");
pub const megadrive = @import("audio/megadrive/root.zig");
pub const megadrive_tunes = @import("audio/megadrive_tunes.zig");

test {
    std.testing.refAllDecls(@This());
}
