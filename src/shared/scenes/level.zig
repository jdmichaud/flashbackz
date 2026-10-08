//! A level run entirely by the behavior engine (DESIGN.md section 4): every character, Conrad
//! included, follows its behavior table, and the screen shows the engine's state the way the
//! original presents it (flashback-re docs/rules/engine-presentation.md).
const std = @import("std");
const behavior = @import("../behavior/root.zig");
const level_pack = @import("../content/level_pack.zig");
const character_art = @import("../content/character_art.zig");
const sprite = @import("../content/sprite.zig");
const palette = @import("../content/palette.zig");
const sprite_renderer = @import("../render/sprite.zig");
const text_renderer = @import("../render/text.zig");
const platform = @import("../platform.zig");
const level_mod = @import("../content/level.zig");
const floppy_interface = @import("../content/floppy_interface.zig");
const demo_mod = @import("../content/demo.zig");
const input_recording = @import("../input_recording.zig");
const step_clock = @import("../step_clock.zig");
const settings = @import("../settings.zig");
const audio_effects = @import("../audio/effects.zig");
const World = behavior.world.World;
const data_set = behavior.data_set;
const contacts = behavior.contacts;

pub const width = 256;
pub const height = 224;
const pixel_count = width * height;

/// How a level ends, for the game to act on.
pub const Outcome = union(enum) {
    playing,
    /// An exit to another level.
    level: level_mod.Id,
    /// Conrad's defeat: the continue screen follows.
    defeated,
    /// The player left, or the demo ended.
    aborted,
};

