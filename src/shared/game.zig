//! Shared application lifecycle and tagged scene ownership. Hosts provide input, time and
//! presentation; the selected scene owns its content and simulation. The game needs the
//! original's files: without them it does not start.
const std = @import("std");
const platform = @import("platform.zig");
const menu_art = @import("content/menu_artwork.zig");
const front_end = @import("scenes/front_end.zig");
const continue_mod = @import("scenes/continue_game.zig");
const story_mod = @import("scenes/story.zig");
const level_scene = @import("scenes/level.zig");
const ending_mod = @import("scenes/ending.zig");
const data_set = @import("behavior/data_set.zig");
const behavior_world = @import("behavior/world.zig");
const content_level = @import("content/level.zig");
const game_options = @import("scenes/game_options.zig");
const memory = @import("memory.zig");
const settings_mod = @import("settings.zig");
const step_clock = @import("step_clock.zig");
const input = @import("input.zig");
const save = @import("save.zig");
const save_slots = @import("scenes/save_slots.zig");
const megadrive = @import("content/megadrive.zig");
const audio_output = @import("audio/output.zig");
pub const Entry = union(enum) {
    automatic,
    menu_development,
    /// Straight into a level (needs the data set).
    level_development: content_level.Id,
};
const Scene = union(enum) {
    menu: front_end.Scene,
    /// A level, run from its behavior tables.
    level: level_scene.Scene,
    continue_game: continue_mod.Scene,
    ending: ending_mod.Ending,
};

/// Every scene's picture: 256 by 224 palette indices, as the original's game view.
pub const picture_width = 256;
pub const picture_height = 224;
const picture_pixels = picture_width * picture_height;

pub const Phase = enum { startup, playing, finished };
pub const UpdateResult = enum { running, finished };

const ConnectedPad = struct { id: platform.ControllerId, model: platform.ControllerModel };

