//! The ending (flashback-re docs/rules/engine-ending-zoom.md 1-5): the ending film, then the
//! ending list, under one music. The credits show over the list only, not over the ending film.
//! When the game was finished in play, scene 73 and the final score follow until a button press.
//!
//! The films stage has two modes (`Replay`). The ending film plays in normal mode: each
//! picture once, for its hold. The list plays in replay mode: each picture shows again while
//! the film waits, and `Credits` types one step at each present. The ending's own clock
//! (`cadence`) times this stage. Scene 73 plays on the clock of its own `vector.Player`.
//!
//! The scene ends when it sets `finished`. Game reads it after each `update`.
const std = @import("std");
const platform = @import("../platform.zig");
const data_set = @import("../behavior/data_set.zig");
const floppy_interface = @import("../content/floppy_interface.zig");
const palette = @import("../content/palette.zig");
const font_mod = @import("../content/font.zig");
const text_renderer = @import("../render/text.zig");
const vector = @import("vector_player.zig");
const input_mod = @import("../input.zig");
const film_mod = @import("../vector_film.zig");
const soundtrack = @import("../audio/soundtrack.zig");

pub const width = 256;
pub const height = 224;
const pixel_count = width * height;

/// The scene a level requests to end the game, and the scene that precedes the final score.
pub const ending_scene = 61;
pub const score_scene = 73;