/// A level being played: the engine, the screen, the player's keys and the sound effects.
pub const Scene = struct {
    allocator: std.mem.Allocator,
    /// Owns the level's data set.
    arena: *std.heap.ArenaAllocator,
    level: level_mod.Id,
    data: *const data_set.Level,
    pack: level_pack.Pack,
    world: World,
    screen: *Screen,
    keys: Keys = .{},
    /// A demo replays its recorded input bytes instead of the keys.
    demo: ?Demo = null,
    clock: ?step_clock.Clock = null,
    pending: std.ArrayList(platform.Event) = .empty,
    effects: audio_effects.Output = .{},
    sound_enabled: bool = true,
    outcome: Outcome = .playing,

    pub const Demo = struct { bytes: []u8, cursor: usize = 0 };

    /// Loads `level` from the data set `files` and the original art and sound in `assets`.
    pub fn load(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        level: level_mod.Id,
        difficulty: settings.Difficulty,
    ) !Scene {
        return loadWithStart(allocator, assets, files, level, difficulty, null);
    }

    /// Loads demo `index`: its level, with Conrad where the demo starts, replaying its input.
    pub fn loadDemo(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        index: usize,
    ) !Scene {
        const recording = try demo_mod.load(allocator, assets, index);
        defer allocator.free(recording.controls);
        const start: ?World.Start = if (recording.descriptor.start) |start| .{
            .room = @intCast(@backingInt(start.room) - 1),
            .x = start.position.x,
            .y = start.position.y,
        } else null;
        var scene = try loadWithStart(
            allocator,
            assets,
            files,
            recording.descriptor.level,
            .normal,
            start,
        );
        errdefer scene.deinit();
        const bytes = try allocator.alloc(u8, recording.controls.len);
        for (bytes, recording.controls) |*byte, sample| byte.* = inputByte(sample);
        scene.demo = .{ .bytes = bytes };
        scene.screen.password_frames = 0;
        // Demos replay from a fixed random state.
        scene.world.random.state = 0;
        return scene;
    }

    fn loadWithStart(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        level: level_mod.Id,
        difficulty: settings.Difficulty,
        start: ?World.Start,
    ) !Scene {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        var diagnostic: data_set.Diagnostic = .{};
        const data = try arena.allocator().create(data_set.Level);
        data.* = data_set.loadLevel(
            allocator,
            arena.allocator(),
            files,
            @tagName(level),
            &diagnostic,
        ) catch |err| {
            std.log.err("data set: {s}", .{diagnostic.message()});
            return err;
        };
        const interface = try floppy_interface.load(allocator, assets);
        const first_room = if (start) |s| s.room else data.characters[0].room orelse 0;
        var pack = try level_pack.load(allocator, assets, &interface, level, difficulty, first_room);
        errdefer pack.deinit();
        var world = try World.init(
            allocator,
            data,
            pack.animations,
            pack.grid,
            @fromBackingInt(@backingInt(difficulty)),
            start,
        );
        errdefer world.deinit();
        const screen = try allocator.create(Screen);
        screen.* = .init(start != null);
        return .{
            .allocator = allocator,
            .arena = arena,
            .level = level,
            .data = data,
            .pack = pack,
            .world = world,
            .screen = screen,
        };
    }

    pub fn deinit(self: *Scene) void {
        if (self.demo) |demo| self.allocator.free(demo.bytes);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self.screen);
        self.world.deinit();
        self.pack.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn enqueue(self: *Scene, event: platform.Event) !void {
        switch (event.payload) {
            .key_down, .key_up, .focus_lost => try self.pending.append(self.allocator, event),
            else => {},
        }
    }

    /// Runs the updates due by `now_ns`, at the original's cadence.
    pub fn update(self: *Scene, now_ns: u64) !void {
        if (self.clock == null) self.clock = try step_clock.Clock.init(step_clock.jungle, now_ns);
        var work: usize = 0;
        while (self.outcome == .playing and self.needsCatchup(now_ns) and work < 8) : (work += 1) {
            const deadline = self.clock.?.deadline();
            self.clock.?.consume();
            try self.step(deadline);
        }
    }

    pub fn nextDeadline(self: *const Scene) ?u64 {
        return if (self.clock) |clock| clock.deadline() else null;
    }

    pub fn needsCatchup(self: *const Scene, now_ns: u64) bool {
        if (self.outcome != .playing) return false;
        return if (self.nextDeadline()) |time| now_ns >= time else false;
    }

    /// One update with the input held at `deadline`.
    fn step(self: *Scene, deadline: u64) !void {
        const held = self.takeKeys(deadline);
        // Esc leaves (the options dialog is not modeled yet); Tab or Backspace ends a demo.
        if (self.keys.escape or (self.demo != null and held & 0x80 != 0)) {
            self.outcome = .aborted;
            return;
        }
        const raw = if (self.demo) |*demo| byte: {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return;
            }
            demo.cursor += 1;
            break :byte demo.bytes[demo.cursor - 1];
        } else held;
        const outcome = try self.world.update(@bitCast(self.keys.collapse(raw)), false);
        for (self.world.requests.sounds[0..self.world.requests.sound_count]) |sound| {
            if (self.sound_enabled) self.effects.submit(self.pack.sounds, .{
                .sound = @fromBackingInt(sound.id),
                .attenuation = @intFromBool(sound.distant),
            });
        }
        switch (outcome) {
            .played => try self.screen.present(&self.pack, &self.world),
            .defeated => self.outcome = .defeated,
            .level_changed => self.outcome = .{
                .level = std.enums.fromInt(level_mod.Id, self.world.requests.level.?) orelse
                    return error.UnknownLevel,
            },
        }
    }

    /// The keys held at `deadline`, from the events that arrived by then.
    fn takeKeys(self: *Scene, deadline: u64) u8 {
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            switch (event.payload) {
                .focus_lost => self.keys = .{ .last_direction = self.keys.last_direction },
                .key_down => |key| self.keys.press(key.key, true),
                .key_up => |key| self.keys.press(key.key, false),
                else => {},
            }
        }
        return self.keys.held;
    }

    /// Every character's state, the score, the view and the random state.
    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(@backingInt(self.level));
        for (self.world.characters) |c| {
            hash.update(std.mem.asBytes(&[_]i32{
                c.state,       c.cursor,                      c.x,                          c.y,
                c.room,        c.health,                      c.counter,                    @intFromBool(c.active),
                c.look.sprite, @intFromBool(c.look.mirrored), @intFromBool(c.facing_right),
            }));
        }
        hash.update(std.mem.asBytes(&[_]u32{
            self.world.score,
            self.world.view_room,
            self.world.random.state,
        }));
        return hash.final();
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        @memcpy(indices, &self.screen.picture);
        try self.screen.writeRgba(rgba);
    }

    pub fn pumpAudio(self: *Scene, p: *platform.Platform) !void {
        if (!self.sound_enabled) return self.effects.stop(p);
        try self.effects.pump(self.pack.sounds, p);
    }

    pub fn stopAudio(self: *Scene, p: *platform.Platform) void {
        self.effects.stop(p);
    }
};

