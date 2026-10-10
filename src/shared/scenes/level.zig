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
const key_latch = @import("../key_latch.zig");
const input_mod = @import("../input.zig");
const save = @import("../save.zig");
const settings_mod = @import("../settings.zig");
const Settings = settings_mod.Settings;
const audio_effects = @import("../audio/effects.zig");
const megadrive = @import("../content/megadrive.zig");
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
    keys: input_mod.Tracker = .{},
    /// A demo replays its recorded input bytes instead of the keys.
    demo: ?Demo = null,
    clock: ?step_clock.Clock = null,
    /// While a world message shows, the keys are polled every three display refreshes and the
    /// world waits.
    message_clock: ?step_clock.Clock = null,
    pending: std.ArrayList(platform.Event) = .empty,
    effects: audio_effects.Output = .{},
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
    /// The last frame ended late: this one walks the characters twice and draws once.
    catch_up_due: bool = false,
    /// This frame walked twice: it waits a tick longer.
    caught_up: bool = false,
    /// The catch-up walks run so far: how often the host fell behind.
    catch_up_walks: u32 = 0,
    /// The walks run so far in this scene, for tests that follow them one by one.
    walk_count: u64 = 0,

    const Options = struct {
        menu: game_options.Menu,
        clock: step_clock.Clock,
        direction_repeat: key_latch.DirectionRepeat = .{},
    };

    const Inventory = struct {
        menu: inventory_menu.Menu,
        keys: inventory_menu.Keys = .{},
        clock: step_clock.Clock,
        direction_repeat: key_latch.DirectionRepeat = .{},
        items: [max_items]u16 = undefined,
        entries: [max_items]inventory_menu.Entry = undefined,
        const max_items = 32;
    };

    pub const Demo = struct { bytes: []u8, cursor: usize = 0 };

    /// Loads `level` from the data set `files` and the original art and sound in `assets`.
    pub const Setup = struct {
        difficulty: settings_mod.Difficulty = .normal,
        /// The records' flags as the previous level left them (none in a new game).
        inherited: []const behavior.world.Inherited = &.{},
        /// The Mega Drive edition's tunes, when the user gave its cartridge.
        tunes: ?*const megadrive.Tunes = null,
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
        setup: Setup,
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
            setup,
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
            .effects = .{ .tunes = setup.tunes },
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
            .key_down,
            .key_up,
            .focus_lost,
            .controller_axis,
            .controller_button_down,
            .controller_button_up,
            .controller_removed,
            => try self.pending.append(self.allocator, event),
            else => {},
        }
    }

    /// Runs the updates due by `now_ns`, at the original's cadence.
    /// Runs the updates due by `now_ns`, at the original's cadence, with the game's `settings`
    /// (the options dialog changes them).
    pub fn update(self: *Scene, now_ns: u64, settings: *Settings) !void {
        if (self.clock == null) {
            self.clock = try step_clock.Clock.init(step_clock.jungle, now_ns);
            // The automatic zoom option lasts for the program run; a permanent zoom does not
            // survive a new game or a continue.
            self.screen.zoom.automatic = settings.zoom == .auto;
        }
        var work: usize = 0;
        while (self.outcome == .playing and self.film == null and self.needsCatchup(now_ns) and
            work < 8) : (work += 1)
        {
            if (self.options) |*options| {
                const deadline = options.clock.deadline();
                options.clock.consume();
                try self.pollOptions(deadline, settings);
                continue;
            }
            if (self.inventory) |*inventory| {
                const deadline = inventory.clock.deadline();
                inventory.clock.consume();
                try self.pollInventory(deadline, settings.joystick);
                continue;
            }
            if (self.message_clock) |*clock| {
                const deadline = clock.deadline();
                clock.consume();
                try self.pollMessage(deadline, settings);
                continue;
            }
            const deadline = self.clock.?.deadline();
            const controls = try self.step(deadline, settings.*);
            if (self.film != null) return;
            try self.finishFrame(controls, deadline, settings);
            self.frameWait();
            try self.checkLate(now_ns);
        }
    }

    /// The original's frame wait: two ticks after the last frame, three after a catch-up walk.
    fn frameWait(self: *Scene) void {
        self.clock.?.consume();
        if (self.caught_up) self.clock.?.advance(1);
        self.caught_up = false;
    }

    /// A frame that ends a tick after its wait was due leaves a catch-up walk to the next
    /// frame, which follows at once; the time lost is dropped. Modal screens and films do not
    /// count: the original stops or restarts its tick counter for them.
    fn checkLate(self: *Scene, now_ns: u64) !void {
        if (!self.clock.?.behind(now_ns, 1)) return;
        self.catch_up_due = true;
        try self.clock.?.restart(now_ns);
    }

    /// After the walk and the draw, in the original's order: a world message, the zoom's
    /// timers, Esc (the options dialog; it ends a demo), the inventory key, then the flip. A
    /// modal screen holds the rest of the sequence until it closes.
    fn finishFrame(self: *Scene, controls: u8, now_ns: u64, settings: *Settings) !void {
        if (self.outcome != .playing) return;
        self.frame_controls = controls;
        if (self.screen.message != null) return self.openMessage(now_ns);
        try self.afterMessage(now_ns, settings);
    }

    fn afterMessage(self: *Scene, now_ns: u64, settings: *Settings) !void {
        self.screen.afterDraw();
        if (self.keys.escape) {
            self.keys.escape = false;
            if (self.demo != null) {
                self.outcome = .aborted;
                return;
            }
            // The dialog shows the zoom the view has.
            settings.zoom = @fromBackingInt(self.screen.zoom.row());
            self.options = .{
                .menu = .{},
                .clock = try step_clock.Clock.init(step_clock.inventory, now_ns),
            };
            self.keys.latch();
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
    fn pollOptions(self: *Scene, deadline: u64, settings: *Settings) !void {
        const options = &self.options.?;
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            const changes = self.keys.apply(event.payload);
            for (changes.slice()) |change| {
                if (!change.down) continue;
                // The original's dialog reads only the keyboard; a pad's B or START resumes
                // (PLAN GS-3).
                if (change.pad and (change.action == .gun or change.action == .pause)) {
                    options.menu.back();
                    continue;
                }
                if (options.direction_repeat.registers(change, event.time_ns)) options.menu.press(change.action, settings);
            }
        }
        if (self.keys.pads.repeat()) |held| {
            if (options.direction_repeat.registers(held, deadline)) options.menu.press(held.action, settings);
        }
        const outcome = options.menu.outcome orelse return;
        self.screen.zoom.setRow(@backingInt(settings.zoom));
        const paused = deadline -| options.clock.origin_ns;
        self.options = null;
        self.keys.unlatch();
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
        self.keys.latch();
    }

    /// Enter, Space or Shift turns the page; after the last, play resumes.
    fn pollMessage(self: *Scene, deadline: u64, settings: *Settings) !void {
        const held = if (self.demo) |*demo| byte: {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return;
            }
            demo.cursor += 1;
            break :byte demo.bytes[demo.cursor - 1];
        } else self.takeKeys(deadline, settings.joystick);
        if (held & 0x70 == 0) return;
        self.keys.latch();
        if (try self.screen.nextMessagePage(&self.pack, self.messages)) return;
        // The world resumes where it stopped.
        self.keys.unlatch();
        const paused = deadline -| self.message_clock.?.origin_ns;
        self.message_clock = null;
        self.clock.?.origin_ns +|= paused;
        try self.afterMessage(deadline, settings);
    }

    /// Play proper: no film, inventory, message or end of the level. The options dialog does
    /// not count; the original lets S through while it is open.
    pub fn inPlay(self: *const Scene) bool {
        return self.outcome == .playing and self.film == null and self.inventory == null and
            self.message_clock == null;
    }

    pub fn needsCatchup(self: *const Scene, now_ns: u64) bool {
        if (self.outcome != .playing or self.film != null) return false;
        return if (self.nextDeadline()) |time| now_ns >= time else false;
    }

    /// One update with the input held at `deadline`; returns the input byte it used last.
    fn step(self: *Scene, deadline: u64, settings: Settings) !u8 {
        const held = self.takeKeys(deadline, settings.joystick);
        // Tab or Backspace ends a demo.
        if (self.demo != null and held & 0x80 != 0) {
            self.outcome = .aborted;
            return 0;
        }
        const controls = self.input(held) orelse return 0;
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
        return self.walks(controls, deadline, settings);
    }

    /// The demo's next input byte, or the keys `held`. Null when the demo has ended.
    fn input(self: *Scene, held: u8) ?u8 {
        const raw = if (self.demo) |*demo| byte: {
            if (demo.cursor == demo.bytes.len) {
                self.outcome = .aborted;
                return null;
            }
            demo.cursor += 1;
            break :byte demo.bytes[demo.cursor - 1];
        } else held;
        return self.keys.collapse(raw);
    }

    /// The frame's walk, and after a late frame a catch-up walk with the input read again,
    /// unless the inventory key is held. Returns the input byte read last.
    fn walks(self: *Scene, controls: u8, deadline: u64, settings: Settings) !u8 {
        const twice = self.catch_up_due and controls & 0x80 == 0;
        try self.walk(controls, if (twice) .first_of_two else .only, settings.sound_fx);
        if (!twice or self.outcome != .playing) return controls;
        self.catch_up_due = false;
        self.caught_up = true;
        self.catch_up_walks += 1;
        const again = self.input(self.takeKeys(deadline, settings.joystick)) orelse return controls;
        try self.walk(again, .catch_up, settings.sound_fx);
        return again;
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
    pub fn finishFilm(self: *Scene, now_ns: u64, paused_for: u64, settings: *Settings) !void {
        self.film = null;
        if (self.outcome != .playing) return;
        self.world.view_dirty = true;
        self.inventory_delay = 10;
        // Keys pressed during the film and held at its end count only once pressed anew.
        _ = self.takeKeys(now_ns, settings.joystick);
        self.keys.unlatch();
        self.clock.?.origin_ns +|= paused_for;
        // Films do not leave the zoom, but its pages are rebuilt.
        if (self.screen.zoom.on) self.screen.zoom.enter = true;
        const controls = try self.walks(self.after_film, now_ns, settings.*);
        try self.finishFrame(controls, now_ns, settings);
        // The film restarted the tick counter: this frame is not late.
        self.frameWait();
    }

    fn walk(self: *Scene, controls: u8, kind: behavior.world.Walk, sound_fx: bool) !void {
        const outcome = try self.world.update(@bitCast(controls), kind);
        self.walk_count += 1;
        for (self.world.requests.sounds[0..self.world.requests.sound_count]) |sound| {
            if (sound_fx) self.effects.submit(self.pack.sounds, .{
                .sound = @fromBackingInt(sound.id),
                .attenuation = @intFromBool(sound.distant),
            });
        }
        switch (outcome) {
            .played => {
                if (self.world.requests.scene) |scene| self.requested_scene = scene;
                // The first of two walks is not drawn.
                if (kind != .first_of_two) try self.screen.draw(&self.pack, self.messages, &self.world);
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
        self.keys.latch();
        // It closes at once: the latch ends with it.
        if (self.world.characters[0].health <= 0) {
            self.keys.unlatch();
            return false;
        }
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
        inventory.menu = inventory_menu.Menu.init(count) catch {
            self.keys.unlatch();
            return false;
        };
        self.inventory = inventory;
        self.inventory_left_zoom = self.screen.leaveZoomFor();
        return true;
    }

    /// One poll of the inventory: directions move, a button shows the score, the inventory key
    /// closes it and selects the item shown.
    fn pollInventory(self: *Scene, deadline: u64, joystick: bool) !void {
        const inventory = &self.inventory.?;
        self.screen.countPasswordFrame();
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            const changes = self.keys.apply(event.payload);
            if (event.payload == .focus_lost) inventory.keys = .{};
            // The original polls the joystick here too when the Joystick option is on.
            for (changes.slice()) |change| {
                if (change.pad and !joystick) continue;
                if (change.down and change.action.isDirection() and
                    !inventory.direction_repeat.accept(change.repeat, event.time_ns)) continue;
                inventory.keys.action(change.action, change.down);
            }
        }
        if (joystick) if (self.keys.pads.repeat()) |held| {
            if (inventory.direction_repeat.accept(true, deadline)) inventory.keys.action(held.action, true);
        };
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
            inventory.keys.buttons = byte & 0xf0;
        }
        switch (inventory.menu.poll(inventory.keys.sample())) {
            .stay => {},
            .choose => |index| {
                self.world.selectItem(0, inventory.items[index]);
                const paused = deadline -| inventory.clock.origin_ns;
                self.inventory = null;
                self.inventory_delay = 10;
                self.keys.unlatch();
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
    fn takeKeys(self: *Scene, deadline: u64, joystick: bool) u8 {
        while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
            const event = self.pending.orderedRemove(0);
            const changes = self.keys.apply(event.payload);
            for (changes.slice()) |change| {
                if (change.action == .pause) self.keys.escape = change.down;
            }
        }
        return self.keys.read(joystick);
    }

    /// Whether the level can be saved now: in play or behind its options dialog, not a demo, a
    /// film, the inventory or a message (DESIGN.md 4).
    pub fn canSave(self: *const Scene) bool {
        return self.demo == null and self.outcome == .playing and self.film == null and
            self.inventory == null and self.message_clock == null;
    }

    /// The play state outside the world that a save keeps.
    pub fn saveState(self: *const Scene) save.Record.Scene {
        return .{
            .last_direction = self.keys.last_direction,
            .inventory_delay = self.inventory_delay,
            .catch_up_due = self.catch_up_due,
            .requested_scene = self.requested_scene,
        };
    }

    /// Puts back a save's play state in this level, loaded again; its world is put back apart.
    pub fn restoreState(self: *Scene, state: save.Record.Scene) void {
        self.keys = .{ .last_direction = state.last_direction };
        self.inventory_delay = state.inventory_delay;
        self.catch_up_due = state.catch_up_due;
        self.requested_scene = state.requested_scene;
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

    /// The level's picture of the moment, without the options dialog or the inventory over it,
    /// as palette indices, and the palette.
    pub fn playPicture(self: *const Scene, indices: []u8) *const palette.Palette {
        var shown = self.screen.displayed;
        self.screen.display(&shown, indices[0..pixel_count]);
        return &self.screen.colors;
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8, settings: Settings) !void {
        var picture = self.screen.displayed;
        if (self.inventory) |inventory| try inventory.menu.draw(
            self.pack.inventory.artwork(),
            inventory.entries[0..inventory.menu.count],
            self.world.score,
            &picture,
            width,
            height,
        );
        if (self.options) |options| try options.menu.draw(&picture, &self.pack.font, settings);
        self.screen.display(&picture, indices[0..pixel_count]);
        try palette.writeRgba(indices, &self.screen.colors, rgba);
    }

    pub fn pumpAudio(self: *Scene, p: *platform.Platform, settings: Settings) !void {
        self.effects.volume = settings.volume;
        if (self.options != null or !settings.sound_fx) return self.effects.stop(p);
        try self.effects.pump(self.pack.sounds, p);
    }

    pub fn stopAudio(self: *Scene, p: *platform.Platform) void {
        self.effects.stop(p);
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
