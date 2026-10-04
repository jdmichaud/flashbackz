//! Owned content for the current jungle development slice. Source identifiers and embedded
//! palette locations are resolved here; the scene uses named motions and opaque art/room IDs.
const std = @import("std");
const platform = @import("../platform.zig");
const motion = @import("../motion.zig");
const conrad = @import("../actors/conrad.zig");
const geometry = @import("../geometry.zig");
const animation = @import("animation.zig");
const collision = @import("collision.zig");
const sprite = @import("sprite.zig");
const artwork = @import("room_artwork.zig");
const palette = @import("palette.zig");
const placement = @import("placement.zig");
const equipment = @import("../equipment.zig");
const starting_equipment = @import("starting_equipment.zig");
const floppy_rooms = @import("floppy_rooms.zig");
const floppy_interface = @import("floppy_interface.zig");
const prop_import = @import("first_world_props.zig");
const art_bank = @import("art_bank.zig");
const object_art = @import("object_artwork.zig");
const inventory_artwork = @import("inventory_artwork.zig");

const Move = enum { roll_running_entry, roll_running_recovery, roll_jump_launch, run_wall_stop, run_stagger_stop, run_ledge_approach, run_ledge_reach, run_ledge_brace, jump_ledge_reach, run_drop, reverse_drop, unbalanced_drop, short_jump_drop, gliding_drop, vertical_drop, run_jump_takeoff, run_jump_ascent, run_jump_crest, run_jump_descent, run_jump_landing, run_jump_stand, run_jump_run, reverse_run, reverse_run_finish, accelerate_run, slow_to_walk, edge_stop, use_item, wake, stand, turn_prepare, turn_finish, walk_start, walk_a, walk_b, run_start, run_a, run_b, run_c, run_d, brake, settle, step_off, land, jump_up, jump_recover, jump_low, jump_low_recover, jump_takeoff, jump_flight, jump_land, jump_finish, crouch_lower, crouch_hold, crouch_rise, crouch_turn, roll_enter, roll_tumble, roll_exit, roll_balance, roll_rise, roll_drop, roll_recover, collision_impact, recoil_fall, recoil_confined, recoil_staggered, recoil_prone, recoil_pause_prone, recoil_pause_tight, recoil_rise, recoil_drop, fall_begin, fall_continue, fatal_land, ledge_lower, ledge_catch, ledge_grip, ledge_hang, ledge_reach, ledge_settle_grip, ledge_climb, ledge_stand, ledge_release, ledge_drop, ledge_turn_release, ledge_tumble_release, ledge_brace, ledge_braced_lower };
const source_moves = [_]u16{ 33, 39, 40, 125, 67, 95, 121, 122, 32, 127, 129, 225, 63, 62, 41, 13, 21, 22, 23, 24, 31, 14, 10, 184, 11, 12, 30, 168, 99, 1, 0, 183, 231, 2, 3, 8, 6, 17, 7, 18, 9, 20, 128, 93, 4, 5, 185, 186, 26, 27, 28, 29, 64, 66, 65, 233, 34, 35, 36, 37, 38, 126, 88, 263, 94, 85, 84, 83, 111, 74, 103, 86, 89, 90, 73, 15, 60, 61, 25, 101, 102, 16, 178, 91, 107, 123, 92, 104, 105 };
pub const RoomArt = struct { id: geometry.RoomId, artwork: artwork.Artwork };