/// The keyboard as the original reads it: one byte of held keys (no edge detection) and the
/// last direction held without a diagonal.
pub const Keys = struct {
    held: u8 = 0,
    last_direction: u8 = 0,
    escape: bool = false,

    pub fn press(self: *Keys, key: platform.Key, down: bool) void {
        const bit: u8 = switch (key) {
            .up => 0x01,
            .down => 0x02,
            .left => 0x04,
            .right => 0x08,
            .enter => 0x10,
            .space => 0x20,
            .left_shift, .right_shift => 0x40,
            .tab, .backspace => 0x80,
            .escape => {
                self.escape = down;
                return;
            },
            else => return,
        };
        if (down) self.held |= bit else self.held &= ~bit;
    }

    /// Holding a vertical and a horizontal direction keeps the last single direction, with the
    /// buttons held now.
    pub fn collapse(self: *Keys, raw: u8) u8 {
        if (raw & 0x03 != 0 and raw & 0x0c != 0) return (raw & 0xf0) | (self.last_direction & 0x0f);
        self.last_direction = raw;
        return raw;
    }
};

fn inputByte(sample: input_recording.Sample) u8 {
    var byte: u8 = 0;
    if (sample.up) byte |= 0x01;
    if (sample.down) byte |= 0x02;
    if (sample.left) byte |= 0x04;
    if (sample.right) byte |= 0x08;
    if (sample.use_item) byte |= 0x10;
    if (sample.weapon) byte |= 0x20;
    if (sample.action) byte |= 0x40;
    if (sample.inventory) byte |= 0x80;
    return byte;
}

test "diagonals keep the last single direction with the current buttons" {
    var keys: Keys = .{};
    try std.testing.expectEqual(@as(u8, 0x08), keys.collapse(0x08));
    try std.testing.expectEqual(@as(u8, 0x48), keys.collapse(0x49));
    try std.testing.expectEqual(@as(u8, 0x03), keys.collapse(0x03));
    try std.testing.expectEqual(@as(u8, 0x23), keys.collapse(0x25));
}

