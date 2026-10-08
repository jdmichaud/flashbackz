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
const inventory_menu = @import("inventory_menu.zig");
const game_options = @import("game_options.zig");
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
    messages: data_set.Messages,
    scenes: data_set.Scenes,
    pack: level_pack.Pack,
    world: World,
    screen: *Screen,
    keys: Keys = .{},
    /// A demo replays its recorded input bytes instead of the keys.
    demo: ?Demo = null,
    clock: ?step_clock.Clock = null,
    /// While a world message shows, the keys are polled every three display refreshes and the
    /// world waits.
    message_clock: ?step_clock.Clock = null,
    pending: std.ArrayList(platform.Event) = .empty,
    effects: audio_effects.Output = .{},
    settings: game_options.Settings = .{},
    outcome: Outcome = .playing,
    /// The options dialog, opened with Esc; the world waits while it is open.
    options: ?Options = null,
    /// Presented frames before the inventory key works: 4 after the level starts, 10 after the
    /// inventory closes.
    inventory_delay: u8 = 4,
    inventory: ?Inventory = null,
    /// The scene the last update requested: it plays at the start of the next one.
    requested_scene: ?i16 = null,
    /// A film the game must play now; the update waits for it with its input latched.
    film: ?data_set.Film = null,
    after_film: u8 = 0,

    const Options = struct { menu: game_options.Menu, clock: step_clock.Clock };

    const Inventory = struct {
        menu: inventory_menu.Menu,
        keys: inventory_menu.Keys = .{},
        clock: step_clock.Clock,
        items: [max_items]u16 = undefined,
        entries: [max_items]inventory_menu.Entry = undefined,
        const max_items = 32;
    };

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
        const messages = data_set.loadMessages(
            allocator,
            arena.allocator(),
            files,
            &diagnostic,
        ) catch |err| {
            std.log.err("data set: {s}", .{diagnostic.message()});
            return err;
        };
        const scenes = data_set.loadScenes(
            allocator,
            arena.allocator(),
            files,
            &diagnostic,
        ) catch |err| {
            std.log.err("data set: {s}", .{diagnostic.message()});
            return err;
        };
        const interface = try floppy_interface.load(allocator, assets);
        const first_room = if (start) |s| s.room else data.characters[0].room orelse 0;
        var pack = try level_pack.load(
            allocator,
            assets,
            &interface,
            level,
            difficulty,
            first_room,
        );
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
            .messages = messages,
            .scenes = scenes,
            // Demos start without their level's opening scene.
            .requested_scene = if (start != null) null else openingScene(scenes, level),
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
        while (self.outcome == .playing and self.film == null and self.needsCatchup(now_ns) and
            work < 8) : (work += 1)
        {
            if (self.options) |*options| {
                const deadline = options.clock.deadline();
                options.clock.consume();
                self.pollOptions(deadline);
                continue;
            }
            if (self.inventory) |*inventory| {
                const deadline = inventory.clock.deadline();
                inventory.clock.consume();
                try self.pollInventory(deadline);
                continue;
            }
            if (self.message_clock) |*clock| {
                const deadline = clock.deadline();
                clock.consume();
                try self.pollMessage(deadline);
                continue;
            }
            const deadline = self.clock.?.deadline();
            self.clock.?.consume();
            const controls = try self.step(deadline);
            if (self.film != null) return;
            try self.afterFrame(controls, deadline);
        }
    }

    /// After a presented frame: a world message opens, else Esc opens the options (it ends a
    /// demo), else the inventory key is checked.
    fn afterFrame(self: *Scene, controls: u8, now_ns: u64) !void {
        if (self.screen.message != null) {
            try self.openMessage(now_ns);
        } else if (self.outcome != .playing) {
            return;
        } else if (self.keys.escape) {
            self.keys.escape = false;
            if (self.demo != null) {
                self.outcome = .aborted;
                return;
            }
            self.options = .{
                .menu = .{ .settings = self.settings },
                .clock = try step_clock.Clock.init(step_clock.inventory, now_ns),
            };
            self.keys.release();
        } else {
            try self.checkInventoryKey(controls, now_ns);
        }
    }

    /// The options dialog takes key presses; resuming applies its settings, and abandoning the
    /// game leads to the continue screen, as a defeat does.
    fn pollOptions(self: *Scene, deadline: u64) void {
        const options = &self.options.?;
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            if (event.payload == .key_down) options.menu.key(event.payload.key_down.key);
        }
        const outcome = options.menu.outcome orelse return;
        self.settings = options.menu.settings;
        const paused = deadline -| options.clock.origin_ns;
        self.options = null;
        self.keys.release();
        self.clock.?.origin_ns +|= paused;
        if (outcome == .abort_game) self.outcome = .defeated;
    }

    pub fn nextDeadline(self: *const Scene) ?u64 {
        if (self.options) |options| return options.clock.deadline();
        if (self.inventory) |inventory| return inventory.clock.deadline();
        if (self.message_clock) |clock| return clock.deadline();
        return if (self.clock) |clock| clock.deadline() else null;
    }

    /// The world message takes the keyboard: keys held now count only once released.
    fn openMessage(self: *Scene, now_ns: u64) !void {
        var cadence = step_clock.inventory;
        cadence.initial_gap_ticks = 3;
        cadence.regular_gap_ticks = 3;
        self.message_clock = try step_clock.Clock.init(cadence, now_ns);
        self.message_clock.?.consume();
        self.keys.release();
    }

    /// Enter, Space or Shift turns the page; after the last, play resumes.
    fn pollMessage(self: *Scene, deadline: u64) !void {
        const held = if (self.demo) |*demo| byte: {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return;
            }
            demo.cursor += 1;
            break :byte demo.bytes[demo.cursor - 1];
        } else self.takeKeys(deadline);
        if (held & 0x70 == 0) return;
        self.keys.release();
        if (try self.screen.nextMessagePage(&self.pack, self.messages)) return;
        // The world resumes where it stopped.
        const paused = deadline -| self.message_clock.?.origin_ns;
        self.message_clock = null;
        self.clock.?.origin_ns +|= paused;
    }

    pub fn needsCatchup(self: *const Scene, now_ns: u64) bool {
        if (self.outcome != .playing or self.film != null) return false;
        return if (self.nextDeadline()) |time| now_ns >= time else false;
    }

    /// One update with the input held at `deadline`; returns the input byte it used.
    fn step(self: *Scene, deadline: u64) !u8 {
        const held = self.takeKeys(deadline);
        // Tab or Backspace ends a demo.
        if (self.demo != null and held & 0x80 != 0) {
            self.outcome = .aborted;
            return 0;
        }
        const raw = if (self.demo) |*demo| byte: {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return 0;
            }
            demo.cursor += 1;
            break :byte demo.bytes[demo.cursor - 1];
        } else held;
        const controls = self.keys.collapse(raw);
        // A scene requested by the last update plays before this update's walk.
        if (self.requested_scene) |scene| {
            self.requested_scene = null;
            if (self.scenes.film(scene)) |film| {
                self.film = film;
                self.after_film = controls;
                return controls;
            }
        }
        try self.walk(controls);
        return controls;
    }

    /// The player chose to continue after a defeat: play resumes from the last checkpoint, at
    /// the score the level was entered with unless the checkpoint saved another. False when
    /// no checkpoint was saved: the level must start again.
    pub fn continueAfterDefeat(self: *Scene) bool {
        self.world.score = self.world.entry_score;
        if (!self.world.restoreCheckpoint()) return false;
        self.outcome = .playing;
        self.clock = null;
        self.message_clock = null;
        self.inventory = null;
        self.inventory_delay = 4;
        self.requested_scene = null;
        self.film = null;
        self.keys = .{ .last_direction = self.keys.last_direction };
        self.screen.hud_icon = null;
        self.screen.message = null;
        self.screen.pending_message = null;
        return true;
    }

    /// The film has played: the view reloads after this update's walk, held keys are
    /// released, and the inventory waits again.
    pub fn finishFilm(self: *Scene, now_ns: u64, paused_for: u64) !void {
        self.film = null;
        if (self.outcome != .playing) return;
        self.world.view_dirty = true;
        self.inventory_delay = 10;
        self.keys.release();
        self.clock.?.origin_ns +|= paused_for;
        try self.walk(self.after_film);
        try self.afterFrame(self.after_film, now_ns);
    }

    fn walk(self: *Scene, controls: u8) !void {
        const outcome = try self.world.update(@bitCast(controls), false);
        for (self.world.requests.sounds[0..self.world.requests.sound_count]) |sound| {
            if (self.settings.sound_fx) self.effects.submit(self.pack.sounds, .{
                .sound = @fromBackingInt(sound.id),
                .attenuation = @intFromBool(sound.distant),
            });
        }
        switch (outcome) {
            .played => {
                if (self.world.requests.scene) |scene| self.requested_scene = scene;
                try self.screen.present(&self.pack, self.messages, &self.world);
            },
            // The defeat scene plays before the continue screen.
            .defeated => {
                self.outcome = .defeated;
                if (self.world.requests.scene) |scene| self.film = self.scenes.film(scene);
            },
            .level_changed => self.outcome = .{
                .level = std.enums.fromInt(level_mod.Id, self.world.requests.level.?) orelse
                    return error.UnknownLevel,
            },
        }
    }

    /// After each presented frame, the inventory key opens the inventory once the delay has
    /// run out. With no items, or Conrad without health, it closes at once.
    fn checkInventoryKey(self: *Scene, controls: u8, deadline: u64) !void {
        if (self.inventory_delay != 0) {
            self.inventory_delay -= 1;
            return;
        }
        if (controls & 0x80 == 0) return;
        self.keys.release();
        if (self.world.characters[0].health <= 0) return;
        var inventory: Inventory = .{
            .menu = undefined,
            .clock = try step_clock.Clock.init(step_clock.inventory, deadline),
        };
        var count: usize = 0;
        var next = self.world.characters[0].first_item;
        while (next) |item| : (next = self.world.characters[item].next_item) {
            if (count == Inventory.max_items) break;
            const definition = self.data.characters[item];
            const icon = iconFrame(&self.pack, definition.inventory_icon) orelse continue;
            inventory.items[count] = item;
            inventory.entries[count] = .{
                .icon = icon,
                .label = definition.label,
                // Items with the quantity flag show their health: charges, credits.
                .quantity = if (definition.other_visual_flags & 4 != 0)
                    @bitCast(self.world.characters[item].health)
                else
                    null,
            };
            count += 1;
        }
        inventory.menu = inventory_menu.Menu.init(count) catch return;
        self.inventory = inventory;
    }

    /// One poll of the inventory: directions move, a button shows the score, the inventory key
    /// closes it and selects the item shown.
    fn pollInventory(self: *Scene, deadline: u64) !void {
        const inventory = &self.inventory.?;
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            switch (event.payload) {
                .key_down => |key| try inventory.keys.key(key.key, true),
                .key_up => |key| try inventory.keys.key(key.key, false),
                .focus_lost => inventory.keys = .{},
                else => {},
            }
        }
        if (self.demo) |*demo| {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return;
            }
            const byte = demo.bytes[demo.cursor];
            demo.cursor += 1;
            inventory.keys.directions = .{
                .up = byte & 0x01 != 0,
                .down = byte & 0x02 != 0,
                .left = byte & 0x04 != 0,
                .right = byte & 0x08 != 0,
            };
            inventory.keys.enter = byte & 0x10 != 0;
            inventory.keys.space = byte & 0x20 != 0;
            inventory.keys.left_shift = byte & 0x40 != 0;
            inventory.keys.tab = byte & 0x80 != 0;
        }
        switch (inventory.menu.poll(inventory.keys.sample())) {
            .stay => {},
            .choose => |index| {
                self.world.selectItem(0, inventory.items[index]);
                const paused = deadline -| inventory.clock.origin_ns;
                self.inventory = null;
                self.inventory_delay = 10;
                self.keys.release();
                self.clock.?.origin_ns +|= paused;
            },
        }
    }

    /// The keys held at `deadline`, from the events that arrived by then.
    fn takeKeys(self: *Scene, deadline: u64) u8 {
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            switch (event.payload) {
                .focus_lost => self.keys.lose(),
                .key_down => |key| self.keys.press(key.key, true, key.repeat),
                .key_up => |key| self.keys.press(key.key, false, false),
                else => {},
            }
        }
        return self.keys.held;
    }

    /// Every character's state and inventory links, the score, the view and the random state.
    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(@backingInt(self.level));
        for (self.world.characters) |c| {
            const fields = [_]i32{
                c.state,
                c.cursor,
                c.x,
                c.y,
                c.room,
                c.health,
                c.counter,
                @intFromBool(c.active),
                @intFromBool(c.facing_right),
                c.look.sprite,
                @intFromBool(c.look.mirrored),
                if (c.first_item) |item| item else -1,
                if (c.next_item) |item| item else -1,
            };
            hash.update(std.mem.asBytes(&fields));
        }
        const globals = [_]u32{ self.world.score, self.world.view_room, self.world.random.state };
        hash.update(std.mem.asBytes(&globals));
        return hash.final();
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        var picture = self.screen.picture;
        if (self.inventory) |inventory| try inventory.menu.draw(
            self.pack.inventory.artwork(),
            inventory.entries[0..inventory.menu.count],
            self.world.score,
            &picture,
            width,
            height,
        );
        if (self.options) |options| try options.menu.draw(&picture, &self.pack.font);
        self.screen.display(&picture, indices[0..pixel_count]);
        try palette.writeRgba(indices, &self.screen.colors, rgba);
    }

    pub fn pumpAudio(self: *Scene, p: *platform.Platform) !void {
        self.effects.volume = self.settings.volume;
        if (self.options != null or !self.settings.sound_fx) return self.effects.stop(p);
        try self.effects.pump(self.pack.sounds, p);
    }

    pub fn stopAudio(self: *Scene, p: *platform.Platform) void {
        self.effects.stop(p);
    }
};