pub const Pack = struct {
    allocator: std.mem.Allocator,
    rooms: []RoomArt,
    frames: []sprite.Frame,
    motions: []animation.OwnedClip,
    walk_strides: []conrad.WalkMotion,
    run_strides: []motion.Clip,
    terrain: collision.Layout,
    initial_items: []equipment.Definition,
    initial_health: i16,
    inventory_art: inventory_artwork.Assets,
    world_props: prop_import.Assets,
    player_contact_width: u8,
    initial_pose: motion.Pose,
    initial_room: geometry.RoomId,

    pub fn deinit(self: *Pack) void {
        for (self.rooms) |*room| room.artwork.deinit();
        for (self.frames) |*art_frame| art_frame.deinit();
        for (self.motions) |*move| move.deinit();
        self.allocator.free(self.rooms);
        self.allocator.free(self.frames);
        self.allocator.free(self.motions);
        self.allocator.free(self.walk_strides);
        self.allocator.free(self.run_strides);
        starting_equipment.release(self.allocator, self.initial_items);
        self.inventory_art.deinit();
        self.world_props.deinit();
        self.terrain.deinit();
        self.* = undefined;
    }

    fn clip(self: *const Pack, move: Move) motion.Clip {
        return self.motions[@backingInt(move)].clip();
    }

    pub fn controllerClips(self: *const Pack) conrad.Clips {
        return .{
            .wake = self.clip(.wake),
            .use_item = self.clip(.use_item),
            .stand = self.clip(.stand),
            .turn_preparation = self.clip(.turn_prepare),
            .turn_follow_through = self.clip(.turn_finish),
            .walk = .{ .start = .{ .clip = self.clip(.walk_start) }, .strides = self.walk_strides },
            .run = .{
                .start = self.clip(.run_start),
                .strides = self.run_strides,
                .entry_stride = 3,
                .wall_stop = self.clip(.run_wall_stop),
                .stagger_stop = self.clip(.run_stagger_stop),
                .brake = self.clip(.brake),
                .settle = self.clip(.settle),
                .accelerate = self.clip(.accelerate_run),
                .walk_out = self.clip(.slow_to_walk),
                .edge_stop = self.clip(.edge_stop),
                .reverse = .{ .brake = self.clip(.reverse_run), .follow_through = self.clip(.reverse_run_finish) },
            },
            .descend = .{ .step_off = self.clip(.step_off), .land = self.clip(.land) },
            .descent = .{
                .running = self.clip(.run_drop),
                .reversing = self.clip(.reverse_drop),
                .unbalanced = self.clip(.unbalanced_drop),
                .short_jump = self.clip(.short_jump_drop),
                .gliding = self.clip(.gliding_drop),
                .vertical = self.clip(.vertical_drop),
            },
            .low_landing = self.clip(.roll_recover),
            .running_jump = .{
                .takeoff = self.clip(.run_jump_takeoff),
                .ascending = self.clip(.run_jump_ascent),
                .crest = self.clip(.run_jump_crest),
                .descending = self.clip(.run_jump_descent),
                .landing = self.clip(.run_jump_landing),
                .standing_recovery = self.clip(.run_jump_stand),
                .running_recovery = self.clip(.run_jump_run),
            },
            .jumps = .{
                .upward = .{ .rise = self.clip(.jump_up), .recover = self.clip(.jump_recover) },
                .low_clearance = .{ .rise = self.clip(.jump_low), .recover = self.clip(.jump_low_recover) },
                .forward = .{ .takeoff = self.clip(.jump_takeoff), .flight = self.clip(.jump_flight), .landing = self.clip(.jump_land), .recover = self.clip(.jump_finish), .ledge_reach = self.clip(.jump_ledge_reach) },
            },
            .crouch = .{ .lower = self.clip(.crouch_lower), .hold = self.clip(.crouch_hold), .rise = self.clip(.crouch_rise), .turn = self.clip(.crouch_turn) },
            .ledge = .{
                .running = .{ .approach = self.clip(.run_ledge_approach), .reach = self.clip(.run_ledge_reach), .brace = self.clip(.run_ledge_brace) },
                .lower = self.clip(.ledge_lower),
                .catch_fall = self.clip(.ledge_catch),
                .grip = self.clip(.ledge_grip),
                .hang = self.clip(.ledge_hang),
                .reach = self.clip(.ledge_reach),
                .settle_grip = self.clip(.ledge_settle_grip),
                .climb = self.clip(.ledge_climb),
                .stand = self.clip(.ledge_stand),
                .release = self.clip(.ledge_release),
                .drop = self.clip(.ledge_drop),
                .turn_release = self.clip(.ledge_turn_release),
                .tumble_release = self.clip(.ledge_tumble_release),
                .brace = self.clip(.ledge_brace),
                .braced_lower = self.clip(.ledge_braced_lower),
            },
            .fall = .{ .initial = self.clip(.fall_begin), .continuing = self.clip(.fall_continue), .landing = self.clip(.fatal_land), .resting = self.clip(.recoil_pause_tight) },
            .recoil = .{
                .impact = self.clip(.collision_impact),
                .fall = self.clip(.recoil_fall),
                .drop = self.clip(.recoil_drop),
                .confined = .{ .settle = self.clip(.recoil_confined), .rest = self.clip(.recoil_pause_tight) },
                .staggered = .{ .settle = self.clip(.recoil_staggered), .rest = self.clip(.recoil_pause_tight) },
                .prone = .{ .settle = self.clip(.recoil_prone), .rest = self.clip(.recoil_pause_prone) },
                .rise = self.clip(.recoil_rise),
            },
            .roll = .{ .running_entry = self.clip(.roll_running_entry), .running_recovery = self.clip(.roll_running_recovery), .jump_launch = self.clip(.roll_jump_launch), .enter = self.clip(.roll_enter), .tumble = self.clip(.roll_tumble), .exit = self.clip(.roll_exit), .balance = self.clip(.roll_balance), .rise = self.clip(.roll_rise), .drop = self.clip(.roll_drop), .recover = self.clip(.roll_recover), .upright_landing = self.clip(.land) },
        };
    }

    pub fn roomArt(self: *const Pack, id: geometry.RoomId) !*const artwork.Artwork {
        for (self.rooms) |*room| if (room.id == id) return &room.artwork;
        return error.MissingRoomArtwork;
    }

    pub fn frame(self: *const Pack, id: motion.VisualId) !*const sprite.Frame {
        const i = @backingInt(id);
        if (i >= self.frames.len) return error.MissingVisual;
        return &self.frames[i];
    }
};

