//! Owned content for the current jungle development slice. Source identifiers and embedded
//! palette locations are resolved here; the scene uses named motions and opaque art/room IDs.
const level_mod = @import("level.zig");
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

const Move = enum { throw_item, operate_reach, operate_press, operate_recover, surface_rest, surface_burst, armed_clearing_draw, casing_stand_a, casing_stand_b, casing_crouch_a, casing_crouch_b, armed_roll_recovery, armed_drawing_after_climb, shot_ignition, shot_flash, shot_flash_low, shot_impact, shot_impact_low, armed_firing, armed_firing_crouched, armed_drawing_crouched, armed_draw_crouched_release, armed_draw_start, armed_drawing, armed_draw_release, armed_aiming, armed_lowering_aim, armed_standing, armed_walking, armed_turning, armed_holstering, armed_holstering_aim, armed_raising_aim, armed_crouching, armed_crouched, armed_turning_crouched, armed_rising, armed_holstering_crouched, armed_lowering_aim_crouched, armed_raising_aim_crouched, armed_aim_crouch_release, armed_aiming_crouched, armed_crouching_aim, armed_rising_aim, armed_turning_aim, armed_turning_aim_crouched, armed_stepping_down, armed_landing, roll_running_entry, roll_running_recovery, roll_jump_launch, run_wall_stop, run_stagger_stop, run_ledge_approach, run_ledge_reach, run_ledge_brace, jump_ledge_reach, run_drop, reverse_drop, unbalanced_drop, short_jump_drop, gliding_drop, vertical_drop, run_jump_takeoff, run_jump_ascent, run_jump_crest, run_jump_descent, run_jump_landing, run_jump_stand, run_jump_run, reverse_run, reverse_run_finish, accelerate_run, slow_to_walk, edge_stop, use_item, wake, stand, turn_prepare, turn_finish, walk_start, walk_a, walk_b, run_start, run_a, run_b, run_c, run_d, brake, settle, step_off, land, jump_up, jump_recover, jump_low, jump_low_recover, jump_takeoff, jump_flight, jump_land, jump_finish, crouch_lower, crouch_hold, crouch_rise, crouch_turn, roll_enter, roll_tumble, roll_exit, roll_balance, roll_rise, roll_drop, roll_recover, collision_impact, recoil_fall, recoil_confined, recoil_staggered, recoil_prone, recoil_pause_prone, recoil_pause_tight, recoil_rise, recoil_drop, fall_begin, fall_continue, fatal_land, ledge_lower, ledge_catch, ledge_grip, ledge_hang, ledge_reach, ledge_settle_grip, ledge_climb, ledge_stand, ledge_release, ledge_drop, ledge_turn_release, ledge_tumble_release, ledge_brace, ledge_braced_lower };
const source_moves = [_]u16{ 69, 179, 181, 180, 565, 566, 77, 162, 163, 164, 165, 177, 174, 443, 414, 415, 411, 413, 58, 59, 160, 222, 182, 175, 223, 57, 55, 44, 45, 48, 52, 262, 54, 46, 50, 49, 51, 161, 53, 47, 224, 56, 71, 72, 76, 173, 166, 167, 33, 39, 40, 125, 67, 95, 121, 122, 32, 127, 129, 225, 63, 62, 41, 13, 21, 22, 23, 24, 31, 14, 10, 184, 11, 12, 30, 168, 99, 1, 0, 183, 231, 2, 3, 8, 6, 17, 7, 18, 9, 20, 128, 93, 4, 5, 185, 186, 26, 27, 28, 29, 64, 66, 65, 233, 34, 35, 36, 37, 38, 126, 88, 263, 94, 85, 84, 83, 111, 74, 103, 86, 89, 90, 73, 15, 60, 61, 25, 101, 102, 16, 178, 91, 107, 123, 92, 104, 105 };
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
    sounds: @import("sound_effects.zig").Bank,
    inventory_art: inventory_artwork.Assets,
    world_props: prop_import.Assets,
    controls: @import("operated_controls.zig").Assets,
    hazards: @import("electrical_hazards.zig").Assets,
    gunmen: @import("gunmen.zig").Assets,
    robots: @import("ground_robots.zig").Assets,
    wounds: @import("conrad_wound.zig").Assets,
    player_contact_width: u8,
    surfaces: []@import("../surface_reactions.zig").Definition,
    forest_calls: []@import("../ambience.zig").Call,
    forest_quiet_steps: u16,
    casing_definition: @import("../pistol_casing.zig").Definition,
    pistol_range: u16,
    pistol_palette: u4,
    pistol_behind_player: bool,
    initial_activity: conrad.Activity,
    forest_enabled: bool,
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
        self.controls.deinit();
        self.hazards.deinit();
        self.gunmen.deinit();
        self.robots.deinit();
        self.wounds.deinit();
        self.sounds.deinit();
        self.allocator.free(self.surfaces);
        self.allocator.free(self.forest_calls);
        self.terrain.deinit();
        self.* = undefined;
    }

    fn clip(self: *const Pack, move: Move) motion.Clip {
        return self.motions[@backingInt(move)].clip();
    }

    pub fn surfaceClips(self: *const Pack) @import("../surface_reactions.zig").Clips {
        return .{ .resting = self.clip(.surface_rest), .burst = self.clip(.surface_burst) };
    }

    pub fn pistolDefinition(self: *const Pack) @import("../pistol_shot.zig").Definition {
        return .{ .ignition = self.clip(.shot_ignition), .standing_flash = self.clip(.shot_flash), .crouched_flash = self.clip(.shot_flash_low), .standing_impact = self.clip(.shot_impact), .crouched_impact = self.clip(.shot_impact_low), .range_cells = self.pistol_range, .palette_bank = self.pistol_palette, .behind_player = self.pistol_behind_player };
    }

    pub fn controllerClips(self: *const Pack) conrad.Clips {
        return .{
            .wounds = self.wounds.definition(),
            .armed = .{
                .clearing_draw = self.clip(.armed_clearing_draw),
                .roll_recovery = self.clip(.armed_roll_recovery),
                .drawing_after_climb = self.clip(.armed_drawing_after_climb),
                .firing = self.clip(.armed_firing),
                .firing_crouched = self.clip(.armed_firing_crouched),
                .drawing_crouched = self.clip(.armed_drawing_crouched),
                .draw_crouched_release = self.clip(.armed_draw_crouched_release),
                .draw_start = self.clip(.armed_draw_start),
                .drawing = self.clip(.armed_drawing),
                .draw_release = self.clip(.armed_draw_release),
                .aiming = self.clip(.armed_aiming),
                .lowering_aim = self.clip(.armed_lowering_aim),
                .standing = self.clip(.armed_standing),
                .walking = self.clip(.armed_walking),
                .turning = self.clip(.armed_turning),
                .holstering = self.clip(.armed_holstering),
                .holstering_aim = self.clip(.armed_holstering_aim),
                .raising_aim = self.clip(.armed_raising_aim),
                .crouching = self.clip(.armed_crouching),
                .crouched = self.clip(.armed_crouched),
                .turning_crouched = self.clip(.armed_turning_crouched),
                .rising = self.clip(.armed_rising),
                .holstering_crouched = self.clip(.armed_holstering_crouched),
                .lowering_aim_crouched = self.clip(.armed_lowering_aim_crouched),
                .raising_aim_crouched = self.clip(.armed_raising_aim_crouched),
                .aim_crouch_release = self.clip(.armed_aim_crouch_release),
                .aiming_crouched = self.clip(.armed_aiming_crouched),
                .crouching_aim = self.clip(.armed_crouching_aim),
                .rising_aim = self.clip(.armed_rising_aim),
                .turning_aim = self.clip(.armed_turning_aim),
                .turning_aim_crouched = self.clip(.armed_turning_aim_crouched),
                .stepping_down = self.clip(.armed_stepping_down),
                .landing = self.clip(.armed_landing),
            },
            .wake = self.clip(.wake),
            .use_item = self.clip(.use_item),
            .throw_item = self.clip(.throw_item),
            .operate = .{ .reach = self.clip(.operate_reach), .press = self.clip(.operate_press), .recover = self.clip(.operate_recover) },
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
    extra_art: @import("actor_art.zig").Catalog,
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
        self.extra_art.deinit();
    }

    pub fn resolve(self: *Resolver, kind: animation.VisualKind, index: u15) !motion.VisualId {
        const key: u16 = @as(u16, index) | if (kind == .composition) @as(u16, 0x8000) else 0;
        if (self.ids.get(key)) |id| return id;
        var frame = if (kind == .sprite) try self.spriteFrame(index) else try object_art.fromArchive(self.allocator, self.compositions, self.bindings, self.banks, index);
        errdefer frame.deinit();
        try self.frames.ensureUnusedCapacity(self.allocator, 1);
        const id: motion.VisualId = @fromBackingInt(@as(u32, @intCast(self.frames.items.len)));
        try self.ids.put(key, id);
        self.frames.appendAssumeCapacity(frame);
        return id;
    }

    fn spriteFrame(self: *Resolver, index: u16) !sprite.Frame {
        return sprite.fromArchive(self.allocator, self.sprites, self.offsets, index) catch |err| switch (err) {
            error.MissingSprite => self.extra_art.resolve(self.allocator, index),
            else => err,
        };
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

pub fn loadWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, difficulty: @import("../settings.zig").Difficulty) !Pack {
    return loadLevelWithDifficulty(allocator, source, .jungle, difficulty);
}

pub fn loadLevel(allocator: std.mem.Allocator, source: platform.AssetSource, level: level_mod.Id) !Pack {
    return loadLevelWithDifficulty(allocator, source, level, .normal);
}

pub fn loadLevelWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, level: level_mod.Id, difficulty: @import("../settings.zig").Difficulty) !Pack {
    const values = try floppy_interface.load(allocator, source);
    return assembleLevel(allocator, source, level, difficulty, .{ .actor_colors = values.actor_colors, .actor_libraries = &values.actor_libraries, .score_awards = values.score_awards, .text_colors = values.text_colors, .interface_colors = values.interface_colors, .level_label = &values.level_label });
}

