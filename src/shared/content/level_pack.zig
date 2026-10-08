//! What a level needs from the original files besides its data set: room artwork with each
//! room's colors, the artwork characters show, the animations and the collision grid.
const std = @import("std");
const platform = @import("../platform.zig");
const level_mod = @import("level.zig");
const artwork = @import("room_artwork.zig");
const palette = @import("palette.zig");
const floppy_interface = @import("floppy_interface.zig");
const backward_stream = @import("backward_stream.zig");
const character_art = @import("character_art.zig");
const sprite = @import("sprite.zig");
const font_mod = @import("font.zig");
const settings = @import("../settings.zig");
const RoomSource = @import("room_source.zig").RoomSource;
const behavior = @import("../behavior/root.zig");

pub const room_count = 64;

pub const Pack = struct {
    allocator: std.mem.Allocator,
    /// Rooms the level does not use are null.
    rooms: [room_count]?artwork.Artwork,
    characters: character_art.Art,
    /// The animation file; `animations` reads it in place.
    animation_file: platform.OwnedBytes,
    animations: behavior.animations.Animations,
    grid: behavior.grid.Grid,
    /// Item icons, for the HUD and the touch label.
    icons: []sprite.Frame,
    font: font_mod.Font,
    /// The enemy sprite libraries' colors, in `SpriteLibrary` order.
    library_colors: [4]palette.Bank,
    /// "CODE: " and the level's password at the chosen difficulty.
    password: [13]u8,

    pub fn deinit(self: *Pack) void {
        for (&self.rooms) |*slot| if (slot.*) |*art| art.deinit();
        self.characters.deinit();
        self.animation_file.deinit();
        for (self.icons) |*icon| icon.deinit();
        self.allocator.free(self.icons);
        self.font.deinit();
    }

    pub fn room(self: *const Pack, id: u8) ?*const artwork.Artwork {
        if (id >= room_count) return null;
        if (self.rooms[id]) |*art| return art;
        return null;
    }
};

/// Loads level `id`. `first_room` is where Conrad starts: its colors are the level's reference
/// for the actor and icon color blocks.
pub fn load(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    interface: *const floppy_interface.Values,
    id: level_mod.Id,
    difficulty: settings.Difficulty,
    first_room: u8,
) !Pack {
    const files = level_mod.files(id);
    var animation_file = try readLevel(source, files.actors, "ANI", 1 << 20);
    errdefer animation_file.deinit();
    const animations = try behavior.animations.Animations.init(animation_file.bytes);
    var collision_file = try readLevel(source, files.rooms, "CT", 65536);
    defer collision_file.deinit();
    const layout = try backward_stream.decode(
        allocator,
        collision_file.bytes,
        behavior.grid.Grid.layout_size,
    );
    defer allocator.free(layout);
    const grid = try behavior.grid.Grid.init(layout);

    var characters = try character_art.load(
        allocator,
        source,
        files,
        &interface.actor_libraries,
        animations,
    );
    errdefer characters.deinit();

    var rooms: [room_count]?artwork.Artwork = @splat(null);
    errdefer for (&rooms) |*r| if (r.*) |*art| art.deinit();
    try loadRooms(allocator, source, interface, files, first_room, &rooms);

    const icons = try loadIcons(allocator, source);
    errdefer {
        for (icons) |*icon| icon.deinit();
        allocator.free(icons);
    }
    var font_file = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer font_file.deinit();
    var font = try font_mod.decode(allocator, font_file.bytes);
    errdefer font.deinit();
    var library_colors: [4]palette.Bank = undefined;
    for (&library_colors, interface.actor_libraries) |*colors, library| colors.* = library.colors;
    var password: [13]u8 = undefined;
    @memcpy(password[0..6], &interface.password_prefix);
    @memcpy(password[6..], &interface.passwords[@backingInt(id)][@backingInt(difficulty)]);
    return .{
        .allocator = allocator,
        .rooms = rooms,
        .characters = characters,
        .animation_file = animation_file,
        .animations = animations,
        .grid = grid,
        .icons = icons,
        .font = font,
        .library_colors = library_colors,
        .password = password,
    };
}

fn loadIcons(allocator: std.mem.Allocator, source: platform.AssetSource) ![]sprite.Frame {
    var file = try source.readAll("DATA/GLOBAL.ICN", 32768);
    defer file.deinit();
    const count = std.mem.readInt(u16, file.bytes[0..2], .little) / 2;
    var icons: std.ArrayList(sprite.Frame) = .empty;
    errdefer {
        for (icons.items) |*icon| icon.deinit();
        icons.deinit(allocator);
    }
    for (0..count) |index| {
        var icon = try sprite.fromIcons(allocator, file.bytes, @intCast(index));
        errdefer icon.deinit();
        try icons.append(allocator, icon);
    }
    return icons.toOwnedSlice(allocator);
}

/// Each room's 256 colors: its own background blocks, then the shared blocks for actors
/// (0x40), icons (0xa0), text (0xe0) and the interface (0xf0).
fn loadRooms(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    interface: *const floppy_interface.Values,
    files: level_mod.Files,
    first_room: u8,
    rooms: *[room_count]?artwork.Artwork,
) !void {
    var room_files = try RoomSource.open(source, files);
    defer room_files.deinit();
    var colors = try readLevel(source, files.rooms, "PAL", 8192);
    defer colors.deinit();
    const reference_bank = reference: {
        var first = try room_files.decode(allocator, colors.bytes, first_room);
        defer first.deinit();
        break :reference first.palette_banks[2];
    };
    const icon_colors = try palette.decodeLevelBank(colors.bytes, reference_bank);
    for (rooms, 0..) |*slot, index| {
        var art = room_files.decode(allocator, colors.bytes, @intCast(index)) catch |err| switch (err) {
            error.AbsentRoom => continue,
            else => return err,
        };
        errdefer art.deinit();
        const alternate = art.palette_banks[2] != reference_bank;
        @memcpy(art.colors[0x40..0x50], &interface.actor_colors[@intFromBool(alternate)]);
        @memcpy(art.colors[0xa0..0xb0], &icon_colors);
        @memcpy(art.colors[0xe0..0xf0], &interface.text_colors);
        @memcpy(art.colors[0xf0..0x100], &interface.interface_colors);
        slot.* = art;
    }
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