const Resolver = struct {
    allocator: std.mem.Allocator,
    sprites: []const u8,
    offsets: []const u8,
    icons: []const u8,
    compositions: []const u8,
    bindings: []const u8,
    banks: art_bank.Archive,
    ids: std.AutoHashMap(u16, motion.VisualId),
    frames: std.ArrayList(sprite.Frame) = .empty,

    fn deinit(self: *Resolver) void {
        for (self.frames.items) |*frame| frame.deinit();
        self.frames.deinit(self.allocator);
        self.ids.deinit();
    }

    pub fn resolve(self: *Resolver, kind: animation.VisualKind, index: u15) !motion.VisualId {
        const key: u16 = @as(u16, index) | if (kind == .composition) @as(u16, 0x8000) else 0;
        if (self.ids.get(key)) |id| return id;
        var frame = if (kind == .sprite) try sprite.fromArchive(self.allocator, self.sprites, self.offsets, index) else try object_art.fromArchive(self.allocator, self.compositions, self.bindings, self.banks, index);
        errdefer frame.deinit();
        try self.frames.ensureUnusedCapacity(self.allocator, 1);
        const id: motion.VisualId = @fromBackingInt(@as(u32, @intCast(self.frames.items.len)));
        try self.ids.put(key, id);
        self.frames.appendAssumeCapacity(frame);
        return id;
    }

    pub fn icon(self: *Resolver, index: u16) !motion.VisualId {
        var image = try sprite.fromIcons(self.allocator, self.icons, index);
        errdefer image.deinit();
        const id: motion.VisualId = @fromBackingInt(@as(u32, @intCast(self.frames.items.len)));
        try self.frames.append(self.allocator, image);
        return id;
    }
};

fn read(source: platform.AssetSource, name: []const u8, maximum: usize) !platform.OwnedBytes {
    return source.readAll(name, maximum);
}

pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Pack {
    return loadWithDifficulty(allocator, source, .normal);
}

pub fn loadWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, _: @import("../settings.zig").Difficulty) !Pack {
    const values = try floppy_interface.load(allocator, source);
    return assemble(allocator, source, .{ .actor_colors = values.actor_colors, .text_colors = values.text_colors, .interface_colors = values.interface_colors, .level_label = &values.level_label });
}

/// Decoded interface content supplied by an edition importer. No executable offsets enter
/// scene assembly. Palette and label locations are isolated in the floppy edition importer.
pub const Interface = struct {
    actor_colors: [2]palette.Bank,
    text_colors: palette.Bank,
    interface_colors: palette.Bank,
    level_label: []const u8,
};

