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
const ending_mod = @import("ending.zig");
const World = behavior.world.World;
const data_set = behavior.data_set;
const contacts = behavior.contacts;

const level_screen = @import("level_screen.zig");
pub const Screen = level_screen.Screen;
pub const width = level_screen.width;
pub const height = level_screen.height;
const pixel_count = level_screen.pixel_count;

/// How a level ends, for the game to act on.
pub const Outcome = union(enum) {
    playing,
    /// An exit to another level.
    level: level_mod.Id,
    /// Conrad's defeat: the continue screen follows.
    defeated,
    /// The player left, or the demo ended.
    aborted,
    /// The game is finished: the ending plays.
    ending,
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
    inventory_left_zoom: bool = false,
    /// The input byte of the update whose frame waits for its flip behind a message, the
    /// options dialog or the inventory.
    frame_controls: u8 = 0,
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
    pub const Setup = struct {
        difficulty: settings.Difficulty = .normal,
        /// The records' flags as the previous level left them (none in a new game).
        inherited: []const behavior.world.Inherited = &.{},
    };

    pub fn load(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        level: level_mod.Id,
        setup: Setup,
    ) !Scene {
        return loadWithStart(allocator, assets, files, level, setup, null);
    }

    /// Loads demo `index`: its level, with Conrad where the demo starts, replaying its input.
    pub fn loadDemo(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        index: usize,
        inherited: []const behavior.world.Inherited,
    ) !Scene {
        const recording = try demo_mod.load(allocator, assets, index);
        defer allocator.free(recording.controls);
        const start: ?World.Start = if (recording.descriptor.start) |start| .{
            .room = start.room,
            .x = start.x,
            .y = start.y,
        } else null;
        var scene = try loadWithStart(
            allocator,
            assets,
            files,
            recording.descriptor.level,
            .{ .inherited = inherited },
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
        setup: Setup,
        start: ?World.Start,
    ) !Scene {
        const difficulty = setup.difficulty;
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
            .{
                .difficulty = @fromBackingInt(@backingInt(difficulty)),
                .start = start,
                .inherited = setup.inherited,
            },
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
        if (self.clock == null) {
            self.clock = try step_clock.Clock.init(step_clock.jungle, now_ns);
            // The automatic zoom option lasts for the program run; a permanent zoom does not
            // survive a new game or a continue.
            self.screen.zoom.automatic = self.settings.zoom == .auto;
        }
        var work: usize = 0;
        while (self.outcome == .playing and self.film == null and self.needsCatchup(now_ns) and
            work < 8) : (work += 1)
        {
            if (self.options) |*options| {
                const deadline = options.clock.deadline();
                options.clock.consume();
                try self.pollOptions(deadline);
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
            try self.finishFrame(controls, deadline);
        }
    }

    /// After the walk and the draw, in the original's order: a world message, the zoom's
    /// timers, Esc (the options dialog; it ends a demo), the inventory key, then the flip. A
    /// modal screen holds the rest of the sequence until it closes.
    fn finishFrame(self: *Scene, controls: u8, now_ns: u64) !void {
        if (self.outcome != .playing) return;
        self.frame_controls = controls;
        if (self.screen.message != null) return self.openMessage(now_ns);
        try self.afterMessage(now_ns);
    }

    fn afterMessage(self: *Scene, now_ns: u64) !void {
        self.screen.afterDraw();
        if (self.keys.escape) {
            self.keys.escape = false;
            if (self.demo != null) {
                self.outcome = .aborted;
                return;
            }
            var settings_shown = self.settings;
            settings_shown.zoom = @fromBackingInt(self.screen.zoom.row());
            self.options = .{
                .menu = .{ .settings = settings_shown },
                .clock = try step_clock.Clock.init(step_clock.inventory, now_ns),
            };
            self.keys.release();
            return;
        }
        try self.afterOptions(now_ns);
    }

    fn afterOptions(self: *Scene, now_ns: u64) !void {
        if (try self.openInventory(self.frame_controls, now_ns)) return;
        self.screen.flip(&self.pack, &self.world);
    }

    /// The options dialog takes key presses; resuming applies its settings, and abandoning the
    /// game leads to the continue screen, as a defeat does.
    fn pollOptions(self: *Scene, deadline: u64) !void {
        const options = &self.options.?;
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            if (event.payload == .key_down) options.menu.key(event.payload.key_down.key);
        }
        const outcome = options.menu.outcome orelse return;
        self.settings = options.menu.settings;
        self.screen.zoom.setRow(@backingInt(self.settings.zoom));
        const paused = deadline -| options.clock.origin_ns;
        self.options = null;
        self.keys.release();
        self.clock.?.origin_ns +|= paused;
        if (outcome == .abort_game) {
            self.outcome = .defeated;
            return;
        }
        try self.afterOptions(deadline);
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
        try self.afterMessage(deadline);
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
            if (scene == ending_mod.ending_scene) {
                self.outcome = .ending;
                return controls;
            }
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
        // The continue screen left the zoom.
        self.screen.zoom.on = false;
        self.screen.zoom.enter = false;
        self.screen.zoom.leave = false;
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
        // Films do not leave the zoom, but its pages are rebuilt.
        if (self.screen.zoom.on) self.screen.zoom.enter = true;
        try self.walk(self.after_film);
        try self.finishFrame(self.after_film, now_ns);
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
                try self.screen.draw(&self.pack, self.messages, &self.world);
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

    /// Once per frame, the inventory key opens the inventory when the delay has run out. With
    /// no items, or Conrad without health, it closes at once. True when it opened; it leaves
    /// the zoom while it is open.
    fn openInventory(self: *Scene, controls: u8, deadline: u64) !bool {
        if (self.inventory_delay != 0) {
            self.inventory_delay -= 1;
            return false;
        }
        if (controls & 0x80 == 0) return false;
        self.keys.release();
        if (self.world.characters[0].health <= 0) return false;
        var inventory: Inventory = .{
            .menu = undefined,
            .clock = try step_clock.Clock.init(step_clock.inventory, deadline),
        };
        var count: usize = 0;
        var next = self.world.characters[0].first_item;
        while (next) |item| : (next = self.world.characters[item].next_item) {
            if (count == Inventory.max_items) break;
            const definition = self.data.characters[item];
            const icon = level_screen.iconFrame(&self.pack, definition.inventory_icon) orelse continue;
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
        inventory.menu = inventory_menu.Menu.init(count) catch return false;
        self.inventory = inventory;
        self.inventory_left_zoom = self.screen.leaveZoomFor();
        return true;
    }

    /// One poll of the inventory: directions move, a button shows the score, the inventory key
    /// closes it and selects the item shown.
    fn pollInventory(self: *Scene, deadline: u64) !void {
        const inventory = &self.inventory.?;
        self.screen.countPasswordFrame();
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
                if (self.inventory_left_zoom) {
                    self.inventory_left_zoom = false;
                    self.screen.returnToZoom();
                }
                self.screen.flip(&self.pack, &self.world);
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
        var picture = self.screen.displayed;
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