pub const Ending = struct {
    allocator: std.mem.Allocator,
    assets: platform.AssetSource,
    /// Owns the scenes and credits read from the data set.
    arena: *std.heap.ArenaAllocator,
    scenes: data_set.Scenes,
    /// The ending film, then the ending list.
    films: [17]data_set.Film = undefined,
    film_count: usize = 0,
    film_index: usize = 0,
    player: ?vector.Player = null,
    music: ?soundtrack.Soundtrack = null,
    music_enabled: bool = true,
    credits: Credits,
    /// Finishing the game shows the final score; the title's code does not.
    score: ?u32,
    stage: Stage = .films,
    /// The last picture and its colors, for the score screen.
    picture: [pixel_count]u8 = @splat(0),
    colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    text_colors: palette.Bank,
    /// "SCORE  ", followed by the score's eight digits.
    score_label: [48]u8,
    code: [7]u8,
    font: font_mod.Font,
    /// Keys held when a screen starts must be released before they count.
    held: std.EnumSet(platform.Key) = .{},
    finished: bool = false,
    /// The ending list runs in replay mode: every picture is presented once, then again while
    /// the film waits, with the credits typed one step per present.
    replay: Replay = .{},
    image: [pixel_count]u8 = @splat(0),
    image_colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    /// The ending's own clock: presents wait for their timer ticks, then a display refresh.
    cadence: vector.Cadence = .{},
    origin_ns: ?u64 = null,
    /// P's toggle as the films last saw it.
    pause_requested: bool = false,
    /// Since when the films stand still for P.
    paused_at: ?u64 = null,
    /// Timer ticks the last present lasted, which the next credits step sees elapsed.
    elapsed_ticks: u32 = 0,

    const Stage = enum { films, score_film, score };

    pub fn init(
        allocator: std.mem.Allocator,
        assets: platform.AssetSource,
        files: *const data_set.Files,
        final_score: ?u32,
    ) !Ending {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        var diagnostic: data_set.Diagnostic = .{};
        const scenes = data_set.loadScenes(
            allocator,
            arena.allocator(),
            files,
            &diagnostic,
        ) catch |err| {
            std.log.err("data set: {s}", .{ diagnostic.message() });
            return err;
        };
        const interface = try floppy_interface.load(allocator, assets);
        var font_file = try assets.readAll("DATA/FB_TXT.FNT", 16384);
        defer font_file.deinit();
        var ending: Ending = .{
            .allocator = allocator,
            .assets = assets,
            .arena = arena,
            .scenes = scenes,
            .credits = .{ .steps = scenes.ending.credits },
            .score = final_score,
            .text_colors = interface.text_colors,
            .score_label = interface.continue_labels[4],
            .code = interface.ending_code,
            .font = try font_mod.decode(allocator, font_file.bytes),
        };
        errdefer ending.font.deinit();
        if (scenes.film(ending_scene)) |film| {
            ending.add(film);
        }
        for (scenes.ending.scenes) |scene| {
            if (scenes.film(scene)) |film| {
                ending.add(film);
            }
        }
        if (ending.film_count == 0) {
            std.log.err("data set: scenes.zon: no film for the ending (scene {d})", .{
                ending_scene,
            });
            return error.NoEndingFilm;
        }
        for (scenes.ending.credits) |credit| {
            if (credit == .text) {
                for (credit.text) |byte| {
                    if (byte != '|' and ending.font.glyph(byte) == null) {
                        std.log.err(
                            "data set: scenes.zon: the font has no character {d} of the credits",
                            .{ byte },
                        );
                        return error.MissingGlyph;
                    }
                }
            }
        }
        // One music plays from the first film to the end of the list.
        if (ending.films[0].music) |name| {
            ending.music = try soundtrack.Soundtrack.open(allocator, assets, name);
        }
        errdefer if (ending.music) |*music| music.deinit();
        try ending.openFilm(0);
        return ending;
    }

    fn add(self: *Ending, film: data_set.Film) void {
        if (self.film_count == self.films.len) return;
        self.films[self.film_count] = film;
        self.film_count += 1;
    }

    pub fn openFilm(self: *Ending, index: usize) !void {
        if (self.player) |*player| {
            player.deinit();
        }
        self.player = null;
        self.film_index = index;
        const film = self.films[index];
        self.player = try vector.Player.open(self.allocator, self.assets, film.film, film.entry);
        // The ending film plays normally; replay mode and the credits start with the list.
        self.replay = .{ .normal = index == 0 };
    }

    pub fn deinit(self: *Ending) void {
        if (self.player) |*player| {
            player.deinit();
        }
        if (self.music) |*music| {
            music.deinit();
        }
        self.font.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// Runs the presents due now: in the films stage at most 16, and a pause stops after the
    /// present in progress. Scene 73 presents through its player.
    pub fn update(self: *Ending, p: *platform.Platform) !void {
        const now = p.nowNs();
        switch (self.stage) {
            .films => {
                if (self.paused_at == null and self.origin_ns == null) {
                    self.origin_ns = now;
                }
                var work: usize = 0;
                while (self.stage == .films and self.due(now) and work < 16) : (work += 1) {
                    if (!try self.present()) {
                        try self.nextFilm();
                    }
                    if (self.pause_requested) {
                        self.paused_at = now;
                        break;
                    }
                }
            },
            .score_film => {
                const player = &self.player.?;
                if (try player.update(now)) {
                    try self.nextFilm();
                }
            },
            .score => {},
        }
    }

    /// P's toggle, as the film player reads it (`vector_player.Player.setPaused`): the films
    /// stop after the present in progress, and the next present comes at once when P is
    /// pressed again. The music plays on.
    pub fn setPaused(self: *Ending, paused: bool, now_ns: u64) void {
        if (self.player) |*player| {
            player.setPaused(paused, now_ns);
        }
        self.pause_requested = paused;
        if (paused) {
            if (self.origin_ns == null and self.paused_at == null) {
                self.paused_at = now_ns;
            }
            return;
        }
        if (self.paused_at == null) return;
        self.paused_at = null;
        if (self.origin_ns) |*origin| {
            origin.* = now_ns -| self.cadence.deadline_ns;
        }
    }

    fn due(self: *const Ending, now_ns: u64) bool {
        if (self.paused_at != null) return false;
        const origin = self.origin_ns orelse return true;
        return now_ns -| origin >= self.cadence.deadline_ns;
    }

    /// The next present of the current film: the picture with the credits on it. False when
    /// the film has no more.
    pub fn present(self: *Ending) !bool {
        return self.presentAfter(self.elapsed_ticks);
    }

    /// The next present, `elapsed` timer ticks after the previous one. A new picture or a page
    /// draws its picture; a hold keeps the image. In replay mode `Credits` can type one step
    /// over the image. Then the present holds for its period, to the next display refresh.
    pub fn presentAfter(self: *Ending, elapsed: u32) !bool {
        const player = &(self.player orelse return false);
        const step = self.replay.next(player.movie.frames) orelse return false;
        const frame = player.movie.frames[step.frame];
        // A hold presents the shown picture again, credits included.
        if (step.kind == .picture or step.kind == .page) {
            var view = player.movie.view();
            view.texts = self.replay.normal;
            try view.drawPicture(step.frame, &self.image);
        }
        self.image_colors = frame.colors;
        @memcpy(self.image_colors[0xe0..0xf0], &self.text_colors);
        // In replay mode every palette change also turns film colour 0xd0 white.
        if (!self.replay.normal) {
            self.image_colors[0xd0] = .{ .r = 255, .g = 255, .b = 255 };
        }
        if (!self.replay.normal and self.credits.present(elapsed, step.kind, step.new_background)) {
            try self.credits.draw(&self.image, &self.font);
        }
        const before = self.cadence.elapsedTicks();
        try self.cadence.hold(step.period);
        self.elapsed_ticks = @intCast(self.cadence.elapsedTicks() - before);
        return true;
    }

    /// After a film: the next of the list, or scene 73 and the score, or the end.
    fn nextFilm(self: *Ending) !void {
        self.keepPicture();
        if (self.stage == .films and self.film_index + 1 < self.film_count) {
            return self.openFilm(self.film_index + 1);
        }
        if (self.stage == .films) {
            if (self.score == null) {
                self.finished = true;
                return;
            }
            const film = self.scenes.film(score_scene) orelse {
                self.stage = .score;
                return;
            };
            self.stage = .score_film;
            self.film_index = 0;
            if (self.player) |*player| {
                player.deinit();
            }
            self.player = try vector.Player.open(
                self.allocator,
                self.assets,
                film.film,
                film.entry,
            );
            return;
        }
        self.stage = .score;
        self.held = .{};
    }

    /// The last film picture stays under the score.
    fn keepPicture(self: *Ending) void {
        if (self.stage != .score_film) return;
        const player = &(self.player orelse return);
        player.movie.view().drawPicture(player.playback.frame, &self.picture) catch return;
        self.colors = player.movie.frames[player.playback.frame].colors;
    }

    /// Tab or Backspace skips: during the ending film only that film, during the list the rest
    /// of it. On the score screen a button ends the game.
    pub fn event(self: *Ending, input: platform.Event) void {
        switch (input.payload) {
            .key_up => |key| self.held.remove(key.key),
            .focus_lost => self.held = .{},
            .key_down => |key| {
                if (key.repeat or self.held.contains(key.key)) return;
                self.held.insert(key.key);
                switch (self.stage) {
                    // Escape too, unlike the original (user decision, 2026-10-09).
                    .films => if (key.key == .tab or key.key == .backspace or key.key == .escape)
                        self.skipFilm(),
                    .score_film => {},
                    .score => switch (key.key) {
                        .enter, .space, .left_shift, .right_shift, .backspace, .tab => {
                            self.finished = true;
                        },
                        else => {},
                    },
                }
            },
            else => {},
        }
    }

    /// A pad's press (PLAN GS-3): Y or START skips a film, a button ends the score screen.
    pub fn pad(self: *Ending, change: input_mod.Change) void {
        if (!change.down or change.repeat) return;
        switch (self.stage) {
            .films => if (change.action == .inventory or change.action == .pause) self.skipFilm(),
            .score_film => {},
            .score => if (!change.action.isDirection()) {
                self.finished = true;
            },
        }
    }

    /// Skipping the ending film leaves the list to play; skipping in the list ends it. A held
    /// film does not look at its keys.
    fn skipFilm(self: *Ending) void {
        if (self.paused_at != null) return;
        if (self.film_index != 0) {
            self.film_index = self.film_count - 1;
        }
        self.replay.finished = true;
    }

    pub fn draw(self: *const Ending, indices: []u8, rgba: []u8) !void {
        switch (self.stage) {
            .films => {
                @memcpy(indices, &self.image);
                try palette.writeRgba(indices, &self.image_colors, rgba);
            },
            .score_film => try self.player.?.draw(indices, rgba),
            .score => {
                @memcpy(indices, &self.picture);
                var line: [64]u8 = undefined;
                const score = self.score orelse 0;
                const text = try std.fmt.bufPrint(&line, "{s}{d:0>8}", .{
                    std.mem.sliceTo(&self.score_label, 0),
                    score % 100_000_000,
                });
                try self.write(indices, text, 40, 0xe5);
                var code_line: [16]u8 = undefined;
                const code = try std.fmt.bufPrint(&code_line, "CODE: {s}", .{
                    std.mem.sliceTo(&self.code, 0),
                });
                try self.write(indices, code, 16, 0xe7);
                var colors = self.colors;
                @memcpy(colors[0xe0..0xf0], &self.text_colors);
                try palette.writeRgba(indices, &colors, rgba);
            },
        }
    }

    fn write(self: *const Ending, indices: []u8, text: []const u8, y: i32, ink: u8) !void {
        const x = 128 - 4 * @as(i32, @intCast(text.len));
        try text_renderer.draw(indices, width, height, &self.font, text, x, y, .{
            .foreground = ink,
            .shadow = 0xe2,
            .palette_bank = 14,
        });
    }

    /// Where the ending is: its stage, film, picture and credits.
    pub fn stateHash(self: *const Ending) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&.{ @backingInt(self.stage), @intFromBool(self.finished) });
        const film_frame: u64 = if (self.player) |player|
            player.playback.frame
        else
            std.math.maxInt(u64);
        for ([_]u64{ self.film_index, film_frame, self.credits.step, self.credits.typed }) |value| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        }
        return hash.final();
    }

    pub fn needsCatchup(self: *const Ending, now_ns: u64) bool {
        return switch (self.stage) {
            .films => self.due(now_ns),
            .score_film => if (self.player) |*player| player.needsCatchup(now_ns) else false,
            .score => false,
        };
    }

    /// The music, from the first film to the end of the list, with the MUSIC option.
    pub fn sound(self: *Ending) ?*soundtrack.Soundtrack {
        if (self.stage != .films or !self.music_enabled) return null;
        return if (self.music) |*music| music else null;
    }
};

