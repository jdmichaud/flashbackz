//! The in-game options dialog, while the world is paused: it changes the game's settings as
//! they are chosen.
const std = @import("std");
const input = @import("../input.zig");
const font = @import("../content/font.zig");
const text = @import("../render/text.zig");
const Settings = @import("../settings.zig").Settings;
/// The rows; CONTROLS is ours (PLAN GS-3), the others the original's.
pub const Item = enum { resume_game, sound_fx, music, volume, joystick, zoom, controls, abort_game };
const item_count = @typeInfo(Item).@"enum".field_names.len;
pub const Outcome = enum { resume_game, abort_game };
/// The dialog's page: its rows, or the CONTROLS page that lists each action's key and button.
pub const Page = enum { rows, controls };
pub const Menu = struct {
    selection: Item = .resume_game,
    page: Page = .rows,
    outcome: ?Outcome = null,
    free_memory_mb: ?u64 = null,
    /// A press of `action`: up and down choose the row, left and right change it, and a button
    /// or Escape closes the dialog, abandoning the game on ABORT GAME.
    pub fn press(self: *Menu, action: input.Action, settings: *Settings) void {
        if (self.page == .controls) {
            // Any button leaves the CONTROLS page.
            if (!action.isDirection()) self.page = .rows;
            return;
        }
        switch (action) {
            .up => self.selection = @fromBackingInt(@as(
                u3,
                @intCast((@as(u8, @backingInt(self.selection)) + item_count - 1) % item_count),
            )),
            .down => self.selection = @fromBackingInt(@as(
                u3,
                @intCast((@as(u8, @backingInt(self.selection)) + 1) % item_count),
            )),
            .left, .right => switch (self.selection) {
                .sound_fx => settings.sound_fx = !settings.sound_fx,
                .music => settings.music = !settings.music,
                .volume => settings.volume = if (action == .right) @min(100, settings.volume + 10) else settings.volume -| 10,
                .joystick => settings.joystick = !settings.joystick,
                .zoom => settings.zoom = @fromBackingInt(@as(
                    u2,
                    @intCast((@as(u8, @backingInt(settings.zoom)) + @as(u8, if (action == .right) 1 else 2)) % 3),
                )),
                else => {},
            },
            .pause, .use, .gun, .act => switch (self.selection) {
                .controls => self.page = .controls,
                .abort_game => self.outcome = .abort_game,
                else => self.outcome = .resume_game,
            },
            .inventory => {},
        }
    }

    /// A pad's B or START: back from the CONTROLS page, or play resumes, never abandoned
    /// (PLAN GS-3).
    pub fn back(self: *Menu) void {
        if (self.page == .controls) self.page = .rows else self.outcome = .resume_game;
    }
    pub fn draw(self: Menu, pixels: []u8, glyphs: *const font.Font, settings: Settings) !void {
        if (pixels.len != 256 * 224) return error.InvalidFrameLength;
        const style: text.Style = .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 };
        if (self.page == .controls) {
            try drawPanel(pixels, glyphs, controls_panel);
            return drawControls(pixels, glyphs, style);
        }
        try drawPanel(pixels, glyphs, rows_panel);
        const labels = [_][]const u8{
            "RESUME GAME",
            "SOUND FX",
            "MUSIC",
            "VOLUME",
            "JOYSTICK",
            "ZOOM",
            "CONTROLS",
            "ABORT GAME",
        };
        for (labels, 0..) |label, i| {
            const y = rows_panel.top + 16 + @as(i32, @intCast(i)) * 16;
            try text.draw(
                pixels,
                256,
                224,
                glyphs,
                label,
                64,
                y,
                .{
                    .foreground = if (i == @backingInt(self.selection)) 0xe4 else 0xe5,
                    .shadow = 0xe2,
                    .palette_bank = 14,
                },
            );
            var volume_text: [4]u8 = undefined;
            const value: ?[]const u8 = switch (@as(Item, @fromBackingInt(@as(u3, @intCast(i))))) {
                .sound_fx => if (settings.sound_fx) "ON  " else "OFF ",
                .music => if (settings.music) "ON  " else "OFF ",
                .volume => try std.fmt.bufPrint(&volume_text, "{d}%", .{settings.volume}),
                .joystick => if (settings.joystick) "ON  " else "OFF ",
                .zoom => switch (settings.zoom) {
                    .off => "OFF ",
                    .on => "ON  ",
                    .auto => "AUTO",
                },
                else => null,
            };
            if (value) |label_value| try text.draw(
                pixels,
                256,
                224,
                glyphs,
                label_value,
                160,
                y,
                .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 },
            );
        }
        var memory_text: [48]u8 = undefined;
        const memory_label = if (self.free_memory_mb) |amount| try std.fmt.bufPrint(
            &memory_text,
            "FREE MEM {d} MB",
            .{amount},
        ) else "FREE MEM : N/A";
        try text.draw(
            pixels,
            256,
            224,
            glyphs,
            memory_label,
            @divTrunc(256 - @as(i32, @intCast(memory_label.len)) * 8, 2),
            rows_panel.bottom - 8,
            .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 },
        );
    }
};