pub fn assemble(allocator: std.mem.Allocator, source: platform.AssetSource, interface: Interface) !Pack {
    var rooms = try RoomSource.open(source);
    defer rooms.deinit();
    var colors = try read(source, "DATA/LEVEL1.PAL", 8192);
    defer colors.deinit();
    var sprites = try read(source, "DATA/PERSO.SPR", 1024 * 1024);
    defer sprites.deinit();
    var offsets = try read(source, "DATA/PERSO.OFF", 32768);
    defer offsets.deinit();
    var ani = try read(source, "DATA/LEVEL1.ANI", 65536);
    defer ani.deinit();
    var rules = try read(source, "DATA/LEVEL1.OBJ", 65536);
    defer rules.deinit();
    var ct = try read(source, "DATA/LEVEL1.CT", 65536);
    defer ct.deinit();
    var icons = try read(source, "DATA/GLOBAL.ICN", 32768);
    defer icons.deinit();
    var compositions = try read(source, "DATA/GLOBAL.SPC", 65536);
    defer compositions.deinit();
    var banks_file = try read(source, "DATA/LEVEL1.MBK", 65536);
    defer banks_file.deinit();
    var bindings = try read(source, "DATA/LEVEL1.RP", 256);
    defer bindings.deinit();
    const banks = try art_bank.Archive.init(banks_file.bytes);
    var font_bytes = try read(source, "DATA/FB_TXT.FNT", 16384);
    defer font_bytes.deinit();
    var names = try read(source, "DATA/LEVEL1.TBN", 16384);
    defer names.deinit();
    var placements = try read(source, "DATA/LEVEL1.PGE", 16384);
    defer placements.deinit();
    const placement_table = try placement.Table.init(placements.bytes);
    const player = try placement_table.record(0);
    if (player.initial_state != 99 or player.kind != 1 or player.room >= 64) return error.UnsupportedPlayerStart;
    var inventory_art = try inventory_artwork.load(allocator, icons.bytes, font_bytes.bytes, interface.level_label);
    errdefer inventory_art.deinit();
    var room_ids: [64]geometry.RoomId = undefined;
    for (&room_ids, 0..) |*id, i| id.* = @fromBackingInt(@as(u16, @intCast(i)) + 1);
    var terrain = try collision.decode(allocator, ct.bytes, &room_ids);
    errdefer terrain.deinit();
    var resolver: Resolver = .{ .allocator = allocator, .sprites = sprites.bytes, .offsets = offsets.bytes, .icons = icons.bytes, .compositions = compositions.bytes, .bindings = bindings.bytes, .banks = banks, .ids = std.AutoHashMap(u16, motion.VisualId).init(allocator) };
    defer resolver.deinit();
    const motions = try allocator.alloc(animation.OwnedClip, source_moves.len);
    var loaded: usize = 0;
    errdefer {
        for (motions[0..loaded]) |*move| move.deinit();
        allocator.free(motions);
    }
    for (source_moves, 0..) |index, i| {
        var clip = try animation.decode(allocator, ani.bytes, index);
        defer clip.deinit();
        motions[i] = try clip.resolve(allocator, &resolver);
        loaded += 1;
    }
    const walk = try allocator.alloc(conrad.WalkMotion, 2);
    errdefer allocator.free(walk);
    walk[0] = .{ .clip = motions[@backingInt(Move.walk_a)].clip(), .torso_clearance_ahead = 0 };
    walk[1] = .{ .clip = motions[@backingInt(Move.walk_b)].clip() };
    const run = try allocator.alloc(motion.Clip, 4);
    errdefer allocator.free(run);
    for (run, 0..) |*clip, i| clip.* = motions[@backingInt(Move.run_a) + i].clip();
    var initial_items = try starting_equipment.recover(allocator, placement_table, ani.bytes, rules.bytes, names.bytes, &resolver);
    errdefer starting_equipment.release(allocator, initial_items);
    var props = try prop_import.load(allocator, placement_table, ani.bytes, rules.bytes, names.bytes, &room_ids, .{ .index = @intCast(initial_items.len), .generation = 1 }, &resolver);
    errdefer props.deinit();
    initial_items = try allocator.realloc(initial_items, initial_items.len + 1);
    initial_items[initial_items.len - 1] = props.takeItem();
    var room_art: std.ArrayList(RoomArt) = .empty;
    errdefer {
        for (room_art.items) |*room| room.artwork.deinit();
        room_art.deinit(allocator);
    }
    var first_room = try rooms.decode(allocator, colors.bytes, player.room);
    defer first_room.deinit();
    const reference_bank = first_room.palette_banks[2];
    const icon_colors = try palette.decodeLevelBank(colors.bytes, reference_bank);
    for (0..64) |index| {
        var art = rooms.decode(allocator, colors.bytes, @intCast(index)) catch |err| switch (err) {
            error.AbsentRoom => continue,
            else => return err,
        };
        errdefer art.deinit();
        const alternate = art.palette_banks[2] != reference_bank;
        @memcpy(art.colors[0x40..0x50], &interface.actor_colors[@intFromBool(alternate)]);
        @memcpy(art.colors[0xa0..0xb0], &icon_colors);
        @memcpy(art.colors[0xe0..0xf0], &interface.text_colors);
        @memcpy(art.colors[0xf0..0x100], &interface.interface_colors);
        try room_art.append(allocator, .{ .id = room_ids[index], .artwork = art });
    }
    const decoded_rooms = try room_art.toOwnedSlice(allocator);
    errdefer {
        for (decoded_rooms) |*room| room.artwork.deinit();
        allocator.free(decoded_rooms);
    }
    const facing: motion.Facing = if (player.facing_right == 0) .left else .right;
    const first_visual = switch (motions[@backingInt(Move.wake)].steps[0]) {
        .frame => |frame| frame.visual,
        .hold => return error.UnsupportedPlayerStart,
    };
    const frames = try resolver.frames.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .rooms = decoded_rooms,
        .frames = frames,
        .motions = motions,
        .walk_strides = walk,
        .run_strides = run,
        .terrain = terrain,
        .initial_items = initial_items,
        .initial_health = player.life,
        .inventory_art = inventory_art,
        .world_props = props,
        .player_contact_width = player.collision_width,
        .initial_room = room_ids[player.room],
        .initial_pose = .{ .position = player.position, .facing = facing, .visual = .{ .id = first_visual.id, .mirrored = first_visual.mirrored != (facing == .left) } },
    };
}