/// The credits typed over the ending list: one step of the stream at each present, unless a
/// hold runs, drawn from the film origin (8, 50) in ink 0xef. Holds count timer ticks.
pub const Credits = struct {
    steps: []const data_set.Credit,
    step: usize = 0,
    /// Characters of the current text step already typed.
    typed: usize = 0,
    line: [256]u8 = undefined,
    line_length: usize = 0,
    column: u8 = 0,
    row: u8 = 0,
    hold_ticks: u32 = 0,
    /// The film holds its picture: after a page or a hold, and during a wait.
    picture_held: bool = false,
    waiting: bool = false,
    /// A block ended while the picture was held: typing resumes once it is not.
    paused: bool = false,

    pub const Present = enum { picture, page, hold, held };

    /// One present of the films, `elapsed` timer ticks after the previous one;
    /// `new_background` when the film started a new background since. Returns whether the
    /// line is drawn over the picture.
    pub fn present(self: *Credits, elapsed: u32, kind: Present, new_background: bool) bool {
        self.hold_ticks -|= elapsed;
        if (kind != .held and self.waiting) {
            self.waiting = false;
            self.picture_held = false;
        }
        if (new_background) {
            self.picture_held = false;
        }
        switch (kind) {
            .picture => {
                defer self.picture_held = false;
                return self.typeStep();
            },
            .page => {
                self.picture_held = true;
                return false;
            },
            // While no text is shown, holding the picture holds the credits too.
            .hold => {
                self.picture_held = true;
                if (self.line_length == 0) {
                    self.hold_ticks += 1;
                }
                return self.typeStep();
            },
            .held => {
                self.picture_held = true;
                self.waiting = true;
                if (self.line_length == 0) {
                    self.hold_ticks = 20;
                }
                return self.typeStep();
            },
        }
    }

    fn typeStep(self: *Credits) bool {
        if (self.paused) {
            if (self.picture_held) return false;
            self.paused = false;
        }
        if (self.hold_ticks == 0) {
            self.next();
        }
        return true;
    }

    fn next(self: *Credits) void {
        if (self.step >= self.steps.len) {
            self.line_length = 0;
            return;
        }
        switch (self.steps[self.step]) {
            .text => |text| {
                if (self.line_length < self.line.len) {
                    self.line[self.line_length] = text[self.typed];
                    self.line_length += 1;
                }
                self.typed += 1;
                if (self.typed < text.len) return;
                self.typed = 0;
            },
            .hold => |ticks| self.hold_ticks = ticks,
            .at => |at| {
                self.column = at.column;
                self.row = at.row;
            },
            .block_end => {
                self.line_length = 0;
                if (self.picture_held) {
                    self.paused = true;
                }
            },
        }
        self.step += 1;
    }

    pub fn draw(self: *const Credits, indices: []u8, font: *const font_mod.Font) !void {
        var y: i32 = 50 + 8 * @as(i32, self.row);
        var lines = std.mem.splitScalar(u8, self.line[0..self.line_length], '|');
        while (lines.next()) |text| : (y += 8) {
            const x = 8 + 8 * (@as(i32, self.column) - 1);
            try text_renderer.draw(indices, width, height, font, text, x, y, .{
                .foreground = 0xef,
                .shadow = 0xe2,
                .palette_bank = 14,
            });
        }
    }
};