/// The keyboard as the original reads it: one byte of held keys (no edge detection) and the
/// last direction held without a diagonal. After a modal screen the held keys are released:
/// a key still down counts again only when pressed anew (or when the keyboard repeats it).
pub const Keys = struct {
    held: u8 = 0,
    /// Keys physically down, and those of them released by a modal screen.
    down: u8 = 0,
    ignored: u8 = 0,
    last_direction: u8 = 0,
    escape: bool = false,

    pub fn release(self: *Keys) void {
        self.ignored |= self.down;
        self.held = 0;
    }

    pub fn lose(self: *Keys) void {
        self.* = .{ .last_direction = self.last_direction };
    }

    pub fn press(self: *Keys, key: platform.Key, down: bool, repeat: bool) void {
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
        if (down) {
            self.down |= bit;
            if (repeat) self.ignored &= ~bit;
            if (self.ignored & bit == 0) self.held |= bit;
        } else {
            self.down &= ~bit;
            self.ignored &= ~bit;
            self.held &= ~bit;
        }
    }

    /// Holding a vertical and a horizontal direction keeps the last single direction, with the
    /// buttons held now.
    pub fn collapse(self: *Keys, raw: u8) u8 {
        if (raw & 0x03 != 0 and raw & 0x0c != 0) return (raw & 0xf0) | (self.last_direction & 0x0f);
        self.last_direction = raw;
        return raw;
    }
};