/// Decoded interface content supplied by an edition importer. No executable offsets enter
/// scene assembly. Palette and label locations are isolated in the floppy edition importer.
pub const Interface = struct {
    actor_colors: [2]palette.Bank,
    actor_libraries: []const @import("actor_art.zig").Library,
    score_awards: [16]u16,
    text_colors: palette.Bank,
    interface_colors: palette.Bank,
    level_label: []const u8,
};

pub fn assemble(allocator: std.mem.Allocator, source: platform.AssetSource, interface: Interface) !Pack {
    return assembleLevel(allocator, source, .jungle, .normal, interface);
}

fn assembleLevel(allocator: std.mem.Allocator, source: platform.AssetSource, level: level_mod.Id, difficulty: @import("../settings.zig").Difficulty, interface: Interface) !Pack {
    const files = level_mod.files(level);
    var rooms = try RoomSource.open(source, files);
    defer rooms.deinit();
    var colors = try readLevel(source, files.rooms, "PAL", 8192);
    defer colors.deinit();
    var sprites = try read(source, "DATA/PERSO.SPR", 1024 * 1024);
    defer sprites.deinit();
    var offsets = try read(source, "DATA/PERSO.OFF", 32768);
    defer offsets.deinit();
    var ani = try readLevel(source, files.actors, "ANI", 65536);
    defer ani.deinit();
    var rules = try readLevel(source, files.actors, "OBJ", 256 * 1024);
    defer rules.deinit();
    var ct = try readLevel(source, files.rooms, "CT", 65536);
    defer ct.deinit();
    var icons = try read(source, "DATA/GLOBAL.ICN", 32768);
    defer icons.deinit();
    var compositions = try read(source, "DATA/GLOBAL.SPC", 65536);
    defer compositions.deinit();
    var banks_file = try readLevel(source, files.rooms, "MBK", 65536);
    defer banks_file.deinit();
    var bindings = try readLevel(source, files.rooms, "RP", 256);
    defer bindings.deinit();
    const banks = try art_bank.Archive.init(banks_file.bytes);
    var font_bytes = try read(source, "DATA/FB_TXT.FNT", 16384);
    defer font_bytes.deinit();
    var names = try readLevel(source, files.actors, "TBN", 16384);
    defer names.deinit();
    var sound_bytes = try read(source, "DATA/GLOBAL.FIB", 4 * 1024 * 1024);
    defer sound_bytes.deinit();
    var sounds = try @import("sound_effects.zig").decode(allocator, sound_bytes.bytes);
    errdefer sounds.deinit();
    var placements = try readLevel(source, files.actors, "PGE", 16384);
    defer placements.deinit();
    const placement_table = try placement.Table.init(placements.bytes);
    const forest_enabled = forest: {
        for (0..placement_table.count) |i| if ((try placement_table.record(@intCast(i))).initial_state == 1143) break :forest true;
        break :forest false;
    };
    const forest_calls = try allocator.alloc(@import("../ambience.zig").Call, if (forest_enabled) 5 else 0);
    errdefer allocator.free(forest_calls);
    var forest_quiet_steps: u16 = 0;
    if (forest_enabled) {
        const forest_sources = [_]u16{ 1144, 1145, 1146, 1147, 1148 };
        for (forest_sources, forest_calls, 0..) |state, *call, index| {
            var clip = try animation.decode(allocator, ani.bytes, state);
            defer clip.deinit();
            call.* = .{ .sound = @fromBackingInt(clip.sound orelse return error.MissingForestSound), .duration = @intCast(clip.frames.len), .chance = if (index < 2) 20 else 10, .repeat_chance = if (index == 2 or index == 3) @as(u16, 2) else null };
        }
        var quiet = try animation.decode(allocator, ani.bytes, 1143);
        defer quiet.deinit();
        forest_quiet_steps = @intCast(quiet.frames.len);
    }
    const player = try placement_table.record(0);
    if (player.parameters[0] < 0) return error.InvalidPistolBinding;
    const gun = try placement_table.record(@intCast(player.parameters[0]));
    if (gun.parameters[0] < 0) return error.InvalidPistolBinding;
    const shot = try placement_table.record(@intCast(gun.parameters[0]));
    if (shot.parameters[3] < 0) return error.InvalidCasingBinding;
    const casing = try placement_table.record(@intCast(shot.parameters[3]));
    if (casing.initial_state != 163) return error.UnsupportedCasingStart;
    if (gun.object_id != 2 or shot.parameters[0] < 1 or shot.parameters[0] > 64) return error.UnsupportedPistolDefinition;
    if ((player.initial_state != 99 and player.initial_state != 1) or player.kind != 1 or player.room >= 64) return error.UnsupportedPlayerStart;
    var inventory_art = try inventory_artwork.load(allocator, icons.bytes, font_bytes.bytes, interface.level_label);
    errdefer inventory_art.deinit();
    var room_ids: [64]geometry.RoomId = undefined;
    for (&room_ids, 0..) |*id, i| id.* = @fromBackingInt(@as(u16, @intCast(i)) + 1);
    var terrain = try collision.decode(allocator, ct.bytes, &room_ids);
    errdefer terrain.deinit();
    var resolver: Resolver = .{ .allocator = allocator, .sprites = sprites.bytes, .offsets = offsets.bytes, .extra_art = .{ .source = source, .libraries = interface.actor_libraries }, .icons = icons.bytes, .compositions = compositions.bytes, .bindings = bindings.bytes, .banks = banks, .ids = std.AutoHashMap(u16, motion.VisualId).init(allocator) };
    defer resolver.deinit();
    var surfaces: std.ArrayList(@import("../surface_reactions.zig").Definition) = .empty;
    errdefer surfaces.deinit(allocator);
    for (0..placement_table.count) |i| {
        const surface = try placement_table.record(@intCast(i));
        if (surface.initial_state != 565) continue;
        if (surface.minimum_difficulty != 0) return error.UnsupportedConditionalSurface;
        if (surface.room >= room_ids.len) return error.InvalidSurfaceRoom;
        try surfaces.append(allocator, .{ .footprint = .{ .room = room_ids[surface.room], .position = surface.position, .width = surface.collision_width }, .facing = if (surface.facing_right != 0) .right else .left, .palette_bank = @intCast(surface.visual_flags & 3), .behind_player = surface.visual_flags & 8 != 0 });
    }
    const motions = try allocator.alloc(animation.OwnedClip, source_moves.len);
    var loaded: usize = 0;
    errdefer {
        for (motions[0..loaded]) |*move| move.deinit();
        allocator.free(motions);
    }
    for (source_moves, 0..) |index, i| {
        // Unused animation slots can name another sprite bank in other levels. A
        // feature without placed instances owns no clips and resolves no artwork.
        if (surfaces.items.len == 0 and (i == @backingInt(Move.surface_rest) or i == @backingInt(Move.surface_burst))) {
            motions[i] = .{ .allocator = allocator, .steps = try allocator.alloc(motion.Step, 0), .presses_floor_switches = false };
            loaded += 1;
            continue;
        }
        var clip = try animation.decode(allocator, ani.bytes, index);
        defer clip.deinit();
        motions[i] = try clip.resolve(allocator, &resolver);
        loaded += 1;
    }
    var wounds = try @import("conrad_wound.zig").load(allocator, rules.bytes, player.rule_group, ani.bytes, &source_moves, &resolver);
    errdefer wounds.deinit();
    for (motions, 0..) |*clip, index| clip.hit_profile = @fromBackingInt(@as(u16, @intCast(index)));
    const walk = try allocator.alloc(conrad.WalkMotion, 2);
    errdefer allocator.free(walk);
    walk[0] = .{ .clip = motions[@backingInt(Move.walk_a)].clip(), .torso_clearance_ahead = 0 };
    walk[1] = .{ .clip = motions[@backingInt(Move.walk_b)].clip() };
    const run = try allocator.alloc(motion.Clip, 4);
    errdefer allocator.free(run);
    for (run, 0..) |*clip, i| clip.* = motions[@backingInt(Move.run_a) + i].clip();
    var initial_items = try starting_equipment.recover(allocator, placement_table, ani.bytes, rules.bytes, names.bytes, &resolver);
    errdefer starting_equipment.release(allocator, initial_items);
    var props = try prop_import.load(allocator, placement_table, ani.bytes, rules.bytes, names.bytes, &room_ids, difficulty, .{ .index = @intCast(initial_items.len), .generation = 1 }, &resolver);
    errdefer props.deinit();
    var connections: std.ArrayList(prop_import.Connection) = .empty;
    defer connections.deinit(allocator);
    try connections.appendSlice(allocator, props.connections);
    var operated = try @import("operated_controls.zig").load(allocator, placement_table, rules.bytes, ani.bytes, names.bytes, &room_ids, difficulty, &connections, &resolver);
    errdefer operated.deinit();
    const combined_connections = try connections.toOwnedSlice(allocator);
    allocator.free(props.connections);
    props.connections = combined_connections;
    var hazards = try @import("electrical_hazards.zig").load(allocator, placement_table, rules.bytes, ani.bytes, &room_ids, difficulty, props.connections, &resolver);
    errdefer hazards.deinit();
    var gunmen = try @import("gunmen.zig").load(allocator, placement_table, rules.bytes, ani.bytes, &room_ids, difficulty, interface.score_awards, &resolver);
    errdefer gunmen.deinit();
    var robots = try @import("ground_robots.zig").load(allocator, placement_table, rules.bytes, ani.bytes, &room_ids, difficulty, &resolver);
    errdefer robots.deinit();
    const supplied = initial_items.len;
    initial_items = try allocator.realloc(initial_items, supplied + props.items.len);
    for (props.items, initial_items[supplied..]) |*item, *destination| {
        destination.* = item.*;
        item.label = &.{};
    }
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
        if (gunmen.definitions.len != 0) @memcpy(art.colors[0x50..0x60], &interface.actor_libraries[0].colors);
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
    const first_visual = switch (motions[@backingInt(if (player.initial_state == 99) Move.wake else Move.stand)].steps[0]) {
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
        .controls = operated,
        .hazards = hazards,
        .gunmen = gunmen,
        .robots = robots,
        .wounds = wounds,
        .surfaces = try surfaces.toOwnedSlice(allocator),
        .sounds = sounds,
        .forest_calls = forest_calls,
        .forest_quiet_steps = forest_quiet_steps,
        .casing_definition = .{
            .trajectories = .{ motions[@backingInt(Move.casing_stand_a)].clip(), motions[@backingInt(Move.casing_stand_b)].clip(), motions[@backingInt(Move.casing_crouch_a)].clip(), motions[@backingInt(Move.casing_crouch_b)].clip() },
            .initial_pose = .{ .position = casing.position, .facing = if (casing.facing_right != 0) .right else .left, .visual = .{ .id = @fromBackingInt(0) } },
            .initial_room = if (casing.room < room_ids.len) room_ids[casing.room] else null,
            .initial_path = .standing_b,
            .palette_bank = @intCast(casing.visual_flags & 3),
            .behind_player = casing.visual_flags & 8 != 0,
        },
        .pistol_range = @intCast(shot.parameters[0]),
        .pistol_palette = @intCast(shot.visual_flags & 3),
        .pistol_behind_player = shot.visual_flags & 8 != 0,
        .player_contact_width = player.collision_width,
        .initial_room = room_ids[player.room],
        .initial_activity = if (player.initial_state == 99) .waking else .standing,
        .forest_enabled = forest_enabled,
        .initial_pose = .{ .position = player.position, .facing = facing, .visual = .{ .id = first_visual.id, .mirrored = first_visual.mirrored != (facing == .left) } },
    };
}