/// The presents of one film, in order. In normal mode each picture presents once, for its
/// hold ticks. In replay mode each picture presents for its `present_ticks`, then again
/// `held_presents` times, every 2 ticks.
pub const Replay = struct {
    /// Normal mode: each picture presented once, held for its waits.
    normal: bool = false,
    frame: usize = 0,
    /// Presents already made of the current picture: its own, then the held ones.
    made: u32 = 0,
    finished: bool = false,

    pub const Present = struct {
        frame: usize,
        kind: Credits.Present,
        /// Timer ticks until the next present.
        period: u32,
        new_background: bool = false,
    };

    pub fn next(self: *Replay, frames: []const film_mod.Frame) ?Present {
        while (!self.finished and self.frame < frames.len) {
            const frame = frames[self.frame];
            if (self.made == 0) {
                self.made = 1;
                if (frame.presented) {
                    return .{
                        .frame = self.frame,
                        .kind = switch (frame.replay_present) {
                            .picture => .picture,
                            .page => .page,
                            .hold => .hold,
                        },
                        .period = if (self.normal) frame.hold_ticks else frame.present_ticks,
                        .new_background = frame.ends_hold,
                    };
                }
            }
            if (!self.normal and self.made <= frame.held_presents) {
                self.made += 1;
                return .{ .frame = self.frame, .kind = .held, .period = 2 };
            }
            self.frame += 1;
            self.made = 0;
        }
        return null;
    }
};
