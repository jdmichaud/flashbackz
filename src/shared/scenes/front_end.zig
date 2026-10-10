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
pub const Difficulty = settings.Difficulty;
const content_level = @import("../content/level.zig");
const level_codes = @import("../content/level_codes.zig");
const settings = @import("../settings.zig");
const key_latch = @import("../key_latch.zig");
const input_mod = @import("../input.zig");
const save = @import("../save.zig");
const save_slots = @import("save_slots.zig");
pub const Stage = enum {
    branding,
    introduction,
    game_over,
    menu,
    ready,
    demo_ready,
    /// The eighth level code was entered: the ending plays.
    ending_ready,
    quit,
};
pub const View = enum { main, skill, info, password, load, unavailable };
const MusicCue = enum { branding, introduction, game_over, menu };

/// The original's main menu chooses Demo once its timer has counted past 2,400 since the page
/// opened or the last Up or Down: 34.38 s, measured (flashback-re docs/title-menu.md).
const idle_demo_ns: u64 = 34_380 * std.time.ns_per_ms;

pub const Scene = struct {
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    assets: menu_art.Assets,
    page_assets: ?menu_art.Assets = null,
    menu: menu_mod.Menu = .{},
    player: ?vector_player.Player = null,
    music: ?soundtrack.Soundtrack = null,
    music_cue: ?MusicCue = null,
    music_enabled: bool = true,
    introduction_part: enum { first, second } = .first,
    skip_requested: bool = false,
    /// The joystick option: the joystick's inventory button skips films too.
    joystick: bool = false,
    /// P's toggle: films hold their picture while it is set.
    films_paused: bool = false,
    /// The music volume keypad + and - step, 0 to 63.
    music_volume: u8 = 48,
    stage: Stage = .menu,
    view: View = .main,
    difficulty: Difficulty = .normal,
    selected_level: content_level.Id = .jungle,
    pending_difficulty: Difficulty = .normal,
    password: [6]u8 = @splat(0),
    password_length: usize = 0,
    /// The character a pad is choosing after the typed ones (PLAN GS-3).
    pad_character: ?u8 = null,
    /// LOAD's slots page; the game reads the slots, sets `slots` and loads the chosen one.
    load_page: save_slots.Page = .{ .mode = .load },
    slots: []const save.Slot = &.{},
    /// The password's blinking cursor, an underscore after the typed characters, and when it
    /// next changes.
    cursor_shown: bool = true,
    cursor_due_ns: ?u64 = null,
    /// Since when the main page has seen no Up or Down: after `idle_demo_ns` it plays a demo.
    idle_since_ns: ?u64 = null,
    /// When a held direction may move the selection again.
    direction_repeat: key_latch.DirectionRepeat = .{},
    notice: []const u8 = "",

    pub fn init(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        assets: menu_art.Assets,
    ) Scene {
        return .{ .allocator = allocator, .source = source, .assets = assets };
    }

    pub fn intro(self: *Scene) !void {
        for ([_][]const u8{
            "DATA/INTRO1.CMD",
            "DATA/INTRO1.POL",
            "DATA/INTRO2.CMD",
            "DATA/INTRO2.POL",
        }) |path| {
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
    }

    pub fn deinit(self: *Scene) void {
        if (self.player) |*player| player.deinit();
        if (self.page_assets) |*assets| assets.deinit();
        if (self.music) |*music| music.deinit();
        self.assets.deinit();
        self.* = undefined;
    }

    /// The music of the stage shown: a cue changed starts its music from the beginning.
    fn updateMusic(self: *Scene) !void {
        if (!self.music_enabled) return;
        const wanted = self.cue() orelse return;
        if (wanted != self.music_cue) {
            const name: []const u8 = switch (wanted) {
                .branding => "PRESENT3",
                .introduction => "INTROL3",
                .game_over => "GAMEOVE3",
                .menu => "OPTION3",
            };
            const replacement = try soundtrack.Soundtrack.open(self.allocator, self.source, name);
            if (self.music) |*previous| previous.deinit();
            self.music = replacement;
            self.music_cue = wanted;
        }
        if (self.music) |*music| music.player.master_volume = self.music_volume;
    }

    fn cue(self: *const Scene) ?MusicCue {
        return switch (self.stage) {
            .branding => .branding,
            .introduction => .introduction,
            .game_over => .game_over,
            .menu => .menu,
            else => null,
        };
    }

    /// The stage's music, with the MUSIC option.
    pub fn sound(self: *Scene) ?*soundtrack.Soundtrack {
        if (!self.music_enabled or self.cue() == null) return null;
        return if (self.music) |*music| music else null;
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&.{
            @backingInt(self.stage),
            @backingInt(self.view),
            @backingInt(self.menu.selected),
            @backingInt(self.difficulty),
            @backingInt(self.pending_difficulty),
            @backingInt(self.selected_level),
        });
        hash.update(self.password[0..self.password_length]);
        hash.update(&.{@backingInt(self.introduction_part)});
        if (self.player) |player| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, player.playback.frame)));
        return hash.final();
    }

    pub fn resolution(_: *const Scene) platform.Size {
        return .{ .width = 256, .height = 224 };
    }

    pub fn update(self: *Scene, p: *platform.Platform) !void {
        if (self.view == .password) self.blinkCursor(p.nowNs());
        if (self.stage == .menu and self.view == .main and self.player == null) {
            const now = p.nowNs();
            const since = self.idle_since_ns orelse now;
            self.idle_since_ns = since;
            if (now -| since >= idle_demo_ns) {
                self.idle_since_ns = null;
                self.stage = .demo_ready;
            }
        } else self.idle_since_ns = null;
        if (self.player) |*player| {
            player.setPaused(self.films_paused, p.nowNs());
            // A held film does not look at its keys.
            if (player.paused_at != null) self.skip_requested = false;
            const skipped = self.skip_requested;
            if (skipped or try player.update(p.nowNs())) {
                if (self.stage == .game_over) {
                    player.deinit();
                    self.player = null;
                    self.stage = .menu;
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
                    self.stage = .menu;
                }
            }
        }
        try self.updateMusic();
    }
    pub fn needsCatchup(self: *const Scene, now: u64) bool {
        return if (self.player) |*player| player.needsCatchup(now) else false;
    }

    /// The original's code entry counts passes of its keyboard loop: the cursor shows at once,
    /// then changes every 3,000 passes, 66 ms at the reference speed (measured, 4.6 film timer
    /// ticks). It blinks whatever is typed.
    fn blinkCursor(self: *Scene, now_ns: u64) void {
        const period = 66 * std.time.ns_per_ms;
        const due = self.cursor_due_ns orelse now_ns + period;
        if (now_ns >= due) {
            self.cursor_shown = !self.cursor_shown;
            self.cursor_due_ns = due + period;
        } else self.cursor_due_ns = due;
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

    pub fn start(self: *Scene) void {
        self.startLevel(.jungle);
    }

    /// The level loads at once: it opens with its own film, the jungle with DEBUT (the scene
    /// table's level openings), so the title plays none.
    pub fn startLevel(self: *Scene, level: content_level.Id) void {
        self.selected_level = level;
        self.stage = .ready;
    }

    pub fn gameOver(self: *Scene) !void {
        try self.play("OVER");
        self.stage = .game_over;
    }

    pub fn event(self: *Scene, input: platform.Event) !void {
        if (input.payload == .quit) {
            self.stage = .quit;
            return;
        }
        // Films read only their skip keys and P.
        if (self.player != null and vector_player.skips(input.payload, self.joystick)) self.skip_requested = true;
        if (input.payload != .key_down) return;
        const press = input.payload.key_down;
        const key = press.key;
        if (self.player != null) return;
        const confirm = key == .enter or key == .space or key == .left_shift or key == .right_shift;
        if (self.stage != .menu) return;
        const direction = if (input_mod.keyAction(key)) |action| action.isDirection() else false;
        if (self.view != .password and direction and
            !self.direction_repeat.accept(press.repeat, input.time_ns)) return;
        switch (self.view) {
            .main => {
                if (key == .up or key == .down) self.idle_since_ns = input.time_ns;
                const index: usize = @backingInt(self.menu.selected);
                if (key == .up) self.menu.selected = @fromBackingInt(@as(
                    u3,
                    @intCast((index + menu_mod.action_count - 1) % menu_mod.action_count),
                ));
                if (key == .down) self.menu.selected = @fromBackingInt(@as(
                    u3,
                    @intCast((index + 1) % menu_mod.action_count),
                ));
                // A held Escape that skipped the introduction does not quit as it repeats.
                if (key == .escape and !press.repeat) self.stage = .quit;
                if (confirm and !press.repeat) try self.choose();
            },
            .skill => {
                // Up and Down wrap around the three difficulties.
                const selected: u2 = @backingInt(self.pending_difficulty);
                if (key == .up) self.pending_difficulty = @fromBackingInt(if (selected == 0) 2 else selected - 1);
                if (key == .down) self.pending_difficulty = @fromBackingInt(if (selected == 2) 0 else selected + 1);
                if (confirm and !press.repeat) {
                    self.difficulty = self.pending_difficulty;
                    self.mainMenu();
                }
                if (key == .escape) self.mainMenu();
            },
            .info, .unavailable => if (confirm or key == .escape or key == .tab) self.mainMenu(),
            .load => if (input_mod.keyAction(key)) |action| {
                if (!press.repeat or action.isDirection()) self.pressLoad(action);
            },
            .password => {
                if (key == .backspace) {
                    if (self.pad_character != null) self.pad_character = null else self.password_length -|= 1;
                    return;
                }
                if (key == .enter) {
                    try self.submitPassword();
                    return;
                }
                // Any printable character the keyboard gives, letters in capitals.
                const code = @backingInt(key);
                const character: ?u8 = if (code >= @backingInt(platform.Key.a) and
                    code <= @backingInt(platform.Key.z))
                    @intCast('A' + code - @backingInt(platform.Key.a))
                else if (code >= @backingInt(platform.Key.digit_0) and code <= @backingInt(platform.Key.digit_9))
                    @intCast('0' + code - @backingInt(platform.Key.digit_0))
                else switch (key) {
                    .space => ' ',
                    .keypad_plus => '+',
                    .keypad_minus => '-',
                    else => null,
                };
                if (character) |value| {
                    self.pad_character = null;
                    self.addCharacter(value);
                }
            },
        }
    }

    /// The main page's selected item, chosen.
    fn choose(self: *Scene) !void {
        switch (self.menu.selected) {
            .start => self.start(),
            .skill => {
                self.pending_difficulty = self.difficulty;
                try self.show(.skill, "MENU3");
            },
            .info => try self.show(.info, "INSTRU_E"),
            .load => {
                self.load_page = .{ .mode = .load };
                try self.show(.load, "MENU2");
            },
            .password => {
                self.password_length = 0;
                self.pad_character = null;
                self.cursor_shown = true;
                self.cursor_due_ns = null;
                try self.show(.password, "MENU2");
            },
            .demo => self.stage = .demo_ready,
            .quit => self.stage = .quit,
        }
    }

    fn addCharacter(self: *Scene, character: u8) void {
        if (self.password_length == self.password.len) return;
        self.password[self.password_length] = character;
        self.password_length += 1;
    }

    /// A pad's press on the pages (PLAN GS-3c): the D-pad moves, A, B and X choose as Shift,
    /// Space and Return do, START goes back as Escape does, except on the main page, where it
    /// chooses rather than quits. Films take the pad's buttons as raw events.
    pub fn pad(self: *Scene, change: input_mod.Change, time_ns: u64) !void {
        if (!change.down or self.player != null or self.stage != .menu) return;
        if (change.action.isDirection()) {
            if (!self.direction_repeat.accept(change.repeat, time_ns)) return;
        } else if (change.repeat) return;
        const back = change.action == .pause;
        const choose_it = !back and !change.action.isDirection();
        switch (self.view) {
            .main => switch (change.action) {
                .up, .down => {
                    self.idle_since_ns = time_ns;
                    const index: usize = @backingInt(self.menu.selected);
                    const step: usize = if (change.action == .up) menu_mod.action_count - 1 else 1;
                    self.menu.selected = @fromBackingInt(@as(u3, @intCast((index + step) % menu_mod.action_count)));
                },
                else => if (choose_it or back) try self.choose(),
            },
            .skill => {
                const selected: u2 = @backingInt(self.pending_difficulty);
                if (change.action == .up) self.pending_difficulty = @fromBackingInt(if (selected == 0) 2 else selected - 1);
                if (change.action == .down) self.pending_difficulty = @fromBackingInt(if (selected == 2) 0 else selected + 1);
                if (choose_it) self.difficulty = self.pending_difficulty;
                if (choose_it or back) self.mainMenu();
            },
            .info, .unavailable => if (choose_it or back) self.mainMenu(),
            .load => self.pressLoad(change.action),
            .password => try self.padCode(change.action, choose_it, back),
        }
    }

    /// A press on LOAD's page, once the game has read the slots; going back returns to the main
    /// page.
    fn pressLoad(self: *Scene, action: input_mod.Action) void {
        if (self.slots.len == save_slots.row_count) self.load_page.press(action, self.slots);
        self.leaveLoad();
    }

    fn leaveLoad(self: *Scene) void {
        if (self.load_page.outcome) |outcome| if (outcome == .back) {
            self.load_page.outcome = null;
            self.mainMenu();
        };
    }

    /// The characters a pad goes through, in order.
    const pad_characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// The code with a pad: up and down change the character being chosen, right keeps it,
    /// left drops it or erases the last one, A, B or X enters the code, START erases (or goes
    /// back from an empty code).
    fn padCode(self: *Scene, action: input_mod.Action, enter: bool, back: bool) !void {
        switch (action) {
            .up, .down => {
                const at = if (self.pad_character) |c| std.mem.indexOfScalar(u8, pad_characters, c).? else if (action == .up) pad_characters.len - 1 else 0;
                const step: usize = if (action == .up) 1 else pad_characters.len - 1;
                self.pad_character = pad_characters[(at + step) % pad_characters.len];
            },
            .right => if (self.pad_character) |c| {
                self.addCharacter(c);
                self.pad_character = null;
            },
            .left => if (self.pad_character != null) {
                self.pad_character = null;
            } else {
                self.password_length -|= 1;
            },
            else => if (enter) {
                if (self.pad_character) |c| self.addCharacter(c);
                self.pad_character = null;
                try self.submitPassword();
            } else if (back) {
                if (self.pad_character != null) {
                    self.pad_character = null;
                } else if (self.password_length == 0) {
                    self.mainMenu();
                } else {
                    self.password_length -= 1;
                }
            },
        }
    }

    fn submitPassword(self: *Scene) !void {
        const destination = try level_codes.lookup(
            self.allocator,
            self.source,
            self.password[0..self.password_length],
        );
        self.mainMenu();
        if (destination) |entry| {
            self.difficulty = entry.difficulty;
            self.startLevel(entry.level);
        } else if (try level_codes.isEnding(
            self.allocator,
            self.source,
            self.password[0..self.password_length],
        )) {
            self.stage = .ending_ready;
        }
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        if (self.player) |*player| return player.draw(indices, rgba);
        if (self.view == .main) return self.menu.draw(self.assets.artwork(), .{}, indices, rgba);
        const assets = &(self.page_assets orelse return error.MissingMenuPage);
        if (self.view == .load) {
            // On black, in the page's colors.
            @memset(indices, 0);
            if (self.slots.len == save_slots.row_count) try self.load_page.draw(
                indices,
                &assets.font,
                self.slots,
                .{ .foreground = 2, .shadow = 0 },
                .{ .foreground = 1, .shadow = 0 },
            );
            return palette.writeRgba(indices, &assets.colors, rgba);
        }
        @memcpy(indices, assets.background.pixels);
        switch (self.view) {
            .skill => {
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    "SKILL LEVEL :",
                    32,
                    96,
                    .{ .foreground = 2, .shadow = 0 },
                );
                for ([_][]const u8{ "EASY", "NORMAL", "EXPERT" }, 0..) |label, i| try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    label,
                    112,
                    120 + @as(i32, @intCast(i)) * 16,
                    .{
                        .foreground = if (i == @backingInt(self.pending_difficulty)) 1 else 2,
                        .shadow = 0,
                    },
                );
            },
            .password => {
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    "Enter password for desired",
                    24,
                    120,
                    .{ .foreground = 2, .shadow = 0 },
                );
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    "level :",
                    24,
                    136,
                    .{ .foreground = 2, .shadow = 0 },
                );
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    self.password[0..self.password_length],
                    120,
                    168,
                    .{ .foreground = 2, .shadow = 0 },
                );
                // The character a pad is choosing, in the selected color, the cursor under it.
                if (self.pad_character) |c| try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    &.{c},
                    120 + 8 * @as(i32, @intCast(self.password_length)),
                    168,
                    .{ .foreground = 1, .shadow = 0 },
                );
                if (self.cursor_shown) try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    "_",
                    120 + 8 * @as(i32, @intCast(self.password_length)),
                    168,
                    .{ .foreground = 2, .shadow = 0 },
                );
            },
            .unavailable => {
                const x = @divTrunc(256 - @as(i32, @intCast(self.notice.len)) * 8, 2);
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    self.notice,
                    x,
                    120,
                    .{ .foreground = 2, .shadow = 0 },
                );
                try text.draw(
                    indices,
                    256,
                    224,
                    &assets.font,
                    "PRESS ENTER TO RETURN",
                    44,
                    152,
                    .{ .foreground = 2, .shadow = 0 },
                );
            },
            .info => {},
            .main, .load => unreachable,
        }
        try palette.writeRgba(indices, &assets.colors, rgba);
    }
};