fn openingScene(scenes: data_set.Scenes, level: level_mod.Id) ?i16 {
    const scene = switch (level) {
        inline else => |id| @field(scenes.openings, @tagName(id)),
    };
    return if (scene) |number| number else null;
}

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

test "a key held through a modal screen counts again only once pressed anew" {
    var keys: Keys = .{};
    keys.press(.enter, true, false);
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
    keys.release();
    try std.testing.expectEqual(@as(u8, 0), keys.held);
    keys.press(.enter, true, false);
    try std.testing.expectEqual(@as(u8, 0), keys.held);
    keys.press(.enter, true, true);
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
    keys.release();
    keys.press(.enter, false, false);
    keys.press(.enter, true, false);
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
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
    /// A world message waits until the room shows, then pages over the frame it froze.
    pending_message: ?u16 = null,
    message: ?ShownMessage = null,
    /// The frame under the message.
    under_message: [pixel_count]u8 = @splat(0),
    /// Pages alternate between the two video pages. After each flip, the page about to be
    /// drawn gets the texts and icons it showed earlier wiped with the background, which then
    /// holds the frozen frame's message area (16, 26, 128x32).
    pages: [2][pixel_count]u8 = undefined,
    page_rects: [2]Rects = .{ .{}, .{} },
    page_buffer: u1 = 0,
    message_background: [pixel_count]u8 = undefined,
    /// The rectangles of the texts and icons drawn this frame and the previous one.
    frame_rects: Rects = .{},
    previous_rects: Rects = .{},
    /// A new HUD icon reaches the picture when it is flipped, after any message.
    hud_unshown: bool = false,
    /// The screen shake moves the displayed picture down by 0 to 3 rows. Each flip takes the
    /// value computed after the previous one.
    shake_rows: u2 = 0,
    next_shake_rows: u2 = 0,
    /// The icon beside the message: what Conrad touched while one was pending (it can be
    /// stale, as in the original).
    message_icon: u8 = 0,

    pub const ShownMessage = struct { number: u16, page: usize = 0 };

    const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
    const Rects = struct {
        items: [16]Rect = undefined,
        count: u8 = 0,

        fn add(self: *Rects, rect: Rect) void {
            if (self.count == self.items.len) return;
            self.items[self.count] = rect;
            self.count += 1;
        }
    };

    pub fn init(demo: bool) Screen {
        return .{ .password_frames = if (demo) 0 else 150 };
    }

    /// Presents the engine's state after an update.
    pub fn present(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
        world: *const World,
    ) !void {
        if (world.requests.world_message) |number| {
            if (number >= 0) self.pending_message = @intCast(number);
        }
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
        @memcpy(&self.picture, &self.background);
        var lists: Lists = .{};
        self.queueAll(pack, world, &lists);
        try self.render(&lists, world);
        self.frame_rects = .{};
        try self.drawLabel(pack, world);
        try self.drawPassword(pack);
        try self.paintHudIcon(pack, world);
        if (self.pending_message) |number| {
            self.pending_message = null;
            if (number < messages.len and messages[number].len != 0) {
                try self.openMessage(pack, messages, number);
            }
        }
        if (self.message == null) self.showHudIcon(pack);
        self.previous_rects = self.frame_rects;
        self.shake_rows = self.next_shake_rows;
        self.next_shake_rows = @truncate(@as(u8, @bitCast(world.shake)));
        if (self.room_countdown == 1) {
            self.room_countdown = 0;
            self.setRoomColors(pack, world.view_room);
        }
    }

    /// Turns the message's page. False when it was the last: the frame shows without it.
    pub fn nextMessagePage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
    ) !bool {
        const shown = &(self.message orelse return false);
        shown.page += 1;
        if (shown.page < messages[shown.number].len) {
            try self.drawMessagePage(pack, messages);
            return true;
        }
        self.message = null;
        @memcpy(&self.picture, &self.under_message);
        self.showHudIcon(pack);
        return false;
    }

    /// The message freezes the frame: the background takes its message area, and both video
    /// pages hold it, each with the texts drawn into it in the last two frames.
    fn openMessage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
        number: u16,
    ) !void {
        @memcpy(&self.under_message, &self.picture);
        @memcpy(&self.message_background, &self.background);
        for (26..58) |row| @memcpy(
            self.message_background[row * width + 16 ..][0..128],
            self.picture[row * width + 16 ..][0..128],
        );
        self.pages = .{ self.picture, self.picture };
        self.page_rects = .{ self.frame_rects, self.previous_rects };
        self.page_buffer = 0;
        self.message = .{ .number = number };
        try self.drawMessagePage(pack, messages);
    }

    /// The page's lines centered on x = 88 from y = 26, with the icon at (80, 8), drawn into
    /// its video page, which is then shown; the other page is wiped for the next one.
    fn drawMessagePage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
    ) !void {
        const shown = self.message.?;
        const target = &self.pages[self.page_buffer];
        const rects = &self.page_rects[self.page_buffer];
        if (iconFrame(pack, self.message_icon)) |frame| drawIcon(target, rects, frame, 80, 8);
        for (messages[shown.number][shown.page], 0..) |line, row| {
            const x = 88 - 4 * @as(i32, @intCast(line.text.len));
            const y = 26 + 8 * @as(i32, @intCast(row));
            try drawText(target, rects, pack, line.text, x, y, line.ink);
        }
        @memcpy(&self.picture, target);
        self.page_buffer = ~self.page_buffer;
        const other = &self.pages[self.page_buffer];
        const old = &self.page_rects[self.page_buffer];
        for (old.items[0..old.count]) |rect| restore(other, &self.message_background, rect);
        old.* = .{};
    }

    pub fn writeRgba(self: *const Screen, rgba: []u8) !void {
        var shown: [pixel_count]u8 = undefined;
        self.display(&self.picture, &shown);
        try palette.writeRgba(&shown, &self.colors, rgba);
    }

    /// What the display shows of `picture`: shaken down by the shake rows, the rows above
    /// blank.
    pub fn display(
        self: *const Screen,
        picture: *const [pixel_count]u8,
        shown: *[pixel_count]u8,
    ) void {
        const offset = @as(usize, self.shake_rows) * width;
        @memset(shown[0..offset], 0);
        @memcpy(shown[offset..], picture[0 .. pixel_count - offset]);
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
        self.hud_unshown = true;
    }

    /// The new HUD icon is drawn onto the picture just before it is flipped.
    fn showHudIcon(self: *Screen, pack: *const level_pack.Pack) void {
        if (!self.hud_unshown) return;
        self.hud_unshown = false;
        const frame = iconFrame(pack, self.hud_icon orelse return) orelse return;
        var unrecorded: Rects = .{};
        drawIcon(&self.picture, &unrecorded, frame, 232, 8);
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
        if (self.pending_message != null) {
            self.message_icon = found.icon - 1;
            self.completed = false;
            return;
        }
        const rects = &self.frame_rects;
        if (iconFrame(pack, found.icon - 1)) |frame| drawIcon(&self.picture, rects, frame, 80, 8);
        const name = world.level.characters[found.character].label;
        const x = 88 - 4 * @as(i32, @intCast(name.len));
        try drawText(&self.picture, rects, pack, name, x, 26, 0xe6);
        if (found.icon != 3) {
            self.completed = false;
        } else if (self.completed) {
            try drawText(&self.picture, rects, pack, "COMPLETED", 88 - 4 * 9, 34, 0xe6);
        }
    }

    fn drawPassword(self: *Screen, pack: *const level_pack.Pack) !void {
        if (self.password_frames == 0) return;
        self.password_frames -= 1;
        if (self.password_frames == 0) return;
        const text = std.mem.sliceTo(&pack.password, 0);
        const x = 128 - 4 * @as(i32, @intCast(text.len));
        try drawText(&self.picture, &self.frame_rects, pack, text, x, 16, 0xe7);
    }
};