/// The save slots as a slot page shows them, read from storage.
const SlotList = struct {
    arena: std.heap.ArenaAllocator,
    slots: [save_slots.row_count]save.Slot,
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    /// The original's files and the saves, bound by the host. Null when the host has none.
    assets: ?platform.AssetSource,
    storage: ?platform.Storage,
    /// The data set that levels run from, when the host provides one.
    data: ?*const data_set.Files = null,
    phase: Phase = .startup,
    update_count: u64 = 0,
    frames_presented: u64 = 0,
    events_consumed: u64 = 0,
    /// The hash of the last presented page, as palette indices.
    last_frame_hash: u64 = 0,
    /// The player's settings, which the game owns and keeps in storage.
    settings: settings_mod.Settings = .{},
    /// The settings as storage last kept them.
    kept_settings: settings_mod.Settings = .{},
    /// What the pads hold, for the screens outside a level (a level tracks its own).
    pads: input.Pads = .{},
    /// The connected pads' models, which give their layouts (PLAN GS-3a).
    pad_models: [8]?ConnectedPad = @splat(null),
    /// The pad that pressed last: the CONTROLS page shows and changes its layout.
    last_pad: ?platform.ControllerId = null,
    /// The walks of this game's levels before the one in play, which its play time counts.
    play_walks: u64 = 0,
    /// The save slots, read when a slot page opens, dropped when a save changes them.
    slot_list: ?SlotList = null,
    /// P's toggle, which only films read: they hold their picture while it is set.
    films_paused: bool = false,
    /// The music volume keypad + and - step, 0 to 63, for notes started afterwards.
    music_volume: u8 = 48,
    /// J was pressed: the joystick option turns on at the next frame of play outside a demo.
    joystick_requested: bool = false,
    page: []u8,
    rgba: []u8,
    scene: Scene,
    demo_index: u2 = 0,
    difficulty: settings_mod.Difficulty = .normal,
    level: content_level.Id = .jungle,
    story: ?story_mod.Story = null,
    /// The level the continue screen may resume.
    suspended_level: ?level_scene.Scene = null,
    /// The character records' flags as the last level left them; the next level's characters
    /// that it does not place keep them, as in the original.
    inherited: [data_set.max_characters]behavior_world.Inherited = @splat(.{}),
    /// The one audio output, which plays the scene's sound.
    sound: audio_output.Output = .{},
    /// The Mega Drive edition's tunes, when the user gave its cartridge (PLAN MD-D), read once
    /// for every level; on the heap so that the levels' pointers outlive moves of the game.
    tunes: ?*megadrive.Tunes = null,

    pub fn init(
        allocator: std.mem.Allocator,
        assets: ?platform.AssetSource,
        storage: ?platform.Storage,
    ) !Game {
        return initWithEntry(allocator, assets, storage, null, .automatic);
    }

    pub fn initWithEntry(
        allocator: std.mem.Allocator,
        assets: ?platform.AssetSource,
        storage: ?platform.Storage,
        data: ?*const data_set.Files,
        entry: Entry,
    ) !Game {
        const page = try allocator.alloc(u8, picture_pixels);
        errdefer allocator.free(page);
        const rgba = try allocator.alloc(
            u8,
            picture_pixels * platform.RgbaFrame.bytes_per_pixel,
        );
        errdefer allocator.free(rgba);
        const settings = settings_mod.load(storage);
        const tunes = try loadTunes(allocator, assets);
        errdefer if (tunes) |t| freeTunes(allocator, t);
        if (entry == .level_development) {
            const level = entry.level_development;
            const scene = try level_scene.Scene.load(
                allocator,
                assets orelse return error.OriginalContentRequired,
                data orelse return error.DataSetRequired,
                level,
                .{ .tunes = tunes },
            );
            return .{
                .allocator = allocator,
                .assets = assets,
                .storage = storage,
                .data = data,
                .page = page,
                .rgba = rgba,
                .settings = settings,
                .kept_settings = settings,
                .level = level,
                .scene = .{ .level = scene },
                .tunes = tunes,
            };
        }
        const source = assets orelse return error.OriginalContentRequired;
        const menu = (try menu_art.load(allocator, source)) orelse return error.MissingMenu;
        var front = front_end.Scene.init(allocator, source, menu);
        errdefer front.deinit();
        if (entry == .automatic) try front.intro();
        return .{
            .allocator = allocator,
            .assets = assets,
            .storage = storage,
            .data = data,
            .page = page,
            .rgba = rgba,
            .settings = settings,
            .kept_settings = settings,
            .scene = .{ .menu = front },
            .tunes = tunes,
        };
    }

    /// The Mega Drive cartridge's tunes, if the user gave it (`content.megadrive.asset`).
    fn loadTunes(allocator: std.mem.Allocator, assets: ?platform.AssetSource) !?*megadrive.Tunes {
        const source = assets orelse return null;
        var cartridge = source.readAll(megadrive.asset, megadrive.size) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        defer cartridge.deinit();
        // Only the accepted cartridge, however the files gave it.
        if (!megadrive.isCartridge(cartridge.bytes)) {
            std.log.err("{s} is not the accepted Mega Drive cartridge", .{megadrive.asset});
            return error.UnsupportedCartridge;
        }
        const tunes = try allocator.create(megadrive.Tunes);
        errdefer allocator.destroy(tunes);
        tunes.* = try megadrive.Tunes.read(allocator, cartridge.bytes);
        return tunes;
    }

    fn freeTunes(allocator: std.mem.Allocator, tunes: *megadrive.Tunes) void {
        tunes.deinit();
        allocator.destroy(tunes);
    }

    pub fn deinit(self: *Game) void {
        self.dropSlots();
        if (self.story) |*story| story.deinit();
        if (self.suspended_level) |*scene| scene.deinit();
        switch (self.scene) {
            .menu => |*scene| scene.deinit(),
            .level => |*scene| scene.deinit(),
            .continue_game => |*scene| scene.deinit(),
            .ending => |*scene| scene.deinit(),
        }
        self.allocator.free(self.page);
        self.allocator.free(self.rgba);
        if (self.tunes) |tunes| freeTunes(self.allocator, tunes);
        self.* = undefined;
    }

    pub fn stateHash(self: *const Game) u64 {
        return switch (self.scene) {
            inline else => |*scene| scene.stateHash(),
        };
    }

    pub fn sceneKind(self: *const Game) std.meta.Tag(Scene) {
        return std.meta.activeTag(self.scene);
    }

    pub fn needsCatchup(self: *const Game, now_ns: u64) bool {
        if (self.story) |*story| return story.player.needsCatchup(now_ns);
        if (self.scene == .level) return self.scene.level.needsCatchup(now_ns);
        if (self.scene == .ending) return self.scene.ending.needsCatchup(now_ns);
        if (self.scene == .menu) return self.scene.menu.needsCatchup(now_ns);
        if (self.scene == .continue_game) return self.scene.continue_game.needsCatchup(now_ns);
        return false;
    }

    pub fn isStoryPlaying(self: *const Game) bool {
        return self.story != null;
    }

    /// One frame: the input, one step of the state, the picture and the sound.
    pub fn update(self: *Game, p: *platform.Platform) !UpdateResult {
        const result = try self.step(p);
        if (result == .finished) {
            self.sound.close(p);
        } else {
            self.sound.volume = self.settings.volume;
            self.sound.pump(p, self.soundSources());
        }
        return result;
    }

    /// What plays: a film's music, else the scene's.
    fn soundSources(self: *Game) audio_output.Sources {
        if (self.story) |*story| return .{ .music = story.sound() };
        return switch (self.scene) {
            .menu => |*front| .{ .music = front.sound() },
            .ending => |*ending| .{ .music = ending.sound() },
            .level => |*level| .{ .level = level.sound(self.settings) },
            .continue_game => .{},
        };
    }

    /// The input, one step of the state and the picture.
    fn step(self: *Game, p: *platform.Platform) !UpdateResult {
        if (self.phase == .finished) return .finished;
        self.update_count += 1;
        // What the last update changed: the options dialog, S, J and K.
        self.keepSettings();
        switch (self.phase) {
            .startup => {
                _ = try p.start();
                try p.setResolution(picture_width, picture_height);
                self.phase = .playing;
                if (self.scene == .level) try self.consumeEvents(p);
            },
            .playing => try self.consumeEvents(p),
            .finished => {},
        }
        if (self.phase == .finished) {
            self.keepSettings();
            return .finished;
        }
        if (self.scene == .ending) {
            const ending = &self.scene.ending;
            ending.music_enabled = self.settings.music;
            if (ending.music) |*music| music.player.master_volume = self.music_volume;
            ending.setPaused(self.films_paused, p.nowNs());
            try ending.update(p);
            if (ending.finished) {
                const next = try self.titleMenu();
                ending.deinit();
                self.scene = .{ .menu = next };
            }
        }
        if (self.scene == .level) {
            if (try self.updateLevel(p)) return .running;
        }
        if (self.scene == .menu) {
            const front = &self.scene.menu;
            front.music_enabled = self.settings.music;
            front.joystick = self.settings.joystick;
            front.films_paused = self.films_paused;
            front.music_volume = self.music_volume;
            if (self.pads.repeat()) |held| try front.pad(held, p.nowNs());
            if (front.view == .load) {
                front.slots = try self.slotList();
                if (front.load_page.outcome) |outcome| if (outcome == .chosen) {
                    front.load_page.outcome = null;
                    var name: [8]u8 = undefined;
                    // Loading replaces the title: nothing of it is used after.
                    self.loadGame(save_slots.slotName(outcome.chosen, &name)) catch |err| {
                        std.log.err("the game could not be loaded: {s}", .{@errorName(err)});
                    };
                    if (self.scene != .menu) {
                        try self.present(p);
                        return .running;
                    }
                };
            }
            if (front.stage == .quit) {
                self.phase = .finished;
                return .finished;
            }
            try front.update(p);
            if (front.stage == .demo_ready) {
                if (self.demo_index == 3) {
                    self.demo_index = 0;
                    try front.intro();
                } else {
                    const next = try level_scene.Scene.loadDemo(
                        self.allocator,
                        self.assets.?,
                        self.data orelse return error.DataSetRequired,
                        self.demo_index,
                        .{ .inherited = &self.inherited, .tunes = self.tunes },
                    );
                    front.deinit();
                    self.scene = .{ .level = next };
                    self.demo_index += 1;
                }
            } else if (front.stage == .ending_ready) {
                const next = try ending_mod.Ending.init(
                    self.allocator,
                    self.assets.?,
                    self.data orelse return error.DataSetRequired,
                    null,
                );
                front.deinit();
                self.scene = .{ .ending = next };
            } else if (front.stage == .ready) {
                self.play_walks = 0;
                const next = try level_scene.Scene.load(
                    self.allocator,
                    self.assets.?,
                    self.data orelse return error.DataSetRequired,
                    front.selected_level,
                    .{
                        .difficulty = front.difficulty,
                        .inherited = &self.inherited,
                        .tunes = self.tunes,
                    },
                );
                self.level = front.selected_level;
                self.difficulty = front.difficulty;
                front.deinit();
                self.scene = .{ .level = next };
            }
        }
        if (self.scene == .continue_game) {
            const dialog = &self.scene.continue_game;
            try dialog.update(p.nowNs());
            if (dialog.menu.outcome) |choice| resume_level: {
                if (self.suspended_level) |*level| {
                    if (choice == .retry) {
                        if (!level.continueAfterDefeat()) {
                            level.world.inheritance(&self.inherited);
                            // No checkpoint: the level starts again, from its entry score.
                            var fresh = try level_scene.Scene.load(
                                self.allocator,
                                self.assets.?,
                                self.data.?,
                                level.level,
                                .{
                                    .difficulty = self.difficulty,
                                    .inherited = &self.inherited,
                                    .tunes = self.tunes,
                                },
                            );
                            fresh.world.score = level.world.entry_score;
                            fresh.world.entry_score = level.world.entry_score;
                            fresh.world.random = level.world.random;
                            fresh.catch_up_due = level.catch_up_due;
                            self.play_walks += level.walk_count;
                            self.retire(level);
                            level.* = fresh;
                        }
                        dialog.deinit();
                        self.scene = .{ .level = level.* };
                        self.suspended_level = null;
                        break :resume_level;
                    }
                    self.retire(level);
                    self.suspended_level = null;
                }
                const art = (try menu_art.load(self.allocator, self.assets.?)) orelse return error.MissingMenu;
                var next = front_end.Scene.init(self.allocator, self.assets.?, art);
                errdefer next.deinit();
                next.difficulty = self.difficulty;
                if (choice == .retry) next.startLevel(self.level) else try next.gameOver();
                dialog.deinit();
                self.scene = .{ .menu = next };
            }
        }
        try self.present(p);
        return .running;
    }

    /// Runs the table-driven level and acts on how it ends. True when the frame is done and
    /// the caller should return.
    fn updateLevel(self: *Game, p: *platform.Platform) !bool {
        const scene = &self.scene.level;
        const now = p.nowNs();
        if (scene.film) |film| {
            if (self.story == null) {
                scene.stopSound();
                self.story = try story_mod.Story.openFilm(
                    self.allocator,
                    self.assets.?,
                    film.film,
                    film.entry,
                    film.music,
                    now,
                );
            }
            const story = &self.story.?;
            story.music_enabled = self.settings.music;
            if (story.music) |*music| music.player.master_volume = self.music_volume;
            story.player.setPaused(self.films_paused, now);
            if (!try story.update(now)) {
                try self.present(p);
                return true;
            }
            const paused = now - story.started_ns;
            story.deinit();
            self.story = null;
            try scene.finishFilm(now, paused, &self.settings);
        }
        // J's request is served at the next frame of play, outside a demo.
        if (self.joystick_requested and scene.demo == null) {
            self.joystick_requested = false;
            self.settings.joystick = true;
        }
        try scene.update(now, &self.settings);
        if (scene.options) |*options| {
            if (options.menu.free_memory_mb == null) {
                if (p.availableMemory()) |bytes| options.menu.free_memory_mb = bytes / (1024 * 1024);
            }
            const shown = self.shownPad();
            if (options.menu.reset_pad) {
                options.menu.reset_pad = false;
                if (shown) |model| self.settings.setPadLayout(model.guid, .{});
            }
            options.menu.pad = .{
                .layout = if (shown) |model| self.settings.padLayout(model.guid) else .{},
                .model = shown,
            };
            if (options.menu.page == .save) {
                options.menu.slots = try self.slotList();
                if (options.menu.save_page.outcome) |outcome| {
                    options.menu.save_page.outcome = null;
                    options.menu.page = .rows;
                    switch (outcome) {
                        .back => {},
                        .chosen => |row| {
                            var name: [8]u8 = undefined;
                            if (self.saveGame(p, save_slots.slotName(row, &name))) {
                                options.menu.saved = true;
                            } else |err| std.log.err("the game could not be saved: {s}", .{@errorName(err)});
                        },
                    }
                }
            }
        }
        switch (scene.outcome) {
            .playing => return scene.needsCatchup(now),
            .level => |destination| {
                self.play_walks += scene.walk_count;
                scene.world.inheritance(&self.inherited);
                var next = try level_scene.Scene.load(
                    self.allocator,
                    self.assets.?,
                    self.data.?,
                    destination,
                    .{
                        .difficulty = self.difficulty,
                        .inherited = &self.inherited,
                        .tunes = self.tunes,
                    },
                );
                next.world.score = scene.world.score;
                next.world.entry_score = scene.world.score;
                next.world.random = scene.world.random;
                next.world.shake = scene.world.shake;
                next.catch_up_due = scene.catch_up_due;
                scene.deinit();
                self.level = destination;
                self.scene = .{ .level = next };
            },
            .defeated => {
                if (scene.film != null) return false;
                scene.stopSound();
                const next = try continue_mod.Scene.init(
                    self.allocator,
                    self.assets.?,
                    scene.world.score,
                );
                self.suspended_level = scene.*;
                self.scene = .{ .continue_game = next };
            },
            .aborted => {
                const next = try self.titleMenu();
                self.retire(scene);
                self.scene = .{ .menu = next };
            },
            .ending => {
                const next = try ending_mod.Ending.init(
                    self.allocator,
                    self.assets.?,
                    self.data.?,
                    scene.world.score,
                );
                self.retire(scene);
                self.scene = .{ .ending = next };
            },
        }
        return false;
    }

    fn titleMenu(self: *Game) !front_end.Scene {
        const art = (try menu_art.load(self.allocator, self.assets.?)) orelse
            return error.MissingMenu;
        var next = front_end.Scene.init(self.allocator, self.assets.?, art);
        next.difficulty = self.difficulty;
        next.music_enabled = self.settings.music;
        return next;
    }

    /// Ends a level scene, keeping its records' flags for the next level.
    fn retire(self: *Game, scene: *level_scene.Scene) void {
        scene.world.inheritance(&self.inherited);
        scene.deinit();
    }

    fn consumeEvents(self: *Game, p: *platform.Platform) !void {
        var buf: [32]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |raw| {
                self.events_consumed += 1;
                const event = self.padEvent(p, raw) orelse continue;
                if (self.quickKey(p, event)) continue;
                self.globalKey(event);
                // A pad's press, of a button or the stick, turns the Joystick option on (PLAN
                // GS-3).
                const pad = self.pads.apply(event.payload);
                for (pad.slice()) |change| {
                    if (change.down) self.settings.joystick = true;
                }
                if (self.story) |*story| {
                    if (event.payload == .quit) {
                        self.phase = .finished;
                        continue;
                    }
                    if (story.event(event, self.settings.joystick)) continue;
                    if (self.scene == .level) try self.scene.level.enqueue(event);
                    continue;
                }
                if (self.scene == .level) {
                    if (event.payload == .quit) self.phase = .finished else try self.scene.level.enqueue(event);
                    continue;
                }
                if (self.scene == .ending) {
                    if (event.payload == .quit) self.phase = .finished else self.scene.ending.event(event);
                    for (pad.slice()) |change| self.scene.ending.pad(change);
                    continue;
                }
                if (self.scene == .continue_game) {
                    if (event.payload == .quit) self.phase = .finished else try self.scene.continue_game.event(event);
                    for (pad.slice()) |change| try self.scene.continue_game.pad(change, event.time_ns);
                    continue;
                }
                try self.scene.menu.event(event);
                for (pad.slice()) |change| try self.scene.menu.pad(change, event.time_ns);
            }
        }
    }

    /// The keys the original's keyboard interrupt acts on whatever the screen, except the code
    /// entry: P, the keypad's + and -, S, J and K. The event still goes on to the scene.
    fn globalKey(self: *Game, event: platform.Event) void {
        const press = switch (event.payload) {
            .key_down => |key| key,
            else => return,
        };
        // While a code is typed the original leaves the keyboard to the BIOS: these keys are
        // only characters of the code.
        if (self.scene == .menu and self.scene.menu.view == .password) return;
        switch (press.key) {
            .p => if (!press.repeat) {
                self.films_paused = !self.films_paused;
            },
            .keypad_plus => if (!press.repeat and self.music_volume < 63) {
                self.music_volume += 1;
            },
            .keypad_minus => if (!press.repeat and self.music_volume > 0) {
                self.music_volume -= 1;
            },
            // Films, the inventory, messages, the continue screen and the title refuse it.
            .s => if (!press.repeat and self.story == null and self.scene == .level) {
                const level = &self.scene.level;
                if (level.inPlay()) {
                    self.settings.sound_fx = !self.settings.sound_fx;
                }
            },
            .j => self.joystick_requested = true,
            .k => self.settings.joystick = false,
            else => {},
        }
    }

    /// A pad's event as the game reads it (PLAN GS-3a). A pad connected has its model noted; a
    /// button stands for the fixed layout's, by its model's layout, or goes no further when it
    /// gives no action; on the CONTROLS page, a button pressed on an action's row becomes that
    /// action's and goes no further.
    fn padEvent(self: *Game, p: *platform.Platform, event: platform.Event) ?platform.Event {
        switch (event.payload) {
            .controller_added => |id| {
                const model = p.controllerModel(id) orelse return event;
                for (&self.pad_models) |*slot| if (slot.* == null) {
                    slot.* = .{ .id = id, .model = model };
                    break;
                };
                return event;
            },
            .controller_removed => |id| {
                for (&self.pad_models) |*slot| if (slot.*) |pad| {
                    if (pad.id == id) slot.* = null;
                };
                if (self.last_pad == id) self.last_pad = null;
                return event;
            },
            .controller_button_down, .controller_button_up => |change| {
                self.last_pad = change.controller;
                const model = self.padModel(change.controller) orelse return event;
                const button = settings_mod.Button.of(change.button) orelse return event;
                if (event.payload == .controller_button_down and !button.isDirection()) {
                    if (self.bindingAction()) |action| {
                        var layout = self.settings.padLayout(model.guid);
                        layout.bind(action, button);
                        self.settings.setPadLayout(model.guid, layout);
                        return null;
                    }
                }
                const standard = self.settings.padLayout(model.guid).standard(button) orelse return null;
                var translated = event;
                const payload: platform.Event.ControllerButtonEvent = .{ .controller = change.controller, .button = standard.controller() };
                translated.payload = if (event.payload == .controller_button_down) .{ .controller_button_down = payload } else .{ .controller_button_up = payload };
                return translated;
            },
            else => return event,
        }
    }

    fn padModel(self: *const Game, id: platform.ControllerId) ?platform.ControllerModel {
        for (self.pad_models) |slot| if (slot) |pad| {
            if (pad.id == id) return pad.model;
        };
        return null;
    }

    /// The model of the pad the CONTROLS page shows: the last to press, or the first connected.
    fn shownPad(self: *const Game) ?platform.ControllerModel {
        if (self.last_pad) |id| if (self.padModel(id)) |model| return model;
        for (self.pad_models) |slot| if (slot) |pad| return pad.model;
        return null;
    }

    /// The action the CONTROLS page gives a pad's button pressed now, if it is open.
    fn bindingAction(self: *const Game) ?input.Action {
        if (self.scene != .level) return null;
        const options = self.scene.level.options orelse return null;
        return options.menu.binding();
    }

    /// Whether the level in play can be saved now (DESIGN.md 4).
    pub fn canSave(self: *const Game) bool {
        return self.scene == .level and self.story == null and self.scene.level.canSave();
    }

    /// F5 saves the level in play into the quick slot, F9 loads it, with a notice (PLAN GS-5).
    /// True when the key was one of them, in a level outside a film or a demo.
    fn quickKey(self: *Game, p: *platform.Platform, event: platform.Event) bool {
        const press = switch (event.payload) {
            .key_down => |key| key,
            else => return false,
        };
        if (press.key != .f5 and press.key != .f9) return false;
        if (self.scene != .level or self.story != null or self.scene.level.demo != null) return false;
        if (press.repeat) return true;
        if (press.key == .f5) {
            if (!self.canSave()) return true;
            self.saveGame(p, save.quick_slot) catch |err| {
                std.log.err("the game could not be saved: {s}", .{@errorName(err)});
                return true;
            };
            self.scene.level.screen.showNotice("GAME SAVED");
        } else {
            self.loadGame(save.quick_slot) catch |err| {
                if (err != error.NotFound) std.log.err("the game could not be loaded: {s}", .{@errorName(err)});
                return true;
            };
            self.scene.level.screen.showNotice("GAME LOADED");
        }
        return true;
    }

    /// The save slots, read from storage the first time a slot page needs them.
    fn slotList(self: *Game) ![]const save.Slot {
        if (self.slot_list == null) {
            var list: SlotList = .{ .arena = .init(self.allocator), .slots = undefined };
            errdefer list.arena.deinit();
            const print = if (self.data) |files| save.fingerprint(files) else 0;
            for (&list.slots, 0..) |*slot, row| {
                var name: [8]u8 = undefined;
                var info_name: [16]u8 = undefined;
                const info = save.infoName(save_slots.slotName(row, &name), &info_name);
                const storage = self.storage orelse {
                    slot.* = .empty;
                    continue;
                };
                var bytes = storage.load(info) catch |err| {
                    slot.* = if (err == error.NotFound) .empty else .broken;
                    continue;
                };
                defer bytes.deinit();
                slot.* = try save.readSlot(self.allocator, list.arena.allocator(), bytes.bytes, print);
            }
            self.slot_list = list;
        }
        return &self.slot_list.?.slots;
    }

    fn dropSlots(self: *Game) void {
        if (self.slot_list) |*list| list.arena.deinit();
        self.slot_list = null;
    }

    /// The picture of the save a slot page has selected, if one shows.
    fn slotPicture(self: *const Game) ?*const save.Picture {
        const list = &(self.slot_list orelse return null);
        const row = switch (self.scene) {
            .level => |*level| if (level.options) |*options| if (options.menu.page == .save) options.menu.save_page.selection else return null else return null,
            .menu => |*front| if (front.view == .load) front.load_page.selection else return null,
            else => return null,
        };
        return switch (list.slots[row]) {
            .save => |*s| if (s.picture) |*pixels| pixels else null,
            else => null,
        };
    }

    /// Draws the selected save's picture into the presented `frame`, in its own colors.
    fn drawSlotPicture(self: *const Game, frame: []u8) void {
        const pixels = self.slotPicture() orelse return;
        for (0..save.picture_height) |y| for (0..save.picture_width) |x| {
            const at = ((save_slots.picture_y + y) * 256 + save_slots.picture_x + x) * 4;
            const from = (y * save.picture_width + x) * 3;
            frame[at..][0..4].* = .{ pixels[from], pixels[from + 1], pixels[from + 2], 255 };
        };
    }

    /// The walks played in this game, the level in play's included: its play time.
    pub fn playedWalks(self: *const Game) u64 {
        return self.play_walks + if (self.scene == .level) self.scene.level.walk_count else 0;
    }

    /// Saves the level in play into `slot` (`save.quick_slot`, or `save.slotName`), and beside
    /// it what the slot list shows: the level, the play time, the date and the picture.
    pub fn saveGame(self: *Game, p: *platform.Platform, slot: []const u8) !void {
        if (!self.canSave()) return error.NothingToSave;
        const storage = self.storage orelse return error.NoStorage;
        const files = self.data orelse return error.DataSetRequired;
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const level = &self.scene.level;
        var print: [16]u8 = undefined;
        const fingerprint = std.fmt.bufPrint(&print, "{x:0>16}", .{save.fingerprint(files)}) catch unreachable;
        const text = try save.encode(arena, .{
            .version = save.version,
            .data_set = fingerprint,
            .level = level.level,
            .difficulty = self.difficulty,
            .play_walks = self.playedWalks(),
            .inherited = &self.inherited,
            .scene = level.saveState(),
            .world = try save.captureWorld(arena, &level.world),
        });
        try storage.save(slot, text);

        const indices = try arena.alloc(u8, level_scene.width * level_scene.height);
        const colors = level.playPicture(indices);
        var pixels: save.Picture = undefined;
        save.picture(indices, level_scene.width, colors, &pixels);
        var date: [16]u8 = undefined;
        const when: []const u8 = if (p.localTime()) |t| std.fmt.bufPrint(&date, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            t.year, t.month, t.day, t.hour, t.minute,
        }) catch "" else "";
        const info = try save.encodeInfo(arena, .{
            .version = save.version,
            .data_set = fingerprint,
            .level = level.level,
            .play_walks = self.playedWalks(),
            .date = when,
            .picture = try save.hex(arena, &pixels),
        });
        var name: [16]u8 = undefined;
        try storage.save(save.infoName(slot, &name), info);
        self.dropSlots();
    }

    /// Loads the save in `slot`: its level, loaded again with its world put back, replaces
    /// whatever plays. A save of another version or data set is refused (`save.Error`).
    pub fn loadGame(self: *Game, slot: []const u8) !void {
        const storage = self.storage orelse return error.NoStorage;
        const files = self.data orelse return error.DataSetRequired;
        const assets = self.assets orelse return error.OriginalContentRequired;
        var bytes = try storage.load(slot);
        defer bytes.deinit();
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const record = try save.decode(self.allocator, arena_state.allocator(), bytes.bytes, save.fingerprint(files));
        if (record.inherited.len != self.inherited.len) return error.InvalidSave;
        var inherited: [data_set.max_characters]behavior_world.Inherited = undefined;
        @memcpy(&inherited, record.inherited);
        var scene = try level_scene.Scene.load(self.allocator, assets, files, record.level, .{
            .difficulty = record.difficulty,
            .inherited = &inherited,
            .tunes = self.tunes,
        });
        errdefer scene.deinit();
        try save.restoreWorld(&scene.world, record.world);
        scene.restoreState(record.scene);
        self.endScene();
        self.inherited = inherited;
        self.level = record.level;
        self.difficulty = record.difficulty;
        self.play_walks = record.play_walks;
        self.scene = .{ .level = scene };
    }

    /// Ends whatever plays, its film and a level waiting behind the continue screen included,
    /// with their sound.
    fn endScene(self: *Game) void {
        if (self.story) |*story| {
            story.deinit();
            self.story = null;
        }
        if (self.suspended_level) |*level| {
            level.deinit();
            self.suspended_level = null;
        }
        switch (self.scene) {
            inline else => |*scene| scene.deinit(),
        }
    }

    /// Keeps the settings in storage when they have changed since storage last kept them. A
    /// failed save is tried again at the next change.
    fn keepSettings(self: *Game) void {
        if (std.meta.eql(self.settings, self.kept_settings)) return;
        settings_mod.save(self.storage, self.settings) catch return;
        self.kept_settings = self.settings;
    }

    /// Draws the scene (or its film) into the picture and presents it.
    fn present(self: *Game, p: *platform.Platform) !void {
        try p.setResolution(picture_width, picture_height);
        const indices = self.page[0..picture_pixels];
        const frame = self.rgba[0 .. picture_pixels * 4];
        if (self.story) |*story| {
            try story.player.draw(indices, frame);
        } else switch (self.scene) {
            .level => |*level| try level.draw(indices, frame, self.settings),
            .ending => |*ending| try ending.draw(indices, frame),
            .continue_game => |*dialog| try dialog.draw(indices, frame),
            .menu => |*front| try front.draw(indices, frame),
        }
        if (self.story == null) self.drawSlotPicture(frame);
        self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
        try p.present(.{ .width = picture_width, .height = picture_height, .stride = picture_width * 4, .pixels = frame });
        self.frames_presented += 1;
    }
};
