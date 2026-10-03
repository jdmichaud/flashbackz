//! The shared module: the platform boundary, the in-memory providers and the game. It links
//! nothing and needs no libc, so the same code builds for the native hosts and for the browser
//! (wasm32-freestanding).
pub const platform = @import("platform.zig");
pub const memory = @import("memory.zig");
pub const version = @import("version.zig");
pub const content = @import("content/root.zig");
pub const iso = @import("iso.zig");
pub const cd_track = @import("cd_track.zig");
pub const menu = @import("scenes/menu.zig");
pub const sprite_renderer = @import("render/sprite.zig");
pub const motion = @import("motion.zig");
pub const conrad = @import("actors/conrad.zig");
pub const geometry = @import("geometry.zig");
pub const conrad_environment = @import("actors/conrad_environment.zig");
pub const game = @import("game.zig");
pub const Game = game.Game;

test {
    @import("std").testing.refAllDecls(@This());
}
