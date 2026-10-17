//! What a level needs from the original files besides its data set: room artwork with each
//! room's colors, the artwork characters show, the animations and the collision grid.
const std = @import("std");
const platform = @import("../platform.zig");
const level_mod = @import("level.zig");
const artwork = @import("room_artwork.zig");
const palette = @import("palette.zig");
const floppy_interface = @import("floppy_interface.zig");
const character_art = @import("character_art.zig");
const sprite = @import("sprite.zig");
const font_mod = @import("font.zig");
const sound_effects = @import("sound_effects.zig");
const inventory_artwork = @import("inventory_artwork.zig");
const settings = @import("../settings.zig");
const RoomSource = @import("room_source.zig").RoomSource;
const animations_mod = @import("animations.zig");
const collision = @import("collision.zig");

pub const room_count = 64;

/// The content of one level. The level scene owns the pack. The world keeps a copy of
/// `animations`, which reads `animation_file` in place, so the pack must outlive the world.
pub const Pack = struct {
    allocator: std.mem.Allocator,
    /// Rooms the level does not use are null.
    rooms: [room_count]?artwork.Artwork,
    characters: character_art.Art,
    /// The animation file; `animations` reads it in place.
    animation_file: platform.OwnedBytes,
    animations: animations_mod.Animations,
    /// The terrain: each room's neighbors and cells.
    collision: collision.Bytes,
    /// Item icons, for the HUD and the touch label.
    icons: []sprite.Frame,
    font: font_mod.Font,
    /// The enemy sprite libraries' colors, in `SpriteLibrary` order.
    library_colors: [4]palette.Bank,
    /// "CODE: " and the level's password at the chosen difficulty.
    password: [13]u8,
    sounds: sound_effects.Bank,
    /// The inventory screen's panel, page arrows, marker and font.
    inventory: inventory_artwork.Assets,

    pub fn deinit(self: *Pack) void {
        for (&self.rooms) |*slot| {
            if (slot.*) |*art| {
                art.deinit();
            }
        }
        self.characters.deinit();
        self.animation_file.deinit();
        for (self.icons) |*icon| {
            icon.deinit();
        }
        self.allocator.free(self.icons);
        self.font.deinit();
        self.sounds.deinit();
        self.inventory.deinit();
    }

    pub fn room(self: *const Pack, id: u8) ?*const artwork.Artwork {
        if (id >= room_count) return null;
        if (self.rooms[id]) |*art| return art;
        return null;
    }
};

/// Loads level `id`. `first_room` is where Conrad starts: its colors are the level's reference
/// for the actor and icon color blocks. The steps, in order:
/// 1. the animations (ANI) and the collision grid (CT);
/// 2. the character art (`character_art.load`);
/// 3. the rooms and their colors (`loadRooms`);
/// 4. the item icons (GLOBAL.ICN) and the font (FB_TXT.FNT);
/// 5. the inventory art, from the icon and font bytes;
/// 6. the library colors and the password, from `interface`;
/// 7. the sound effects (GLOBAL.FIB).
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
    const animations = try animations_mod.Animations.init(animation_file.bytes);
    var collision_file = try readLevel(source, files.rooms, "CT", 65536);
    defer collision_file.deinit();
    const terrain = try collision.decode(allocator, collision_file.bytes);

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

    var icon_file = try source.readAll("DATA/GLOBAL.ICN", 32768);
    defer icon_file.deinit();
    const icons = try loadIcons(allocator, icon_file.bytes);
    errdefer {
        for (icons) |*icon| {
            icon.deinit();
        }
        allocator.free(icons);
    }
    var font_file = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer font_file.deinit();
    var font = try font_mod.decode(allocator, font_file.bytes);
    errdefer font.deinit();
    var inventory = try inventory_artwork.load(
        allocator,
        icon_file.bytes,
        font_file.bytes,
        &interface.level_label,
    );
    errdefer inventory.deinit();
    // The level screen indexes these colors with `data_set.SpriteLibrary`. That enum must
    // keep the order of the executable's library table.
    var library_colors: [4]palette.Bank = undefined;
    for (&library_colors, interface.actor_libraries) |*colors, library| {
        colors.* = library.colors;
    }
    var password: [13]u8 = undefined;
    @memcpy(password[0..6], &interface.password_prefix);
    @memcpy(password[6..], &interface.passwords[@backingInt(id)][@backingInt(difficulty)]);
    var sound_file = try source.readAll("DATA/GLOBAL.FIB", 4 * 1024 * 1024);
    defer sound_file.deinit();
    var sounds = try sound_effects.decode(allocator, sound_file.bytes);
    errdefer sounds.deinit();
    return .{
        .allocator = allocator,
        .rooms = rooms,
        .characters = characters,
        .animation_file = animation_file,
        .animations = animations,
        .collision = terrain,
        .icons = icons,
        .font = font,
        .library_colors = library_colors,
        .password = password,
        .sounds = sounds,
        .inventory = inventory,
    };
}

fn loadIcons(allocator: std.mem.Allocator, file: []const u8) ![]sprite.Frame {
    if (file.len < 2) return error.InvalidIconDirectory;
    const count = std.mem.readInt(u16, file[0..2], .little) / 2;
    var icons: std.ArrayList(sprite.Frame) = .empty;
    errdefer {
        for (icons.items) |*icon| {
            icon.deinit();
        }
        icons.deinit(allocator);
    }
    for (0..count) |index| {
        var icon = try sprite.fromIcons(allocator, file, @intCast(index));
        errdefer icon.deinit();
        try icons.append(allocator, icon);
    }
    return icons.toOwnedSlice(allocator);
}

/// Decodes every room, then sets the shared blocks of each room's 256 colors. Bit 7 of a room
/// pixel puts it in front of the sprites, so the room's four banks show twice:
/// - 0x00-0x3f: the room's banks (slots 0-3), mirrored at 0x80-0xbf;
/// - 0x40: Conrad, in the alternate colors when slot 2 differs from the first room's;
/// - 0x50: the enemy library, which the level screen sets;
/// - 0xa0: the icons, in the first room's slot 2 colors; they overwrite the mirror of slot 2;
/// - 0xc0-0xdf: the films, which this function does not set;
/// - 0xe0: the text; 0xf0: the interface.
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
    for (rooms, 0..) |*slot, index| {
        slot.* = room_files.decode(
            allocator,
            colors.bytes,
            @intCast(index),
        ) catch |err| switch (err) {
            error.AbsentRoom => null,
            else => return err,
        };
    }
    // The first room's third bank is the reference the others' actor colors follow.
    const first = rooms[first_room] orelse return error.AbsentRoom;
    const reference_bank = first.palette_banks[2];
    const icon_colors = try palette.decodeLevelBank(colors.bytes, reference_bank);
    for (rooms) |*slot| {
        if (slot.*) |*art| {
            const alternate = art.palette_banks[2] != reference_bank;
            @memcpy(art.colors[0x40..0x50], &interface.actor_colors[@intFromBool(alternate)]);
            @memcpy(art.colors[0xa0..0xb0], &icon_colors);
            @memcpy(art.colors[0xe0..0xf0], &interface.text_colors);
            @memcpy(art.colors[0xf0..0x100], &interface.interface_colors);
        }
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
