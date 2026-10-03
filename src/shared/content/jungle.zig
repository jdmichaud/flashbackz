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
const inventory_artwork = @import("inventory_artwork.zig");

const Move = enum { wake, stand, turn_prepare, turn_finish, walk_start, walk_a, walk_b, run_start, run_a, run_b, run_c, run_d, brake, settle, step_off, land, jump_up, jump_recover, jump_low, jump_low_recover, jump_takeoff, jump_flight, jump_land, jump_finish, crouch_lower, crouch_hold, crouch_rise, crouch_turn, roll_enter, roll_tumble, roll_exit, roll_balance, roll_rise, roll_drop, roll_recover };
const source_moves = [_]u16{ 99, 1, 0, 183, 231, 2, 3, 8, 6, 17, 7, 18, 9, 20, 128, 93, 4, 5, 185, 186, 26, 27, 28, 29, 64, 66, 65, 233, 34, 35, 36, 37, 38, 126, 88 };
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
        self.terrain.deinit();
        self.* = undefined;
    }

    fn clip(self: *const Pack, move: Move) motion.Clip {
        return self.motions[@backingInt(move)].clip();
    }

    pub fn controllerClips(self: *const Pack) conrad.Clips {
        return .{
            .wake = self.clip(.wake),
            .stand = self.clip(.stand),
            .turn_preparation = self.clip(.turn_prepare),
            .turn_follow_through = self.clip(.turn_finish),
            .walk = .{ .start = .{ .clip = self.clip(.walk_start) }, .strides = self.walk_strides },
            .run = .{ .start = self.clip(.run_start), .strides = self.run_strides, .entry_stride = 3, .brake = self.clip(.brake), .settle = self.clip(.settle) },
            .descend = .{ .step_off = self.clip(.step_off), .land = self.clip(.land) },
            .jumps = .{
                .upward = .{ .rise = self.clip(.jump_up), .recover = self.clip(.jump_recover) },
                .low_clearance = .{ .rise = self.clip(.jump_low), .recover = self.clip(.jump_low_recover) },
                .forward = .{ .takeoff = self.clip(.jump_takeoff), .flight = self.clip(.jump_flight), .landing = self.clip(.jump_land), .recover = self.clip(.jump_finish) },
            },
            .crouch = .{ .lower = self.clip(.crouch_lower), .hold = self.clip(.crouch_hold), .rise = self.clip(.crouch_rise), .turn = self.clip(.crouch_turn) },
            .roll = .{ .enter = self.clip(.roll_enter), .tumble = self.clip(.roll_tumble), .exit = self.clip(.roll_exit), .balance = self.clip(.roll_balance), .rise = self.clip(.roll_rise), .drop = self.clip(.roll_drop), .recover = self.clip(.roll_recover), .upright_landing = self.clip(.land) },
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
    ids: std.AutoHashMap(u16, motion.VisualId),
    frames: std.ArrayList(sprite.Frame) = .empty,

    fn deinit(self: *Resolver) void {
        for (self.frames.items) |*frame| frame.deinit();
        self.frames.deinit(self.allocator);
        self.ids.deinit();
    }

    pub fn resolve(self: *Resolver, kind: animation.VisualKind, index: u15) !motion.VisualId {
        if (kind != .sprite) return error.UnsupportedPlayerArtwork;
        if (self.ids.get(index)) |id| return id;
        var frame = try sprite.fromArchive(self.allocator, self.sprites, self.offsets, index);
        errdefer frame.deinit();
        try self.frames.ensureUnusedCapacity(self.allocator, 1);
        const id: motion.VisualId = @fromBackingInt(@as(u32, @intCast(self.frames.items.len)));
        try self.ids.put(index, id);
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

pub fn loadWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, difficulty_setting: @import("../settings.zig").Difficulty) !Pack {
    var map = try read(source, "DATA/LEVEL1.MAP", 8 * 1024 * 1024);
    defer map.deinit();
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
    var font_bytes = try read(source, "DATA/FB_TXT.FNT", 16384);
    defer font_bytes.deinit();
    var names = try read(source, "DATA/LEVEL1.TBN", 16384);
    defer names.deinit();
    var placements = try read(source, "DATA/LEVEL1.PGE", 16384);
    defer placements.deinit();
    const placement_table = try placement.Table.init(placements.bytes);
    const player = try placement_table.record(0);
    if (player.initial_state != 99 or player.kind != 1 or player.room >= 64) return error.UnsupportedPlayerStart;
    var executable = try read(source, "GAME_E.OVL", 1024 * 1024);
    defer executable.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable.bytes, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "bf6cef92ae8606180b907c4f901734470699b9bb999fed23a744e27eb19644ea");
    if (!std.mem.eql(u8, &digest, &expected)) return error.UnsupportedGameEdition;
    const palette_offset = 5632 + 0x1a680 + 0xf61;
    const actor_colors = [_]palette.Bank{
        try palette.decodeActorBank(executable.bytes[palette_offset..][0..32]),
        try palette.decodeActorBank(executable.bytes[palette_offset + 32 ..][0..32]),
    };
    const text_colors = try palette.decodeActorBank(executable.bytes[palette_offset + 64 ..][0..32]);
    var interface_colors: palette.Bank = undefined;
    for (&interface_colors, 0..) |*color, i| {
        const rgb = executable.bytes[palette_offset + 96 + i * 3 ..][0..3];
        color.* = .{ .r = palette.expandComponent(rgb[0]), .g = palette.expandComponent(rgb[1]), .b = palette.expandComponent(rgb[2]) };
    }
    // Difficulty selection supplies the original inventory label. UI labels
    // come from the checked English overlay; executable offsets stay at this boundary.
    const data_base: usize = 5632 + 0x1a680;
    const difficulty_offset = std.mem.readInt(u16, executable.bytes[data_base + 0x1841 + 2 * @as(usize, @backingInt(difficulty_setting)) ..][0..2], .little);
    const difficulty = try embeddedLabel(executable.bytes, data_base + difficulty_offset);
    const level_prefix = try embeddedLabel(executable.bytes, data_base + 0x186a);
    const level_label = try std.mem.concat(allocator, u8, &.{ level_prefix, difficulty });
    defer allocator.free(level_label);
    var inventory_art = try inventory_artwork.load(allocator, icons.bytes, font_bytes.bytes, level_label);
    errdefer inventory_art.deinit();
    var room_ids: [64]geometry.RoomId = undefined;
    for (&room_ids, 0..) |*id, i| id.* = @fromBackingInt(@as(u16, @intCast(i)) + 1);
    var terrain = try collision.decode(allocator, ct.bytes, &room_ids);
    errdefer terrain.deinit();
    var resolver: Resolver = .{ .allocator = allocator, .sprites = sprites.bytes, .offsets = offsets.bytes, .icons = icons.bytes, .ids = std.AutoHashMap(u16, motion.VisualId).init(allocator) };
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
    const initial_items = try starting_equipment.recover(allocator, placement_table, ani.bytes, rules.bytes, names.bytes, &resolver);
    errdefer starting_equipment.release(allocator, initial_items);
    var room_art: std.ArrayList(RoomArt) = .empty;
    errdefer {
        for (room_art.items) |*room| room.artwork.deinit();
        room_art.deinit(allocator);
    }
    if (map.bytes.len < 384) return error.TruncatedRoomDirectory;
    const first_offset = @abs(std.mem.readInt(i32, map.bytes[@as(usize, player.room) * 6 ..][0..4], .little));
    if (first_offset == 0) return error.MissingRoomArtwork;
    if (first_offset >= map.bytes.len or map.bytes.len - first_offset < 4) return error.InvalidRoomRange;
    const reference_bank = map.bytes[first_offset + 2];
    const icon_colors = try palette.decodeLevelBank(colors.bytes, reference_bank);
    for (0..64) |index| {
        var art = artwork.decode(allocator, map.bytes, colors.bytes, @intCast(index)) catch |err| switch (err) {
            error.AbsentRoom => continue,
            else => return err,
        };
        errdefer art.deinit();
        const offset = @abs(std.mem.readInt(i32, map.bytes[index * 6 ..][0..4], .little));
        const alternate = map.bytes[offset + 2] != reference_bank;
        @memcpy(art.colors[0x40..0x50], &actor_colors[@intFromBool(alternate)]);
        @memcpy(art.colors[0xa0..0xb0], &icon_colors);
        @memcpy(art.colors[0xe0..0xf0], &text_colors);
        @memcpy(art.colors[0xf0..0x100], &interface_colors);
        try room_art.append(allocator, .{ .id = room_ids[index], .artwork = art });
    }
    const rooms = try room_art.toOwnedSlice(allocator);
    errdefer {
        for (rooms) |*room| room.artwork.deinit();
        allocator.free(rooms);
    }
    const facing: motion.Facing = if (player.facing_right == 0) .left else .right;
    const first_visual = switch (motions[@backingInt(Move.wake)].steps[0]) {
        .frame => |frame| frame.visual,
        .hold => return error.UnsupportedPlayerStart,
    };
    const frames = try resolver.frames.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .rooms = rooms,
        .frames = frames,
        .motions = motions,
        .walk_strides = walk,
        .run_strides = run,
        .terrain = terrain,
        .initial_items = initial_items,
        .initial_health = player.life,
        .inventory_art = inventory_art,
        .initial_room = room_ids[player.room],
        .initial_pose = .{ .position = player.position, .facing = facing, .visual = .{ .id = first_visual.id, .mirrored = first_visual.mirrored != (facing == .left) } },
    };
}

fn embeddedLabel(bytes: []const u8, offset: usize) ![]const u8 {
    if (offset >= bytes.len) return error.InvalidInterfaceLabel;
    const tail = bytes[offset..@min(bytes.len, offset + 257)];
    const length = std.mem.indexOfScalar(u8, tail, 0) orelse return error.InvalidInterfaceLabel;
    return tail[0..length];
}
