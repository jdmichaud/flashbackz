//! Room artwork from the original files: the installed MAP file, or the floppy's compact LEV,
//! BNQ and SGD files. Rooms decode one at a time with the level's colors.
const std = @import("std");
const platform = @import("../platform.zig");
const level_mod = @import("level.zig");
const artwork = @import("room_artwork.zig");
const floppy_rooms = @import("floppy_rooms.zig");

pub const RoomSource = union(enum) {
    installed: platform.OwnedBytes,
    compact: struct {
        rooms: platform.OwnedBytes,
        tiles: platform.OwnedBytes,
        background: ?platform.OwnedBytes,
        tile_bias: u16,
    },
    pub fn open(source: platform.AssetSource, files: level_mod.Files) !RoomSource {
        if (readLevel(
            source,
            files.rooms,
            "MAP",
            8 * 1024 * 1024,
        )) |file| {
            return .{ .installed = file };
        } else |err| if (err != error.NotFound) {
            return err;
        }
        var rooms = try readLevel(source, files.rooms, "LEV", 1024 * 1024);
        errdefer rooms.deinit();
        var tiles = try readLevel(source, files.rooms, "BNQ", 1024 * 1024);
        errdefer tiles.deinit();
        return .{
            .compact = .{
                .rooms = rooms,
                .tiles = tiles,
                .background = if (files.tile_bias != 0)
                    try readLevel(source, files.rooms, "SGD", 1024 * 1024)
                else
                    null,
                .tile_bias = files.tile_bias,
            },
        };
    }
    pub fn deinit(self: *RoomSource) void {
        switch (self.*) {
            .installed => |*file| file.deinit(),
            .compact => |*files| {
                files.rooms.deinit();
                files.tiles.deinit();
                if (files.background) |*background| {
                    background.deinit();
                }
            },
        }
    }
    pub fn decode(
        self: *const RoomSource,
        allocator: std.mem.Allocator,
        colors: []const u8,
        room: u8,
    ) !artwork.Artwork {
        return switch (self.*) {
            .installed => |file| artwork.decode(allocator, file.bytes, colors, room),
            .compact => |files| (floppy_rooms.Archive{
                .rooms = files.rooms.bytes,
                .banks = files.tiles.bytes,
                .background = if (files.background) |background| background.bytes else &.{},
                .tile_bias = files.tile_bias,
            }).decode(allocator, colors, room),
        };
    }
};

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
