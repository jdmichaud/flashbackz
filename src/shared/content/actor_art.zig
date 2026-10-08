//! Lazy sprite libraries share the animation namespace. Decoded frames remain owned by
//! the content pack; compressed archives are released as soon as import finishes.
const std = @import("std");
const platform = @import("../platform.zig");
const sprite = @import("sprite.zig");
const palette = @import("palette.zig");

pub const Library = struct { name: [12]u8, colors: palette.Bank };
const Archive = struct {
    sprites: platform.OwnedBytes,
    offsets: platform.OwnedBytes,
    fn deinit(self: *Archive) void {
        self.sprites.deinit();
        self.offsets.deinit();
    }
};
pub const Catalog = struct {
    source: platform.AssetSource,
    libraries: []const Library,
    loaded: [4]?Archive = @splat(null),

    pub fn deinit(self: *Catalog) void {
        for (&self.loaded) |*entry| if (entry.*) |*archive| archive.deinit();
    }

    pub fn resolve(self: *Catalog, allocator: std.mem.Allocator, index: u16) !sprite.Frame {
        for (self.libraries, 0..) |library, i| {
            if (i >= self.loaded.len) return error.TooManySpriteLibraries;
            if (self.loaded[i] == null) {
                const name = std.mem.sliceTo(&library.name, 0);
                var path: [64]u8 = undefined;
                var sprites = try self.source.readAll(
                    try std.fmt.bufPrint(&path, "DATA/{s}.SPR", .{name}),
                    1024 * 1024,
                );
                errdefer sprites.deinit();
                const offsets = try self.source.readAll(
                    try std.fmt.bufPrint(&path, "DATA/{s}.OFF", .{name}),
                    32768,
                );
                self.loaded[i] = .{ .sprites = sprites, .offsets = offsets };
            }
            const archive = self.loaded[i].?;
            return sprite.fromArchive(
                allocator,
                archive.sprites.bytes,
                archive.offsets.bytes,
                index,
            ) catch |err| switch (err) {
                error.MissingSprite => continue,
                else => return err,
            };
        }
        return error.MissingSprite;
    }
};