/// Own whichever source representation the user supplied. Both yield ordinary artwork.
const RoomSource = union(enum) {
    installed: platform.OwnedBytes,
    compact: struct { rooms: platform.OwnedBytes, tiles: platform.OwnedBytes, background: platform.OwnedBytes },
    fn open(source: platform.AssetSource) !RoomSource {
        if (read(source, "DATA/LEVEL1.MAP", 8 * 1024 * 1024)) |file| return .{ .installed = file } else |err| if (err != error.NotFound) return err;
        var rooms = try read(source, "DATA/LEVEL1.LEV", 1024 * 1024);
        errdefer rooms.deinit();
        var tiles = try read(source, "DATA/LEVEL1.BNQ", 1024 * 1024);
        errdefer tiles.deinit();
        return .{ .compact = .{ .rooms = rooms, .tiles = tiles, .background = try read(source, "DATA/LEVEL1.SGD", 1024 * 1024) } };
    }
    fn deinit(self: *RoomSource) void {
        switch (self.*) {
            .installed => |*file| file.deinit(),
            .compact => |*files| {
                files.rooms.deinit();
                files.tiles.deinit();
                files.background.deinit();
            },
        }
    }
    fn decode(self: *const RoomSource, allocator: std.mem.Allocator, colors: []const u8, room: u8) !artwork.Artwork {
        return switch (self.*) {
            .installed => |file| artwork.decode(allocator, file.bytes, colors, room),
            .compact => |files| (floppy_rooms.Archive{ .rooms = files.rooms.bytes, .banks = files.tiles.bytes, .background = files.background.bytes, .tile_bias = 896 }).decode(allocator, colors, room),
        };
    }
};
