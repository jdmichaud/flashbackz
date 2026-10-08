//! Shared application lifecycle and tagged scene ownership. Hosts provide input, time and
//! presentation; the selected scene owns its content and simulation. The no-content branch
//! retains the template platform smoke program and save contract for host tests.
const std = @import("std");
const platform = @import("platform.zig");
const menu_art = @import("content/menu_artwork.zig");
const front_end = @import("scenes/front_end.zig");
const continue_mod = @import("scenes/continue_game.zig");
const story_mod = @import("scenes/story.zig");
const jungle_mod = @import("scenes/jungle.zig");
const level_scene = @import("scenes/level.zig");
const data_set = @import("behavior/data_set.zig");
const content_level = @import("content/level.zig");
const demo = @import("content/demo.zig");
const game_options = @import("scenes/game_options.zig");
const memory = @import("memory.zig");
const settings_mod = @import("settings.zig");
const step_clock = @import("step_clock.zig");
const volume_preference = @import("volume_preference.zig");
pub const Entry = union(enum) {
    automatic,
    menu_development,
    jungle_development,
    level_development: content_level.Id,
    /// A level run from the behavior tables (needs the data set).
    table_level_development: content_level.Id,
};
const Scene = union(enum) {
    smoke,
    menu: front_end.Scene,
    jungle: jungle_mod.Scene,
    /// A level run from the behavior tables.
    level: level_scene.Scene,
    continue_game: continue_mod.Scene,
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
    preferences: game_options.Settings = .{},
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
        const preferences: game_options.Settings = .{ .volume = volume_preference.load(storage) };
        if (entry == .table_level_development) {
            const level = entry.table_level_development;
            const scene = try level_scene.Scene.load(
                allocator,
                assets orelse return error.OriginalContentRequired,
                data orelse return error.DataSetRequired,
                level,
                .normal,
            );
            return .{
                .allocator = allocator,
                .assets = assets,
                .storage = storage,
                .data = data,
                .page = page,
                .rgba = rgba,
                .preferences = preferences,
                .level = level,
                .scene = .{ .level = scene },
            };
        }
        if (entry == .jungle_development or entry == .level_development) {
            const level: content_level.Id = if (entry == .level_development) entry.level_development else .jungle;
            var scene = try jungle_mod.Scene.loadLevel(
                allocator,
                assets orelse return error.OriginalContentRequired,
                level,
                .normal,
            );
            scene.settings = preferences;
            return .{
                .allocator = allocator,
                .assets = assets,
                .storage = storage,
                .data = data,
                .page = page,
                .rgba = rgba,
                .preferences = preferences,
                .level = level,
                .scene = .{ .jungle = scene },
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
            .preferences = preferences,
            .scene = scene,
        };
    }

    pub fn deinit(self: *Game) void {
        if (self.story) |*story| story.deinit();
        if (self.suspended_level) |*scene| scene.deinit();
        switch (self.scene) {
            .smoke => {},
            .menu => |*scene| scene.deinit(),
            .jungle => |*scene| scene.deinit(),
            .level => |*scene| scene.deinit(),
            .continue_game => |*scene| scene.deinit(),
        }
        self.allocator.free(self.page);
        self.allocator.free(self.rgba);
        self.* = undefined;
    }

    pub fn title(self: *const Game) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn stateHash(self: *const Game) u64 {
        if (self.scene == .jungle) {
            const world = std.hash.Wyhash.hash(
                self.scene.jungle.stateHash(),
                &.{ @backingInt(self.level), @backingInt(self.difficulty) },
            );
            if (self.story) |story| {
                var hash = std.hash.Wyhash.init(world);
                hash.update(&.{
                    if (story.kind) |kind| @backingInt(kind) else 0xff,
                    @intFromBool(story.skip),
                    @intFromBool(story.player.confirmed),
                });
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, story.player.playback.frame)));
                return hash.final();
            }
            return world;
        }
        if (self.scene == .level) return self.scene.level.stateHash();
        if (self.scene == .menu) return self.scene.menu.stateHash();
        if (self.scene == .continue_game) return self.scene.continue_game.stateHash();
        return self.state.hash();
    }

    pub fn sceneKind(self: *const Game) std.meta.Tag(Scene) {
        return std.meta.activeTag(self.scene);
    }

    pub fn jungle(self: *Game) ?*jungle_mod.Scene {
        return if (self.scene == .jungle) &self.scene.jungle else null;
    }

    pub fn needsCatchup(self: *const Game, now_ns: u64) bool {
        if (self.story) |*story| return story.player.needsCatchup(now_ns);
        if (self.scene == .jungle) return self.scene.jungle.needsCatchup(now_ns);
        if (self.scene == .level) return self.scene.level.needsCatchup(now_ns);
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
        switch (self.phase) {
            .startup => {
                _ = try p.start();
                const original_content = self.scene != .smoke;
                const size = self.resolution();
                try p.setResolution(size.width, size.height);
                if (!original_content) self.audio = p.audioOpen(audio_format) catch null;
                self.readTitle();
                self.phase = .playing;
                if (self.scene == .jungle) try self.consumeEvents(p);
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
            if (self.story) |*story| story.stopAudio(p);
            if (self.audio != null) p.audioClose();
            if (self.scene == .menu) self.scene.menu.stopAudio(p);
            if (self.jungle()) |scene| scene.stopAudio(p);
            if (self.scene == .level) self.scene.level.stopAudio(p);
            return .finished;
        }
        if (self.scene == .level) {
            if (try self.updateLevel(p)) return .running;
        }
        if (self.scene == .menu) {
            const front = &self.scene.menu;
            front.music_enabled = self.preferences.music;
            front.volume = self.preferences.volume;
            if (front.stage == .quit) {
                front.stopAudio(p);
                self.phase = .finished;
                return .finished;
            }
            try front.update(p);
            if (front.stage == .demo_ready and self.data != null) {
                if (self.demo_index == 3) {
                    self.demo_index = 0;
                    try front.intro();
                } else {
                    var next = try level_scene.Scene.loadDemo(
                        self.allocator,
                        self.assets.?,
                        self.data.?,
                        self.demo_index,
                    );
                    next.sound_enabled = self.preferences.sound_fx;
                    front.deinit();
                    self.scene = .{ .level = next };
                    self.demo_index += 1;
                }
            } else if (front.stage == .ready and self.data != null) {
                var next = try level_scene.Scene.load(
                    self.allocator,
                    self.assets.?,
                    self.data.?,
                    front.selected_level,
                    front.difficulty,
                );
                next.sound_enabled = self.preferences.sound_fx;
                self.level = front.selected_level;
                self.difficulty = front.difficulty;
                front.deinit();
                self.scene = .{ .level = next };
            } else if (front.stage == .demo_ready) {
                // Without a data set, the hand-written scene plays the demos.
                if (self.demo_index == 3) {
                    self.demo_index = 0;
                    try front.intro();
                } else {
                    const recording = try demo.load(self.allocator, self.assets.?, self.demo_index);
                    errdefer self.allocator.free(recording.controls);
                    var next = try jungle_mod.Scene.loadLevel(
                        self.allocator,
                        self.assets.?,
                        recording.descriptor.level,
                        .normal,
                    );
                    next.settings = self.preferences;
                    next.replay = .{ .samples = recording.controls };
                    if (recording.descriptor.start) |start| {
                        next.pose.position = start.position;
                        next.environment.room = start.room;
                    }
                    front.deinit();
                    self.scene = .{ .jungle = next };
                    self.demo_index += 1;
                }
            } else if (front.stage == .ready) {
                var next = try jungle_mod.Scene.loadLevel(
                    self.allocator,
                    self.assets.?,
                    front.selected_level,
                    front.difficulty,
                );
                next.pending_movie = content_level.opening(front.selected_level);
                if (next.pending_movie != null) next.clock = try step_clock.Clock.init(step_clock.jungle, p.nowNs());
                self.level = front.selected_level;
                next.settings = self.preferences;
                self.difficulty = front.difficulty;
                front.deinit();
                self.scene = .{ .jungle = next };
            }
        }
        if (self.jungle()) |scene| {
            self.applyPreferences(scene.settings);
            const now = p.nowNs();
            if (self.story == null and
                scene.message == null and
                scene.options == null and
                scene.dialog == null and
                scene.pending_movie != null and
                scene.needsCatchup(now))
            {
                const movie = scene.pending_movie.?;
                scene.pending_movie = null;
                if (try scene.latchMovieInput()) {
                    scene.stopAudio(p);
                    self.story = try story_mod.Story.open(
                        self.allocator,
                        self.assets.?,
                        movie,
                        now,
                        if (scene.input.use_held) .enter else if (scene.input.left_action) .left_shift else if (scene.input.right_action) .right_shift else null,
                    );
                }
            }
            if (self.story) |*story| {
                story.music_enabled = self.preferences.music;
                if (story.music) |*music| music.volume = self.preferences.volume;
                if (try story.update(p)) {
                    const defeated = story.kind == .disintegration or
                        story.kind == .reactor_failure;
                    const paused = now - story.started_ns;
                    story.stopAudio(p);
                    story.deinit();
                    try scene.resumeMovie(paused);
                    self.story = null;
                    if (defeated) scene.defeated = true;
                } else {
                    try self.present(p);
                    return .running;
                }
            }
            try scene.update(now);
            self.applyPreferences(scene.settings);
            if (scene.options) |*options| if (options.menu.free_memory_mb == null) {
                if (p.availableMemory()) |bytes| options.menu.free_memory_mb = bytes / (1024 * 1024);
            };
            if (scene.aborted or (scene.defeated and scene.replay != null)) {
                scene.stopAudio(p);
                const art = (try menu_art.load(self.allocator, self.assets.?)) orelse return error.MissingMenu;
                var next = front_end.Scene.init(self.allocator, self.assets.?, art);
                next.difficulty = self.difficulty;
                next.music_enabled = self.preferences.music;
                scene.deinit();
                self.scene = .{ .menu = next };
            } else if (scene.exits.requested) |destination| {
                var next = try jungle_mod.Scene.loadLevel(
                    self.allocator,
                    self.assets.?,
                    destination,
                    self.difficulty,
                );
                next.settings = scene.settings;
                next.score = scene.score;
                next.random = scene.random;
                next.input = scene.input;
                std.mem.swap(@TypeOf(next.pending), &next.pending, &scene.pending);
                next.clock = try step_clock.Clock.init(step_clock.jungle, now);
                next.pending_movie = content_level.opening(destination);
                self.level = destination;
                scene.stopAudio(p);
                scene.deinit();
                self.scene = .{ .jungle = next };
            } else if (scene.defeated) {
                scene.stopAudio(p);
                const next = try continue_mod.Scene.init(
                    self.allocator,
                    self.assets.?,
                    scene.score,
                );
                scene.deinit();
                self.scene = .{ .continue_game = next };
            } else {
                try scene.pumpAudio(p);
                if (self.needsCatchup(now)) return .running;
            }
        }
        if (self.scene == .continue_game) {
            const dialog = &self.scene.continue_game;
            try dialog.update(p.nowNs());
            if (dialog.menu.outcome) |choice| resume_level: {
                if (self.suspended_level) |*level| {
                    if (choice == .retry) {
                        if (!level.continueAfterDefeat()) {
                            // No checkpoint: the level starts again, from its entry score.
                            var fresh = try level_scene.Scene.load(
                                self.allocator,
                                self.assets.?,
                                self.data.?,
                                level.level,
                                self.difficulty,
                            );
                            fresh.world.score = level.world.entry_score;
                            fresh.world.entry_score = level.world.entry_score;
                            fresh.world.random = level.world.random;
                            level.deinit();
                            level.* = fresh;
                        }
                        dialog.deinit();
                        self.scene = .{ .level = level.* };
                        self.suspended_level = null;
                        break :resume_level;
                    }
                    level.deinit();
                    self.suspended_level = null;
                }
                const art = (try menu_art.load(self.allocator, self.assets.?)) orelse return error.MissingMenu;
                var next = front_end.Scene.init(self.allocator, self.assets.?, art);
                errdefer next.deinit();
                next.difficulty = self.difficulty;
                if (choice == .retry) try next.startLevel(self.level, dialog.menu.activation_key) else try next.gameOver(dialog.menu.activation_key);
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
                    null,
                    now,
                    null,
                );
            }
            const story = &self.story.?;
            story.music_enabled = self.preferences.music;
            if (!try story.update(p)) {
                try self.present(p);
                return true;
            }
            const paused = now - story.started_ns;
            story.stopAudio(p);
            story.deinit();
            self.story = null;
            try scene.finishFilm(now, paused);
        }
        try scene.update(now);
        switch (scene.outcome) {
            .playing => {
                try scene.pumpAudio(p);
                return scene.needsCatchup(now);
            },
            .level => |destination| {
                var next = try level_scene.Scene.load(
                    self.allocator,
                    self.assets.?,
                    self.data.?,
                    destination,
                    self.difficulty,
                );
                next.world.score = scene.world.score;
                next.world.entry_score = scene.world.score;
                next.world.random = scene.world.random;
                next.world.shake = scene.world.shake;
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
                const art = (try menu_art.load(self.allocator, self.assets.?)) orelse
                    return error.MissingMenu;
                var next = front_end.Scene.init(self.allocator, self.assets.?, art);
                next.difficulty = self.difficulty;
                next.music_enabled = self.preferences.music;
                scene.deinit();
                self.scene = .{ .menu = next };
            },
        }
        return false;
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
            for (buf[0..n]) |event| {
                self.events_consumed += 1;
                if (self.story) |*story| {
                    if (event.payload == .quit) {
                        self.phase = .finished;
                        continue;
                    }
                    if (story.event(event)) continue;
                    switch (self.scene) {
                        .jungle => |*scene| try scene.enqueue(event),
                        .level => |*scene| try scene.enqueue(event),
                        else => {},
                    }
                    continue;
                }
                if (self.jungle()) |scene| {
                    switch (event.payload) {
                        .quit => self.phase = .finished,
                        else => try scene.enqueue(event),
                    }
                    continue;
                }
                if (self.scene == .level) {
                    if (event.payload == .quit) self.phase = .finished else try self.scene.level.enqueue(event);
                    continue;
                }
                if (self.scene == .continue_game) {
                    if (event.payload == .quit) self.phase = .finished else try self.scene.continue_game.event(event);
                    continue;
                }
                if (self.scene == .menu) {
                    try self.scene.menu.event(event);
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

    fn applyPreferences(self: *Game, settings: game_options.Settings) void {
        const volume_changed = self.preferences.volume != settings.volume;
        self.preferences = settings;
        if (volume_changed) volume_preference.save(self.storage, settings.volume) catch {};
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
            .jungle, .level, .continue_game => .{ .width = 256, .height = 224 },
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
        if (self.jungle()) |scene| {
            const indices = self.page[0..57344];
            const frame = self.rgba[0 .. 57344 * 4];
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
        if (self.scene == .level) {
            const indices = self.page[0..57344];
            const frame = self.rgba[0 .. 57344 * 4];
            try self.scene.level.draw(indices, frame);
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

test "applied volume survives a new game instance and invalid preferences use defaults" {
    var store = memory.MemoryStorage.init(testing.allocator);
    defer store.deinit();
    for ([_]u8{ 50, 0, 100 }) |volume| {
        var first = try Game.init(testing.allocator, null, store.storage());
        first.applyPreferences(.{ .volume = volume });
        first.deinit();
        var reopened = try Game.init(testing.allocator, null, store.storage());
        defer reopened.deinit();
        try testing.expectEqual(volume, reopened.preferences.volume);
    }
    for ([_][]const u8{ "101", "-1", "broken", "" }) |record| {
        try store.storage().save(volume_preference.key, record);
        var game = try Game.init(testing.allocator, null, store.storage());
        defer game.deinit();
        try testing.expectEqual(@as(u8, 100), game.preferences.volume);
    }
}