/// A panel: its frame's glyphs from `left` to `right` and from `top` to `bottom`, each a glyph's
/// top-left corner, on a filled background with rounded corners.
const Panel = struct { left: i32, right: i32, top: i32, bottom: i32 };

/// The original's panel, 8 pixels higher and a row longer for CONTROLS.
const rows_panel: Panel = .{ .left = 48, .right = 200, .top = 32, .bottom = 192 };
/// A wider one for the CONTROLS page's three columns.
const controls_panel: Panel = .{ .left = 16, .right = 232, .top = 48, .bottom = 176 };

/// The original panel uses nine ordinary font glyphs for its rounded frame.
fn drawPanel(pixels: []u8, glyphs: *const font.Font, panel: Panel) !void {
    const border: text.Style = .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 };
    for (@intCast(panel.top)..@intCast(panel.bottom + 8)) |y| {
        @memset(pixels[y * 256 + @as(usize, @intCast(panel.left + 8)) .. y * 256 + @as(usize, @intCast(panel.right))], 0xe2);
    }
    for (@intCast(panel.top + 8)..@intCast(panel.bottom)) |y| {
        @memset(pixels[y * 256 + @as(usize, @intCast(panel.left)) .. y * 256 + @as(usize, @intCast(panel.right + 8))], 0xe2);
    }
    var x = panel.left;
    while (x <= panel.right) : (x += 8) {
        const first = x == panel.left;
        const last = x == panel.right;
        const top: u8 = if (first) 129 else if (last) 130 else 133;
        const bottom: u8 = if (first) 131 else if (last) 132 else 136;
        try text.draw(pixels, 256, 224, glyphs, &.{top}, x, panel.top, border);
        try text.draw(pixels, 256, 224, glyphs, &.{bottom}, x, panel.bottom, border);
    }
    var y = panel.top + 8;
    while (y < panel.bottom) : (y += 8) {
        try text.draw(pixels, 256, 224, glyphs, &.{134}, panel.left, y, border);
        try text.draw(pixels, 256, 224, glyphs, &.{135}, panel.right, y, border);
    }
}

/// Each action's key and pad button, in the panel's three columns.
const controls = [_][3][]const u8{
    .{ "", "KEYS", "PAD" },
    .{ "MOVE", "ARROWS", "D-PAD" },
    .{ "ACTION", "SHIFT", "A" },
    .{ "GUN", "SPACE", "B" },
    .{ "USE", "ENTER", "X" },
    .{ "ITEMS", "TAB", "Y" },
    .{ "PAUSE", "ESC", "START" },
};

fn drawControls(pixels: []u8, glyphs: *const font.Font, style: text.Style) !void {
    for (controls, 0..) |row, i| {
        const y = controls_panel.top + 16 + @as(i32, @intCast(i)) * 16;
        for (row, [_]i32{ 32, 104, 168 }) |label, x| {
            try text.draw(pixels, 256, 224, glyphs, label, x, y, style);
        }
    }
}

test "options wrap, cycle with horizontal arrows, and apply on Escape or action" {
    var settings: Settings = .{};
    var menu: Menu = .{};
    menu.press(.up, &settings);
    try std.testing.expectEqual(.abort_game, menu.selection);
    menu.press(.down, &settings);
    menu.press(.down, &settings);
    menu.press(.right, &settings);
    try std.testing.expect(!settings.sound_fx);
    menu.press(.pause, &settings);
    try std.testing.expectEqual(@as(?Outcome, .resume_game), menu.outcome);
    var abort: Menu = .{};
    abort.press(.up, &settings);
    abort.press(.use, &settings);
    try std.testing.expectEqual(@as(?Outcome, .abort_game), abort.outcome);
    // A pad's B resumes, even on ABORT GAME.
    var pad: Menu = .{};
    pad.press(.up, &settings);
    pad.back();
    try std.testing.expectEqual(@as(?Outcome, .resume_game), pad.outcome);
}

test "CONTROLS opens its page, which any button or B leaves" {
    var settings: Settings = .{};
    var menu: Menu = .{};
    menu.press(.up, &settings);
    menu.press(.up, &settings);
    try std.testing.expectEqual(Item.controls, menu.selection);
    menu.press(.use, &settings);
    try std.testing.expectEqual(Page.controls, menu.page);
    menu.press(.down, &settings);
    try std.testing.expectEqual(Page.controls, menu.page);
    menu.press(.act, &settings);
    try std.testing.expectEqual(Page.rows, menu.page);
    menu.press(.use, &settings);
    menu.back();
    try std.testing.expectEqual(Page.rows, menu.page);
    try std.testing.expectEqual(@as(?Outcome, null), menu.outcome);
}