/// Draws text and records its rectangle, as the original does for later restoring.
fn drawText(
    target: *[pixel_count]u8,
    rects: *Screen.Rects,
    pack: *const level_pack.Pack,
    text: []const u8,
    x: i32,
    y: i32,
    ink: u8,
) !void {
    try text_renderer.draw(target, width, height, &pack.font, text, x, y, .{
        .foreground = ink,
        .shadow = 0xe2,
        .palette_bank = 14,
    });
    rects.add(.{ .x = x, .y = y, .w = 8 * @as(i32, @intCast(text.len)), .h = 8 });
}

/// Copies a rectangle from `source`, clipped to the screen.
fn restore(target: *[pixel_count]u8, source: *const [pixel_count]u8, rect: Screen.Rect) void {
    const x0: usize = @intCast(std.math.clamp(rect.x, 0, width));
    const x1: usize = @intCast(std.math.clamp(rect.x + rect.w, 0, width));
    const y0: usize = @intCast(std.math.clamp(rect.y, 0, height));
    const y1: usize = @intCast(std.math.clamp(rect.y + rect.h, 0, height));
    if (x1 <= x0) return;
    for (y0..y1) |row| {
        const line = row * width;
        @memcpy(target[line + x0 .. line + x1], source[line + x0 .. line + x1]);
    }
}

const Label = struct { icon: u8, character: u16 };

/// The first search looks for an item (kind 3) among the characters in Conrad's first cell,
/// newest first, Conrad included. If none has an icon, a second search for kinds 5 and 9 starts
/// from the first cell of the last character the first search examined.
fn labelTarget(world: *const World) ?Label {
    var last: u16 = 0;
    const item = search(world, 0, &.{ 3, 0xff }, &last);
    if (item) |found| if (positive(found.icon)) return found;
    const other = search(world, last, &.{ 0xff, 5, 9 }, &last);
    if (other) |found| if (positive(found.icon)) return found;
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
fn drawIcon(
    picture: *[pixel_count]u8,
    rects: *Screen.Rects,
    frame: *const sprite.Frame,
    x: usize,
    y: usize,
) void {
    for (0..16) |row| for (0..16) |column| {
        const pixel = frame.image.pixels[row * 16 + column];
        if (pixel != 0) picture[(y + row) * width + x + column] = 0xa0 | pixel;
    };
    rects.add(.{ .x = @intCast(x), .y = @intCast(y), .w = 16, .h = 16 });
}
