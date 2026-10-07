//! Floppy startup presentation, title menu and game-entry transitions.
//! Scene transitions own their resources; inputs are never forwarded into a new scene.
const std = @import("std");
const platform = @import("../platform.zig");
const menu_art = @import("../content/menu_artwork.zig");
const palette = @import("../content/palette.zig");
const text = @import("../render/text.zig");
const menu_mod = @import("menu.zig");
const soundtrack = @import("../audio/soundtrack.zig");
const vector_player = @import("vector_player.zig");
pub const Difficulty = @import("../settings.zig").Difficulty;
pub const Stage = enum { branding, introduction, awakening, game_over, menu, ready, demo_ready, quit };
pub const View = enum { main, skill, info, password, unavailable };

pub const Scene = struct {
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    assets: menu_art.Assets,
    page_assets: ?menu_art.Assets = null,
    menu: menu_mod.Menu = .{},
    player: ?vector_player.Player = null,
    music: ?soundtrack.Soundtrack = null,
    music_cue: ?enum { branding, introduction, awakening, game_over, menu } = null,
    music_rate: ?u32 = null,
    music_enabled: bool = true,
    volume: u8 = 100,
    introduction_part: enum { first, second } = .first,
    skip_requested: bool = false,
    stage: Stage = .menu,
    view: View = .main,
    difficulty: Difficulty = .normal,
    selected_level: @import("../content/level.zig").Id = .jungle,
    pending_difficulty: Difficulty = .normal,
    activation_key: ?platform.Key = null,
    password: [6]u8 = @splat(0),
    password_length: usize = 0,
    notice: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source: platform.AssetSource, assets: menu_art.Assets) Scene {
        return .{ .allocator = allocator, .source = source, .assets = assets };
    }

    pub fn intro(self: *Scene) !void {
        for ([_][]const u8{ "DATA/INTRO1.CMD", "DATA/INTRO1.POL", "DATA/INTRO2.CMD", "DATA/INTRO2.POL" }) |path| {
            const asset = try self.source.open(path);
            self.source.close(asset.handle);
        }
        try self.play("LOGOS");
        self.stage = .branding;
    }

    fn play(self: *Scene, name: []const u8) !void {
        const next = try vector_player.Player.open(self.allocator, self.source, name, 0);
        if (self.player) |*previous| previous.deinit();
        self.player = next;
        self.skip_requested = false;
        self.activation_key = null;
    }

    pub fn deinit(self: *Scene) void {
        if (self.player) |*player| player.deinit();
        if (self.page_assets) |*assets| assets.deinit();
        if (self.music) |*music| music.deinit();
        self.assets.deinit();
        self.* = undefined;
    }

    pub fn stopAudio(self: *Scene, p: *platform.Platform) void {
        if (self.music_rate != null) {
            p.audioClear();
            p.audioClose();
            self.music_rate = null;
        }
    }

    fn updateMusic(self: *Scene, p: *platform.Platform) !void {
        if (!self.music_enabled) {
            self.stopAudio(p);
            return;
        }
        const cue: @TypeOf(self.music_cue) = switch (self.stage) {
            .branding => .branding,
            .introduction => .introduction,
            .awakening => .awakening,
            .game_over => .game_over,
            .menu => .menu,
            else => {
                self.stopAudio(p);
                return;
            },
        };
        if (self.music_rate == null) {
            const format = try p.audioOpen(.{ .channels = 2, .sample_rate = 44100 });
            if (format.channels != 2) {
                p.audioClose();
                return error.UnsupportedAudioFormat;
            }
            self.music_rate = format.sample_rate;
        }
        if (cue != self.music_cue) {
            const name: []const u8 = switch (cue.?) {
                .branding => "PRESENT3",
                .introduction => "INTROL3",
                .awakening => "REVEIL3",
                .game_over => "GAMEOVE3",
                .menu => "OPTION3",
            };
            const replacement = try soundtrack.Soundtrack.open(self.allocator, self.source, name, self.music_rate.?);
            p.audioClear();
            if (self.music) |*previous| previous.deinit();
            self.music = replacement;
            self.music_cue = cue;
        }
        if (self.music) |*music| {
            music.volume = self.volume;
            try music.pump(p);
        }
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&.{ @backingInt(self.stage), @backingInt(self.view), @backingInt(self.menu.selected), @backingInt(self.difficulty), @backingInt(self.pending_difficulty), @backingInt(self.selected_level) });
        hash.update(self.password[0..self.password_length]);
        hash.update(&.{@backingInt(self.introduction_part)});
        if (self.player) |player| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, player.playback.frame)));
        return hash.final();
    }

    pub fn resolution(_: *const Scene) platform.Size {
        return .{ .width = 256, .height = 224 };
    }

    pub fn update(self: *Scene, p: *platform.Platform) !void {
        if (self.player) |*player| {
            const skipped = self.skip_requested;
            if (skipped or try player.update(p.nowNs())) {
                if (self.stage == .game_over) {
                    player.deinit();
                    self.player = null;
                    self.skip_requested = false;
                    self.stage = .menu;
                } else if (self.stage == .awakening) {
                    player.deinit();
                    self.player = null;
                    self.stage = .ready;
                } else if (self.stage == .branding) {
                    try self.play("INTRO1");
                    self.introduction_part = .first;
                    self.stage = .introduction;
                } else if (!skipped and self.introduction_part == .first) {
                    try self.play("INTRO2");
                    self.introduction_part = .second;
                } else {
                    player.deinit();
                    self.player = null;
                    self.skip_requested = false;
                    self.stage = .menu;
                }
            }
        }
        try self.updateMusic(p);
    }
    pub fn needsCatchup(self: *const Scene, now: u64) bool {
        return if (self.player) |*player| player.needsCatchup(now) else false;
    }

    fn show(self: *Scene, view: View, picture: []const u8) !void {
        const replacement = try menu_art.loadNamed(self.allocator, self.source, picture);
        if (self.page_assets) |*assets| assets.deinit();
        self.page_assets = replacement;
        self.view = view;
    }

    fn mainMenu(self: *Scene) void {
        if (self.page_assets) |*assets| assets.deinit();
        self.page_assets = null;
        self.view = .main;
        self.menu.selected = .start;
    }

    pub fn start(self: *Scene, key: ?platform.Key) !void {
        try self.startLevel(.jungle, key);
    }

    pub fn startLevel(self: *Scene, level: @import("../content/level.zig").Id, key: ?platform.Key) !void {
        self.selected_level = level;
        if (level == .jungle) {
            try self.play("DEBUT");
            self.stage = .awakening;
        } else self.stage = .ready;
        self.activation_key = key;
    }

    pub fn gameOver(self: *Scene, key: ?platform.Key) !void {
        try self.play("OVER");
        self.activation_key = key;
        self.stage = .game_over;
    }

    pub fn event(self: *Scene, input: platform.Event) !void {
        if (input.payload == .quit) {
            self.stage = .quit;
            return;
        }
        if (input.payload == .focus_lost) self.activation_key = null;
        if (input.payload == .key_up) {
            if (self.activation_key == input.payload.key_up.key) self.activation_key = null;
            return;
        }
        if (input.payload != .key_down) return;
        const press = input.payload.key_down;
        const key = press.key;
        const confirm = key == .enter or key == .space or key == .left_shift or key == .right_shift;
        if (self.player != null) {
            if (!press.repeat and (key == .tab or key == .escape or confirm)) self.skip_requested = true;
            return;
        }
        if (self.stage != .menu) return;
        switch (self.view) {
            .main => {
                const index: usize = @backingInt(self.menu.selected);
                if (key == .up) self.menu.selected = @fromBackingInt(@as(u3, @intCast((index + menu_mod.action_count - 1) % menu_mod.action_count)));
                if (key == .down) self.menu.selected = @fromBackingInt(@as(u3, @intCast((index + 1) % menu_mod.action_count)));
                if (key == .escape) self.stage = .quit;
                if (confirm and !press.repeat) switch (self.menu.selected) {
                    .start => try self.start(key),
                    .skill => {
                        self.pending_difficulty = self.difficulty;
                        try self.show(.skill, "MENU3");
                    },
                    .info => try self.show(.info, "INSTRU_E"),
                    .password => {
                        self.password_length = 0;
                        try self.show(.password, "MENU2");
                    },
                    .demo => self.stage = .demo_ready,
                    .quit => self.stage = .quit,
                };
            },
            .skill => {
                const selected: u2 = @backingInt(self.pending_difficulty);
                if (key == .up and selected != 0) self.pending_difficulty = @fromBackingInt(selected - 1);
                if (key == .down and selected != 2) self.pending_difficulty = @fromBackingInt(selected + 1);
                if (confirm and !press.repeat) {
                    self.difficulty = self.pending_difficulty;
                    self.mainMenu();
                }
                if (key == .escape) self.mainMenu();
            },
            .info, .unavailable => if (confirm or key == .escape or key == .tab) self.mainMenu(),
            .password => {
                if (key == .backspace) {
                    self.password_length -|= 1;
                    return;
                }
                if (key == .enter) {
                    try self.submitPassword(key);
                    return;
                }
                const code = @backingInt(key);
                const character: ?u8 = if (code >= @backingInt(platform.Key.a) and code <= @backingInt(platform.Key.z)) @intCast('A' + code - @backingInt(platform.Key.a)) else if (key == .space) ' ' else null;
                if (character) |value| if (self.password_length < self.password.len) {
                    self.password[self.password_length] = value;
                    self.password_length += 1;
                };
            },
        }
    }

    fn submitPassword(self: *Scene, key: platform.Key) !void {
        const destination = try @import("../content/level_codes.zig").lookup(self.allocator, self.source, self.password[0..self.password_length]);
        self.mainMenu();
        if (destination) |entry| {
            self.difficulty = entry.difficulty;
            try self.startLevel(entry.level, key);
        }
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        if (self.player) |*player| return player.draw(indices, rgba);
        if (self.view == .main) return self.menu.draw(self.assets.artwork(), .{}, indices, rgba);
        const assets = &(self.page_assets orelse return error.MissingMenuPage);
        @memcpy(indices, assets.background.pixels);
        switch (self.view) {
            .skill => {
                try text.draw(indices, 256, 224, &assets.font, "SKILL LEVEL :", 32, 96, .{ .foreground = 2, .shadow = 0 });
                for ([_][]const u8{ "EASY", "NORMAL", "EXPERT" }, 0..) |label, i| try text.draw(indices, 256, 224, &assets.font, label, 112, 120 + @as(i32, @intCast(i)) * 16, .{ .foreground = if (i == @backingInt(self.pending_difficulty)) 1 else 2, .shadow = 0 });
            },
            .password => {
                try text.draw(indices, 256, 224, &assets.font, "Enter password for desired", 24, 120, .{ .foreground = 2, .shadow = 0 });
                try text.draw(indices, 256, 224, &assets.font, "level :", 24, 136, .{ .foreground = 2, .shadow = 0 });
                try text.draw(indices, 256, 224, &assets.font, self.password[0..self.password_length], 120, 168, .{ .foreground = 2, .shadow = 0 });
            },
            .unavailable => {
                const x = @divTrunc(256 - @as(i32, @intCast(self.notice.len)) * 8, 2);
                try text.draw(indices, 256, 224, &assets.font, self.notice, x, 120, .{ .foreground = 2, .shadow = 0 });
                try text.draw(indices, 256, 224, &assets.font, "PRESS ENTER TO RETURN", 44, 152, .{ .foreground = 2, .shadow = 0 });
            },
            .info => {},
            .main => unreachable,
        }
        try palette.writeRgba(indices, &assets.colors, rgba);
    }
};
