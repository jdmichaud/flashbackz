//! Shared application lifecycle and tagged scene ownership. Hosts provide input, time and
//! presentation; the selected scene owns its content and simulation. The no-content branch
//! retains the template platform smoke program and save contract for host tests.
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
const megadrive = @import("content/megadrive.zig");
pub const Entry = union(enum) {
    automatic,
    menu_development,
    /// Straight into a level (needs the data set).
    level_development: content_level.Id,
};
const Scene = union(enum) {
    smoke,
    menu: front_end.Scene,
    /// A level, run from its behavior tables.
    level: level_scene.Scene,
    continue_game: continue_mod.Scene,
    ending: ending_mod.Ending,
};

pub const page_width: u32 = 320;
pub const page_height: u32 = 200;

pub const Phase = enum { startup, playing, finished };
pub const UpdateResult = enum { running, finished };

/// The asset that the game reads at startup. Its first line is the title. A missing asset is not an
/// error: the title stays empty.
pub const title_asset = "TITLE.TXT";
/// The save record that F2 writes and F3 reads.
pub const save_name = "STATE";

/// One in 16.16 fixed point.
pub const one: i32 = 1 << 16;
const ball_size: u32 = 6;
const wall: u32 = 4;
const max_speed: i32 = 4 * one;

/// Palette indices of the page, and the palette that converts them. An original game keeps its
/// own palette; the conversion to RGBA happens once, when a frame is presented.
const colour_background: u8 = 0;
const colour_wall: u8 = 1;
const colour_ball: u8 = 2;
const palette = [_][3]u8{ .{ 0x10, 0x10, 0x40 }, .{ 0xa0, 0xa0, 0xa0 }, .{ 0xff, 0xe0, 0x40 } };

/// The sound: a click of `click_samples` at `click_hz`, and the device format that the game asks
/// for. The queue is kept `audio_ahead` frames ahead of the device.
const audio_format: platform.AudioFormat = .{ .channels = 1, .sample_rate = 22050 };
const click_hz: u32 = 880;
const click_samples: u32 = 441;
const audio_ahead: u64 = 2048;

