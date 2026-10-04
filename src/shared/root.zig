//! The shared module: the platform boundary, the in-memory providers and the game. It links
//! nothing and needs no libc; native presentation and headless verification use the same game.
pub const music_player = @import("audio/music_player.zig");
pub const score = @import("audio/score.zig");
pub const opl = @import("audio/opl.zig");
pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const version = @import("version.zig");
pub const content = @import("content/root.zig");
pub const floppy = @import("floppy.zig");
pub const asset_pack = @import("asset_pack.zig");
pub const menu = @import("scenes/menu.zig");
pub const vector_player = @import("scenes/vector_player.zig");
pub const vector_film = @import("vector_film.zig");
pub const indexed_shapes = @import("render/indexed_shapes.zig");
pub const sprite_renderer = @import("render/sprite.zig");
pub const motion = @import("motion.zig");
pub const identity = @import("identity.zig");
pub const inventory = @import("inventory.zig");
pub const equipment = @import("equipment.zig");
pub const inventory_menu = @import("scenes/inventory_menu.zig");
pub const continue_game = @import("scenes/continue_game.zig");
pub const front_end = @import("scenes/front_end.zig");
pub const settings = @import("settings.zig");
pub const conrad_ledge = @import("actors/conrad_ledge.zig");
pub const conrad_fall = @import("actors/conrad_fall.zig");
pub const conrad_recoil = @import("actors/conrad_recoil.zig");
pub const conrad_roll = @import("actors/conrad_roll.zig");
pub const conrad = @import("actors/conrad.zig");
pub const geometry = @import("geometry.zig");
pub const terrain = @import("terrain.zig");
pub const conrad_environment = @import("actors/conrad_environment.zig");
pub const step_clock = @import("step_clock.zig");
pub const jungle_scene = @import("scenes/jungle.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;

test {
    @import("std").testing.refAllDecls(@This());
}