/// What the screen keeps between updates.
pub const Screen = struct {
    /// The background page: the view room, with the HUD icon painted into it.
    background: [pixel_count]u8 = @splat(0),
    /// Background pixels that hide sprites: the room's foreground and the HUD icon.
    foreground: [pixel_count]bool = @splat(false),
    /// The picture on display and the colors it is shown with.
    picture: [pixel_count]u8 = @splat(0),
    colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    /// Room loads already shown.
    room_loads: u32 = 0,
    /// After a room load, the screen keeps the old picture for two updates and shows the new
    /// room, with its colors, on the third.
    room_countdown: u8 = 0,
    hud_icon: ?u8 = null,
    /// The enemy library loaded, and the last rule group (here: behavior) resolved to one.
    library: ?data_set.SpriteLibrary = null,
    library_behavior: ?u16 = null,
    /// Frames left showing the level's password; none in demos.
    password_frames: u8,
    checkpoint_saves: u32 = 0,
    /// "COMPLETED" shows while Conrad touches the save terminal after saving.
    completed: bool = false,

    pub fn init(demo: bool) Screen {
        return .{ .password_frames = if (demo) 0 else 150 };
    }

    /// Presents the engine's state after an update.
    pub fn present(self: *Screen, pack: *const level_pack.Pack, world: *const World) !void {
        if (world.room_loads != self.room_loads) {
            self.room_loads = world.room_loads;
            self.loadRoom(pack, world.view_room);
        }
        if (world.checkpoint_saves != self.checkpoint_saves) {
            self.checkpoint_saves = world.checkpoint_saves;
            self.completed = true;
        }
        if (self.room_countdown > 1) {
            self.room_countdown -= 1;
            return;
        }
        try self.paintHudIcon(pack, world);
        @memcpy(&self.picture, &self.background);
        var lists: Lists = .{};
        self.queueAll(pack, world, &lists);
        try self.render(&lists, world);
        try self.drawLabel(pack, world);
        try self.drawPassword(pack);
        if (self.room_countdown == 1) {
            self.room_countdown = 0;
            self.setRoomColors(pack, world.view_room);
        }
    }

    pub fn writeRgba(self: *const Screen, rgba: []u8) !void {
        try palette.writeRgba(&self.picture, &self.colors, rgba);
    }

    fn loadRoom(self: *Screen, pack: *const level_pack.Pack, room: u8) void {
        if (pack.room(room)) |art| {
            @memcpy(&self.background, art.image.pixels);
            @memcpy(&self.foreground, art.foreground);
        } else {
            @memset(&self.background, 0);
            @memset(&self.foreground, false);
        }
        self.hud_icon = null;
        self.room_countdown = 3;
    }

    /// The new room's colors, set after its first frame shows. The enemy library's block and
    /// the film blocks are left as they are.
    fn setRoomColors(self: *Screen, pack: *const level_pack.Pack, room: u8) void {
        const art = pack.room(room) orelse return;
        for ([_]usize{ 0, 1, 2, 3, 4, 8, 9, 10, 11, 14, 15 }) |block| {
            @memcpy(self.colors[block * 16 ..][0..16], art.colors[block * 16 ..][0..16]);
        }
    }

    /// The selected item's icon is painted into the background, where it hides sprites. It is
    /// painted over the previous one without clearing, and stays when the inventory empties.
    fn paintHudIcon(self: *Screen, pack: *const level_pack.Pack, world: *const World) !void {
        const item = world.characters[0].first_item orelse return;
        const icon = world.level.characters[item].inventory_icon;
        if (self.hud_icon == icon) return;
        self.hud_icon = icon;
        const frame = iconFrame(pack, icon) orelse return;
        for (0..16) |row| for (0..16) |column| {
            const pixel = frame.image.pixels[row * 16 + column];
            if (pixel == 0) continue;
            const at = (8 + row) * width + 232 + column;
            self.background[at] = 0xa0 | pixel;
            self.foreground[at] = true;
        };
    }

    // Characters --------------------------------------------------------------------------

    const Layer = enum { behind, conrad, normal, overlay };

    const Entry = struct {
        frame: *const sprite.Frame,
        x: i32,
        y: i32,
        mirrored: bool,
        bank: u4,
        character: u16,
    };

    const Lists = struct {
        entries: [4][64]Entry = undefined,
        counts: [4]u8 = @splat(0),

        fn add(self: *Lists, layer: Layer, entry: Entry) void {
            const list = @backingInt(layer);
            if (self.counts[list] == self.entries[list].len) return;
            self.entries[list][self.counts[list]] = entry;
            self.counts[list] += 1;
        }
    };

    /// The view room's characters, then those of the rooms above, below, left and right whose
    /// position reaches into the view.
    fn queueAll(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
    ) void {
        const view = world.view_room;
        if (view >= 64) return;
        self.queueRoom(pack, world, lists, view, .view);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .up), .up);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .down), .down);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .left), .left);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .right), .right);
    }

    const Strip = enum { view, up, down, left, right };

    fn queueRoom(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
        room: u8,
        strip: Strip,
    ) void {
        if (room >= 64) return;
        var next = world.room_lists[room];
        while (next) |index| : (next = world.characters[index].next_in_room) {
            const character = world.characters[index];
            const offset: [2]i32 = switch (strip) {
                .view => .{ 0, 0 },
                .up => if (character.y > @as(i16, if (isEnemy(world, index)) 216 else 176))
                    .{ 0, -216 }
                else
                    continue,
                .down => if (character.y < 48) .{ 0, 216 } else continue,
                .left => if (character.x > 224) .{ -256, 0 } else continue,
                .right => if (character.x <= 32) .{ 256, 0 } else continue,
            };
            self.queue(pack, world, lists, index, offset[0], offset[1]);
        }
    }

    fn queue(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
        index: u16,
        dx: i32,
        dy: i32,
    ) void {
        const character = world.characters[index];
        const definition = world.level.characters[index];
        const look = character.look;
        const key: character_art.Key = .{ .sprite = look.sprite, .composed = look.composed };
        const x = @as(i32, character.x) + dx;
        const y = @as(i32, character.y) + dy;
        if (look.composed) {
            // Composed object art: one of the room's four blocks, never culled here.
            const frame = pack.characters.get(key) orelse return;
            const layer: Layer = if (lowByte(definition.kind) == 11)
                .overlay
            else if (definition.behind_player) .behind else .normal;
            lists.add(layer, .{
                .frame = frame,
                .x = x + 8,
                .y = y + 2,
                .mirrored = look.mirrored,
                .bank = @intCast(definition.palette_bank & 3),
                .character = index,
            });
            return;
        }
        if (index != 0 and !self.libraryReady(pack, world, index)) return;
        const frame = pack.characters.get(key) orelse return;
        const w: i32 = frame.image.width;
        const left = if (look.mirrored) x + frame.origin_x - w else x - frame.origin_x;
        const top = y - frame.origin_y + 2;
        if (left <= -32 or left >= 256 or top <= -48 or top >= 224) return;
        const layer: Layer = if (index == 0)
            .conrad
        else if (definition.behind_player) .behind else .normal;
        lists.add(layer, .{
            .frame = frame,
            .x = x + 8,
            .y = y + 2,
            .mirrored = look.mirrored,
            .bank = if (definition.palette_bank & 3 == 3) 5 else 4,
            .character = index,
        });
    }

    /// Enemies draw library sprites only once their library is loaded. The library follows the
    /// enemies queued in the view room; elsewhere only the last group resolved is drawn.
    fn libraryReady(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        index: u16,
    ) bool {
        const definition = world.level.characters[index];
        const library = definition.sprite_library orelse return true;
        if (self.library_behavior == definition.behavior) return true;
        if (world.characters[index].room != world.view_room) return false;
        if (library == .none) return false;
        self.library_behavior = definition.behavior;
        if (self.library == library) return true;
        self.library = library;
        // The library's colors take effect at once.
        @memcpy(self.colors[0x50..0x60], &pack.library_colors[@backingInt(library)]);
        return true;
    }

    /// Bottom to top: the behind list, Conrad, the others, then overlay art. Within a list the
    /// character queued first ends on top. Conrad blinks while his protection is odd.
    fn render(self: *Screen, lists: *const Lists, world: *const World) !void {
        for (std.enums.values(Layer)) |layer| {
            const list = @backingInt(layer);
            var k = lists.counts[list];
            while (k > 0) {
                k -= 1;
                const entry = lists.entries[list][k];
                if (layer == .conrad and world.protection & 1 != 0) continue;
                try sprite_renderer.draw(
                    &self.picture,
                    width,
                    height,
                    entry.frame,
                    entry.x,
                    entry.y,
                    .{
                        .palette_bank = entry.bank,
                        .facing = if (entry.mirrored) .mirrored else .original,
                        .foreground = if (layer == .overlay) .overwrite else .respect,
                        .occlusion = &self.foreground,
                    },
                );
            }
        }
    }

    // Texts --------------------------------------------------------------------------------

    /// The icon and name of what Conrad touches: an item in his first cell, else a character
    /// of kind 5 or 9. Touching anything ends the password display.
    fn drawLabel(self: *Screen, pack: *const level_pack.Pack, world: *const World) !void {
        const found = labelTarget(world) orelse {
            self.completed = false;
            return;
        };
        self.password_frames = 0;
        if (iconFrame(pack, found.icon - 1)) |frame| drawIcon(&self.picture, frame, 80, 8);
        const name = world.level.characters[found.character].label;
        try self.drawText(pack, name, 88 - 4 * @as(i32, @intCast(name.len)), 26, 0xe6);
        if (found.icon != 3) {
            self.completed = false;
        } else if (self.completed) {
            try self.drawText(pack, "COMPLETED", 88 - 4 * 9, 34, 0xe6);
        }
    }

    fn drawPassword(self: *Screen, pack: *const level_pack.Pack) !void {
        if (self.password_frames == 0) return;
        self.password_frames -= 1;
        if (self.password_frames == 0) return;
        const text = std.mem.sliceTo(&pack.password, 0);
        try self.drawText(pack, text, 128 - 4 * @as(i32, @intCast(text.len)), 16, 0xe7);
    }

    fn drawText(
        self: *Screen,
        pack: *const level_pack.Pack,
        text: []const u8,
        x: i32,
        y: i32,
        ink: u8,
    ) !void {
        try text_renderer.draw(&self.picture, width, height, &pack.font, text, x, y, .{
            .foreground = ink,
            .shadow = 0xe2,
            .palette_bank = 14,
        });
    }
};