/// Synthetic smoke state. Flashback simulation state belongs to the selected scene.
pub const State = struct {
    x: i32 = 160 * one,
    y: i32 = 100 * one,
    dx: i32 = one,
    dy: i32 = one / 2,
    bounces: u32 = 0,
    /// The one random generator of the game. Every draw goes through `next`, in update order.
    seed: u32 = 0x2545f491,

    /// xorshift32.
    pub fn next(self: *State) u32 {
        var s = self.seed;
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        self.seed = s;
        return s;
    }

    /// One fixed step: move, and bounce off the walls. A bounce turns the vertical speed by a small
    /// random amount, so the path does not repeat. Returns whether the ball bounced.
    pub fn step(self: *State) bool {
        self.x +%= self.dx;
        self.y +%= self.dy;
        const min: i32 = @as(i32, wall) * one;
        const max_x: i32 = @as(i32, page_width - wall - ball_size) * one;
        const max_y: i32 = @as(i32, page_height - wall - ball_size) * one;
        var bounced = false;
        if (self.x < min or self.x > max_x) {
            self.x = std.math.clamp(self.x, min, max_x);
            self.dx = -self.dx;
            bounced = true;
        }
        if (self.y < min or self.y > max_y) {
            self.y = std.math.clamp(self.y, min, max_y);
            self.dy = -self.dy;
            bounced = true;
        }
        if (bounced) {
            self.bounces +%= 1;
            const nudge: i32 = @as(i32, @intCast(self.next() & 0x3fff)) - 0x2000;
            self.dy = std.math.clamp(self.dy +% nudge, -max_speed, max_speed);
        }
        return bounced;
    }

    /// An arrow key changes the speed by a quarter pixel an update.
    pub fn push(self: *State, key: platform.Key) void {
        const q = one / 4;
        switch (key) {
            .left => self.dx = std.math.clamp(self.dx - q, -max_speed, max_speed),
            .right => self.dx = std.math.clamp(self.dx + q, -max_speed, max_speed),
            .up => self.dy = std.math.clamp(self.dy - q, -max_speed, max_speed),
            .down => self.dy = std.math.clamp(self.dy + q, -max_speed, max_speed),
            else => {},
        }
    }

    /// The canonical hash of the state: every field in a fixed order, little endian. Two runs agree
    /// exactly when their hashes do; the tests and the hosts compare this, not the pixels.
    pub fn hash(self: State) u64 {
        var h = std.hash.Wyhash.init(0);
        for ([_]u32{
            @bitCast(self.x),
            @bitCast(self.y),
            @bitCast(self.dx),
            @bitCast(self.dy),
            self.bounces,
            self.seed,
        }) |v| {
            h.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
        }
        return h.final();
    }

    /// The save record: a magic, the version, then the fields, little endian.
    pub const magic = "GPST";
    pub const version: u16 = 1;
    pub const record_len: usize = magic.len + 2 + 6 * 4;

    pub fn encode(self: State) [record_len]u8 {
        var out: [record_len]u8 = undefined;
        @memcpy(out[0..magic.len], magic);
        std.mem.writeInt(u16, out[magic.len..][0..2], version, .little);
        var at: usize = magic.len + 2;
        for ([_]u32{
            @bitCast(self.x),
            @bitCast(self.y),
            @bitCast(self.dx),
            @bitCast(self.dy),
            self.bounces,
            self.seed,
        }) |v| {
            std.mem.writeInt(u32, out[at..][0..4], v, .little);
            at += 4;
        }
        return out;
    }

    /// A record of another version is refused, not converted: there is one save format.
    pub fn decode(bytes: []const u8) error{ NotAState, WrongVersion }!State {
        if (bytes.len != record_len or
            !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.NotAState;
        if (std.mem.readInt(u16, bytes[magic.len..][0..2], .little) != version) return error.WrongVersion;
        var v: [6]u32 = undefined;
        for (&v, 0..) |*field, i| field.* = std.mem.readInt(
            u32,
            bytes[magic.len + 2 + 4 * i ..][0..4],
            .little,
        );
        return .{
            .x = @bitCast(v[0]),
            .y = @bitCast(v[1]),
            .dx = @bitCast(v[2]),
            .dy = @bitCast(v[3]),
            .bounces = v[4],
            .seed = v[5],
        };
    }
};

const ConnectedPad = struct { id: platform.ControllerId, model: platform.ControllerModel };

pub const Game = struct {
    allocator: std.mem.Allocator,
    /// The original's files and the saves, bound by the host. Null when the host has none.
    assets: ?platform.AssetSource,
    storage: ?platform.Storage,
    /// The data set that levels run from, when the host provides one.
    data: ?*const data_set.Files = null,
    phase: Phase = .startup,
    state: State = .{},
    update_count: u64 = 0,
    frames_presented: u64 = 0,
    events_consumed: u64 = 0,
    /// The hash of the last presented page, as palette indices.
    last_frame_hash: u64 = 0,
    /// The first line of `title_asset`, when the asset exists.
    title_buf: [40]u8 = @splat(0),
    title_len: usize = 0,
    saves_written: u32 = 0,
    loads_done: u32 = 0,
    audio: ?platform.AudioFormat = null,
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
    /// P's toggle, which only films read: they hold their picture while it is set.
    films_paused: bool = false,
    /// The music volume keypad + and - step, 0 to 63, for notes started afterwards.
    music_volume: u8 = 48,
    /// J was pressed: the joystick option turns on at the next frame of play outside a demo.
    joystick_requested: bool = false,
    /// The samples of the current click still to queue, and the phase of its square wave.
    click_left: u32 = 0,
    click_phase: u32 = 0,
    page: []u8,
    rgba: []u8,
    scene: Scene = .smoke,
    demo_index: u2 = 0,
    difficulty: settings_mod.Difficulty = .normal,
    level: content_level.Id = .jungle,
    story: ?story_mod.Story = null,
    /// The level the continue screen may resume.
    suspended_level: ?level_scene.Scene = null,
    /// The character records' flags as the last level left them; the next level's characters
    /// that it does not place keep them, as in the original.
    inherited: [256]behavior_world.Inherited = @splat(.{}),
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
        const page = try allocator.alloc(u8, page_width * page_height);
        errdefer allocator.free(page);
        const rgba = try allocator.alloc(
            u8,
            page_width * page_height * platform.RgbaFrame.bytes_per_pixel,
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
        const original_menu = if (assets) |source| try menu_art.load(allocator, source) else null;
        var scene: Scene = .smoke;
        if (original_menu) |menu| {
            var front = front_end.Scene.init(allocator, assets.?, menu);
            errdefer front.deinit();
            if (entry == .automatic) try front.intro();
            scene = .{ .menu = front };
        }
        return .{
            .allocator = allocator,
            .assets = assets,
            .storage = storage,
            .data = data,
            .page = page,
            .rgba = rgba,
            .settings = settings,
            .kept_settings = settings,
            .scene = scene,
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
        if (self.story) |*story| story.deinit();
        if (self.suspended_level) |*scene| scene.deinit();
        switch (self.scene) {
            .smoke => {},
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

    pub fn title(self: *const Game) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn stateHash(self: *const Game) u64 {
        if (self.scene == .level) return self.scene.level.stateHash();
        if (self.scene == .menu) return self.scene.menu.stateHash();
        if (self.scene == .continue_game) return self.scene.continue_game.stateHash();
        return self.state.hash();
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

    /// One frame: the input, one step of the state, the sound and the picture.
    pub fn update(self: *Game, p: *platform.Platform) !UpdateResult {
        if (self.phase == .finished) return .finished;
        self.update_count += 1;
        // What the last update changed: the options dialog, S, J and K.
        self.keepSettings();
        switch (self.phase) {
            .startup => {
                _ = try p.start();
                const original_content = self.scene != .smoke;
                const size = self.resolution();
                try p.setResolution(size.width, size.height);
                if (!original_content) self.audio = p.audioOpen(audio_format) catch null;
                self.readTitle();
                self.phase = .playing;
                if (self.scene == .level) try self.consumeEvents(p);
            },
            .playing => {
                try self.consumeEvents(p);
                if (self.phase == .playing and
                    self.scene == .smoke and
                    self.state.step()) self.click_left = click_samples;
            },
            .finished => {},
        }
        if (self.phase == .finished) {
            self.keepSettings();
            if (self.story) |*story| story.stopAudio(p);
            if (self.audio != null) p.audioClose();
            if (self.scene == .menu) self.scene.menu.stopAudio(p);
            if (self.scene == .level) self.scene.level.stopAudio(p);
            if (self.scene == .ending) self.scene.ending.stopMusic(p);
            return .finished;
        }
        if (self.scene == .ending) {
            const ending = &self.scene.ending;
            ending.music_enabled = self.settings.music;
            if (ending.music) |*music| {
                music.volume = self.settings.volume;
                music.player.master_volume = self.music_volume;
            }
            ending.setPaused(self.films_paused, p.nowNs());
            try ending.update(p);
            if (ending.finished) {
                const next = try self.titleMenu();
                ending.stopMusic(p);
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
            front.volume = self.settings.volume;
            front.joystick = self.settings.joystick;
            front.films_paused = self.films_paused;
            front.music_volume = self.music_volume;
            if (self.pads.repeat()) |held| try front.pad(held, p.nowNs());
            if (front.stage == .quit) {
                front.stopAudio(p);
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
        self.feedAudio(p);
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
                scene.stopAudio(p);
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
            if (story.music) |*music| {
                music.volume = self.settings.volume;
                music.player.master_volume = self.music_volume;
            }
            story.player.setPaused(self.films_paused, now);
            if (!try story.update(p)) {
                try self.present(p);
                return true;
            }
            const paused = now - story.started_ns;
            story.stopAudio(p);
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
        }
        switch (scene.outcome) {
            .playing => {
                try scene.pumpAudio(p, self.settings);
                return scene.needsCatchup(now);
            },
            .level => |destination| {
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
                scene.stopAudio(p);
                scene.deinit();
                self.level = destination;
                self.scene = .{ .level = next };
            },
            .defeated => {
                if (scene.film != null) return false;
                scene.stopAudio(p);
                const next = try continue_mod.Scene.init(
                    self.allocator,
                    self.assets.?,
                    scene.world.score,
                );
                self.suspended_level = scene.*;
                self.scene = .{ .continue_game = next };
            },
            .aborted => {
                scene.stopAudio(p);
                const next = try self.titleMenu();
                self.retire(scene);
                self.scene = .{ .menu = next };
            },
            .ending => {
                scene.stopAudio(p);
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

    /// The first line of `title_asset`, when the host has the asset.
    fn readTitle(self: *Game) void {
        const assets = self.assets orelse return;
        var owned = assets.readAll(title_asset, 4096) catch return;
        defer owned.deinit();
        const line = std.mem.trimEnd(u8, std.mem.sliceTo(owned.bytes, '\n'), "\r");
        self.title_len = @min(line.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], line[0..self.title_len]);
    }

    fn consumeEvents(self: *Game, p: *platform.Platform) !void {
        var buf: [32]platform.Event = undefined;
        while (true) {
            const n = p.pollEvents(&buf);
            if (n == 0) break;
            for (buf[0..n]) |raw| {
                self.events_consumed += 1;
                const event = self.padEvent(p, raw) orelse continue;
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
                if (self.scene == .menu) {
                    try self.scene.menu.event(event);
                    for (pad.slice()) |change| try self.scene.menu.pad(change, event.time_ns);
                    continue;
                }
                switch (event.payload) {
                    .quit => self.phase = .finished,
                    .key_down => |k| switch (k.key) {
                        .escape => self.phase = .finished,
                        .f2 => self.saveState(),
                        .f3 => self.loadState(),
                        else => self.state.push(k.key),
                    },
                    else => {},
                }
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

    /// Keeps the settings in storage when they have changed since storage last kept them. A
    /// failed save is tried again at the next change.
    fn keepSettings(self: *Game) void {
        if (std.meta.eql(self.settings, self.kept_settings)) return;
        settings_mod.save(self.storage, self.settings) catch return;
        self.kept_settings = self.settings;
    }

    fn saveState(self: *Game) void {
        const storage = self.storage orelse return;
        const record = self.state.encode();
        storage.save(save_name, &record) catch return;
        self.saves_written += 1;
    }

    /// A record that is missing, damaged or of another version leaves the state as it is.
    fn loadState(self: *Game) void {
        const storage = self.storage orelse return;
        var owned = storage.load(save_name) catch return;
        defer owned.deinit();
        self.state = State.decode(owned.bytes) catch return;
        self.loads_done += 1;
    }

    /// Keeps the device queue `audio_ahead` frames ahead: the click while it lasts, then silence.
    fn feedAudio(self: *Game, p: *platform.Platform) void {
        const format = self.audio orelse return;
        const status = p.audioStatus();
        if (status.queued_frames >= audio_ahead) return;
        var samples: [512]i16 = undefined;
        const frames = samples.len / format.channels;
        const half_period = @max(format.sample_rate / (2 * click_hz), 1);
        for (0..frames) |f| {
            var value: i16 = 0;
            if (self.click_left > 0) {
                value = if ((self.click_phase / half_period) % 2 == 0) 6000 else -6000;
                self.click_phase += 1;
                self.click_left -= 1;
            }
            for (0..format.channels) |c| samples[f * format.channels + c] = value;
        }
        _ = p.audioQueue(samples[0 .. frames * format.channels]) catch {};
    }

    fn resolution(self: *const Game) platform.Size {
        return switch (self.scene) {
            .smoke => .{ .width = page_width, .height = page_height },
            .menu => |*front| front.resolution(),
            .level, .continue_game, .ending => .{ .width = 256, .height = 224 },
        };
    }

    fn present(self: *Game, p: *platform.Platform) !void {
        const size = self.resolution();
        try p.setResolution(size.width, size.height);
        if (self.story) |*story| {
            const indices = self.page[0..57344];
            const rgba = self.rgba[0 .. 57344 * 4];
            try story.player.draw(indices, rgba);
            self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
            try p.present(.{ .width = 256, .height = 224, .stride = 256 * 4, .pixels = rgba });
            self.frames_presented += 1;
            return;
        }
        if (self.scene == .level) {
            const indices = self.page[0..57344];
            const frame = self.rgba[0 .. 57344 * 4];
            try self.scene.level.draw(indices, frame, self.settings);
            self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
            try p.present(.{ .width = 256, .height = 224, .stride = 256 * 4, .pixels = frame });
            self.frames_presented += 1;
            return;
        }
        if (self.scene == .ending) {
            const indices = self.page[0..57344];
            const frame = self.rgba[0 .. 57344 * 4];
            try self.scene.ending.draw(indices, frame);
            self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
            try p.present(.{ .width = 256, .height = 224, .stride = 256 * 4, .pixels = frame });
            self.frames_presented += 1;
            return;
        }
        if (self.scene == .continue_game) {
            const indices = self.page[0..57344];
            const frame = self.rgba[0 .. 57344 * 4];
            try self.scene.continue_game.draw(indices, frame);
            self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
            try p.present(.{ .width = 256, .height = 224, .stride = 256 * 4, .pixels = frame });
            self.frames_presented += 1;
            return;
        }
        if (self.scene == .menu) {
            const scene = &self.scene.menu;
            const count = size.width * size.height;
            const indices = self.page[0..count];
            const frame = self.rgba[0 .. count * 4];
            try scene.draw(indices, frame);
            self.last_frame_hash = std.hash.Wyhash.hash(0, indices);
            try p.present(.{
                .width = size.width,
                .height = size.height,
                .stride = size.width * 4,
                .pixels = frame,
            });
            self.frames_presented += 1;
            return;
        }
        self.draw();
        self.last_frame_hash = std.hash.Wyhash.hash(0, self.page);
        for (self.page, 0..) |index, i| {
            const rgb = palette[index];
            self.rgba[i * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], 0xff };
        }
        try p.present(.{
            .width = page_width,
            .height = page_height,
            .stride = page_width * platform.RgbaFrame.bytes_per_pixel,
            .pixels = self.rgba,
        });
        self.frames_presented += 1;
    }

    /// The page: the walls, then the ball at the integer part of its position.
    fn draw(self: *Game) void {
        @memset(self.page, colour_background);
        for (0..page_height) |y| {
            for (0..page_width) |x| {
                if (x < wall or y < wall or x >= page_width - wall or y >= page_height - wall) {
                    self.page[y * page_width + x] = colour_wall;
                }
            }
        }
        // A loaded record is trusted no further than the page: the ball is drawn inside it.
        const bx: u32 = @intCast(std.math.clamp(
            self.state.x >> 16,
            0,
            @as(i32, page_width - ball_size),
        ));
        const by: u32 = @intCast(std.math.clamp(
            self.state.y >> 16,
            0,
            @as(i32, page_height - ball_size),
        ));
        for (by..by + ball_size) |y| {
            @memset(self.page[y * page_width + bx ..][0..ball_size], colour_ball);
        }
    }
};

const testing = std.testing;

test "the same pushes give the same state, and a different push a different hash" {
    var a: State = .{};
    var b: State = .{};
    for (0..500) |i| {
        if (i == 100) {
            a.push(.up);
            b.push(.up);
        }
        _ = a.step();
        _ = b.step();
    }
    try testing.expectEqual(a.hash(), b.hash());
    try testing.expect(a.bounces > 0);
    b.push(.left);
    _ = a.step();
    _ = b.step();
    try testing.expect(a.hash() != b.hash());
}

test "the ball stays inside the walls" {
    var s: State = .{ .dx = max_speed, .dy = -max_speed };
    for (0..5000) |_| {
        _ = s.step();
        try testing.expect(s.x >= @as(i32, wall) * one and
            s.x <= @as(i32, page_width - wall - ball_size) * one);
        try testing.expect(s.y >= @as(i32, wall) * one and
            s.y <= @as(i32, page_height - wall - ball_size) * one);
    }
}

test "a save record comes back as the same state, and another version is refused" {
    var s: State = .{};
    for (0..123) |_| _ = s.step();
    const record = s.encode();
    const back = try State.decode(&record);
    try testing.expectEqual(s.hash(), back.hash());

    var other = record;
    std.mem.writeInt(u16, other[State.magic.len..][0..2], State.version + 1, .little);
    try testing.expectError(error.WrongVersion, State.decode(&other));
    try testing.expectError(error.NotAState, State.decode(record[0..10]));
}

test "F2 saves through the bound storage, F3 loads it back, and the title comes from the assets" {
    var assets = memory.MemoryAssetSource.init(testing.allocator);
    defer assets.deinit();
    try assets.add(title_asset, "A ball in a box\r\nsecond line");
    var storage = memory.MemoryStorage.init(testing.allocator);
    defer storage.deinit();
    var game = try Game.init(testing.allocator, assets.assetSource(), storage.storage());
    defer game.deinit();

    game.readTitle();
    try testing.expectEqualStrings("A ball in a box", game.title());
    for (0..40) |_| _ = game.state.step();
    const saved = game.state.hash();
    game.saveState();
    for (0..40) |_| _ = game.state.step();
    game.loadState();
    try testing.expectEqual(saved, game.state.hash());
    try testing.expectEqual(@as(u32, 1), game.saves_written);
    try testing.expectEqual(@as(u32, 1), game.loads_done);

    // Without providers, nothing is read or written, and nothing fails.
    var bare = try Game.init(testing.allocator, null, null);
    defer bare.deinit();
    bare.readTitle();
    bare.saveState();
    bare.loadState();
    try testing.expectEqual(@as(u32, 0), bare.saves_written);
}

test "settings changed in a game are there in the next, and the old volume record is not read" {
    var store = memory.MemoryStorage.init(testing.allocator);
    defer store.deinit();
    try store.storage().save("VOLUME", "50\n");
    var first = try Game.init(testing.allocator, null, store.storage());
    try testing.expectEqual(settings_mod.Settings{}, first.settings);
    first.settings.volume = 30;
    first.settings.joystick = true;
    first.keepSettings();
    first.deinit();
    var reopened = try Game.init(testing.allocator, null, store.storage());
    defer reopened.deinit();
    try testing.expectEqual(@as(u8, 30), reopened.settings.volume);
    try testing.expect(reopened.settings.joystick);
}
