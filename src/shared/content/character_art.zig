//! The artwork characters show. A character's displayed frame names a sprite, either from the
//! character sprites (Conrad's PERSO file, then the monster libraries) or from the composed
//! object art. Every sprite a level's animations can show is decoded when the level loads.
const std = @import("std");
const platform = @import("../platform.zig");
const level_mod = @import("level.zig");
const sprite = @import("sprite.zig");
const object_art = @import("object_artwork.zig");
const art_bank = @import("art_bank.zig");
const actor_art = @import("actor_art.zig");
const animations = @import("../behavior/animations.zig");

pub const Key = struct { sprite: u15, composed: bool };

pub const Art = struct {
    allocator: std.mem.Allocator,
    frames: std.AutoHashMapUnmanaged(Key, sprite.Frame) = .empty,
    /// Sprites an animation names that no file holds; drawing skips them.
    missing: u32 = 0,

    pub fn deinit(self: *Art) void {
        var frames = self.frames.valueIterator();
        while (frames.next()) |frame| frame.deinit();
        self.frames.deinit(self.allocator);
    }

    pub fn get(self: *const Art, key: Key) ?*const sprite.Frame {
        return self.frames.getPtr(key);
    }
};

/// Decodes every sprite named by a frame of the level's animations.
pub fn load(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    files: level_mod.Files,
    libraries: []const actor_art.Library,
    level_animations: animations.Animations,
) !Art {
    var sprites = try source.readAll("DATA/PERSO.SPR", 1024 * 1024);
    defer sprites.deinit();
    var offsets = try source.readAll("DATA/PERSO.OFF", 32768);
    defer offsets.deinit();
    var compositions = try source.readAll("DATA/GLOBAL.SPC", 65536);
    defer compositions.deinit();
    var banks_file = try readLevel(source, files.rooms, "MBK", 65536);
    defer banks_file.deinit();
    var bindings = try readLevel(source, files.rooms, "RP", 256);
    defer bindings.deinit();
    const banks = try art_bank.Archive.init(banks_file.bytes);
    var monsters: actor_art.Catalog = .{ .source = source, .libraries = libraries };
    defer monsters.deinit();

    var art: Art = .{ .allocator = allocator };
    errdefer art.deinit();
    for (0..level_animations.count()) |id| {
        const animation = level_animations.get(@intCast(id)) catch continue;
        for (0..animation.count()) |index| {
            const number = animation.frame(index).sprite orelse continue;
            const key: Key = .{ .sprite = @intCast(number), .composed = animation.composition };
            if (art.frames.contains(key)) continue;
            var frame = (if (key.composed) object_art.fromArchive(
                allocator,
                compositions.bytes,
                bindings.bytes,
                banks,
                key.sprite,
            ) else characterSprite(
                allocator,
                sprites.bytes,
                offsets.bytes,
                &monsters,
                key.sprite,
            )) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    art.missing += 1;
                    continue;
                },
            };
            errdefer frame.deinit();
            try art.frames.put(allocator, key, frame);
        }
    }
    return art;
}

fn characterSprite(
    allocator: std.mem.Allocator,
    sprites: []const u8,
    offsets: []const u8,
    monsters: *actor_art.Catalog,
    index: u16,
) !sprite.Frame {
    return sprite.fromArchive(allocator, sprites, offsets, index) catch |err| switch (err) {
        error.MissingSprite => monsters.resolve(allocator, index),
        else => err,
    };
}

fn readLevel(
    source: platform.AssetSource,
    basename: []const u8,
    extension: []const u8,
    limit: usize,
) !platform.OwnedBytes {
    var path: [64]u8 = undefined;
    return source.readAll(
        try std.fmt.bufPrint(&path, "DATA/{s}.{s}", .{ basename, extension }),
        limit,
    );
}