const Label = struct { icon: u8, character: u16 };

/// The first search looks for an item (kind 3) among the characters in Conrad's first cell,
/// newest first, Conrad included. If none has an icon, a second search for kinds 5 and 9 starts
/// from the first cell of the last character the first search examined.
fn labelTarget(world: *const World) ?Label {
    var last: u16 = 0;
    if (search(world, 0, &.{ 3, 0xff }, &last)) |found| if (positive(found.icon)) return found;
    if (search(world, last, &.{ 0xff, 5, 9 }, &last)) |found| if (positive(found.icon)) return found;
    return null;
}

/// Icons compare as signed bytes.
fn positive(icon: u8) bool {
    return @as(i8, @bitCast(icon)) > 0;
}

fn search(world: *const World, who: u16, kinds: []const u8, last: *u16) ?Label {
    const slot = world.characters[who].contact;
    if (slot == contacts.no_slot) return null;
    var occupants = world.contacts.occupants(slot);
    while (occupants.nextEntry()) |entry| {
        last.* = entry.character;
        const definition = world.level.characters[entry.character];
        if (std.mem.indexOfScalar(u8, kinds, lowByte(definition.kind)) == null) continue;
        return .{ .icon = definition.contact_icon, .character = entry.character };
    }
    return null;
}

fn isEnemy(world: *const World, index: u16) bool {
    return lowByte(world.level.characters[index].kind) == 10;
}

fn lowByte(kind: behavior.vocabulary.Kind) u8 {
    return @truncate(@as(u16, @bitCast(@backingInt(kind))));
}

fn iconFrame(pack: *const level_pack.Pack, icon: u8) ?*const sprite.Frame {
    if (icon >= pack.icons.len) return null;
    return &pack.icons[icon];
}

/// Icons draw their nonzero pixels with the icon colors, over anything.
fn drawIcon(picture: []u8, frame: *const sprite.Frame, x: usize, y: usize) void {
    for (0..16) |row| for (0..16) |column| {
        const pixel = frame.image.pixels[row * 16 + column];
        if (pixel != 0) picture[(y + row) * width + x + column] = 0xa0 | pixel;
    };
}