/// Own whichever source representation the user supplied. Both yield ordinary artwork.
const RoomSource = union(enum) {
    installed: platform.OwnedBytes,
    compact: struct { rooms: platform.OwnedBytes, tiles: platform.OwnedBytes, background: ?platform.OwnedBytes, tile_bias: u16 },
    fn open(source: platform.AssetSource, files: level_mod.Files) !RoomSource {
        if (readLevel(source, files.rooms, "MAP", 8 * 1024 * 1024)) |file| return .{ .installed = file } else |err| if (err != error.NotFound) return err;
        var rooms = try readLevel(source, files.rooms, "LEV", 1024 * 1024);
        errdefer rooms.deinit();
        var tiles = try readLevel(source, files.rooms, "BNQ", 1024 * 1024);
        errdefer tiles.deinit();
        return .{ .compact = .{ .rooms = rooms, .tiles = tiles, .background = if (files.tile_bias != 0) try readLevel(source, files.rooms, "SGD", 1024 * 1024) else null, .tile_bias = files.tile_bias } };
    }
    fn deinit(self: *RoomSource) void {
        switch (self.*) {
            .installed => |*file| file.deinit(),
            .compact => |*files| {
                files.rooms.deinit();
                files.tiles.deinit();
                if (files.background) |*background| background.deinit();
            },
        }
    }
    fn decode(self: *const RoomSource, allocator: std.mem.Allocator, colors: []const u8, room: u8) !artwork.Artwork {
        return switch (self.*) {
            .installed => |file| artwork.decode(allocator, file.bytes, colors, room),
            .compact => |files| (floppy_rooms.Archive{ .rooms = files.rooms.bytes, .banks = files.tiles.bytes, .background = if (files.background) |background| background.bytes else &.{}, .tile_bias = files.tile_bias }).decode(allocator, colors, room),
        };
    }
};

fn readLevel(source: platform.AssetSource, basename: []const u8, extension: []const u8, limit: usize) !platform.OwnedBytes {
    var path: [64]u8 = undefined;
    return read(source, try std.fmt.bufPrint(&path, "DATA/{s}.{s}", .{ basename, extension }), limit);
}
