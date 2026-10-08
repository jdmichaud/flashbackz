//! The in-game options dialog owns a draft of settings while the world is paused.
const std = @import("std");
const platform = @import("../platform.zig");
const font = @import("../content/font.zig");
const text = @import("../render/text.zig");
pub const Zoom = enum { off, on, auto };
pub const Settings = struct {
    volume: u8 = 100,
    sound_fx: bool = true,
    music: bool = true,
    joystick: bool = false,
    zoom: Zoom = .off,
};
pub const Item = enum { resume_game, sound_fx, music, volume, joystick, zoom, abort_game };
pub const Outcome = enum { resume_game, abort_game };
pub const Menu = struct {
    selection: Item = .resume_game,
    settings: Settings,
    outcome: ?Outcome = null,
    free_memory_mb: ?u64 = null,
    pub fn key(self: *Menu, key_code: platform.Key) void {
        switch (key_code) {
            .up => self.selection = @fromBackingInt(@as(
                u3,
                @intCast((@as(u8, @backingInt(self.selection)) + 6) % 7),
            )),
            .down => self.selection = @fromBackingInt(@as(
                u3,
                @intCast((@as(u8, @backingInt(self.selection)) + 1) % 7),
            )),
            .left, .right => switch (self.selection) {
                .sound_fx => self.settings.sound_fx = !self.settings.sound_fx,
                .music => self.settings.music = !self.settings.music,
                .volume => self.settings.volume = if (key_code == .right) @min(
                    100,
                    self.settings.volume + 10,
                ) else self.settings.volume -| 10,
                .joystick => self.settings.joystick = !self.settings.joystick,
                .zoom => self.settings.zoom = @fromBackingInt(@as(
                    u2,
                    @intCast((@as(u8, @backingInt(self.settings.zoom)) + @as(
                        u8,
                        if (key_code == .right) 1 else 2,
                    )) % 3),
                )),
                else => {},
            },
            .escape, .enter, .space, .left_shift, .right_shift => self.outcome = if (self.selection == .abort_game) .abort_game else .resume_game,
            else => {},
        }
    }
    pub fn draw(self: Menu, pixels: []u8, glyphs: *const font.Font) !void {
        if (pixels.len != 256 * 224) return error.InvalidFrameLength;
        // The original panel uses nine ordinary font glyphs for its rounded frame.
        for (40..192) |y| @memset(pixels[y * 256 + 56 .. y * 256 + 200], 0xe2);
        for (48..184) |y| @memset(pixels[y * 256 + 48 .. y * 256 + 208], 0xe2);
        const border: text.Style = .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 };
        for (0..20) |column| {
            const top: u8 = if (column == 0) 129 else if (column == 19) 130 else 133;
            const bottom: u8 = if (column == 0) 131 else if (column == 19) 132 else 136;
            try text.draw(
                pixels,
                256,
                224,
                glyphs,
                &.{top},
                48 + @as(i32, @intCast(column)) * 8,
                40,
                border,
            );
            try text.draw(
                pixels,
                256,
                224,
                glyphs,
                &.{bottom},
                48 + @as(i32, @intCast(column)) * 8,
                184,
                border,
            );
        }
        for (1..18) |row| {
            const y = 40 + @as(i32, @intCast(row)) * 8;
            try text.draw(pixels, 256, 224, glyphs, &.{134}, 48, y, border);
            try text.draw(pixels, 256, 224, glyphs, &.{135}, 200, y, border);
        }
        const labels = [_][]const u8{
            "RESUME GAME",
            "SOUND FX",
            "MUSIC",
            "VOLUME",
            "JOYSTICK",
            "ZOOM",
            "ABORT GAME",
        };
        for (labels, 0..) |label, i| {
            const y = 56 + @as(i32, @intCast(i)) * 16;
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
                .sound_fx => if (self.settings.sound_fx) "ON  " else "OFF ",
                .music => if (self.settings.music) "ON  " else "OFF ",
                .volume => try std.fmt.bufPrint(&volume_text, "{d}%", .{self.settings.volume}),
                .joystick => if (self.settings.joystick) "ON  " else "OFF ",
                .zoom => switch (self.settings.zoom) {
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
            176,
            .{ .foreground = 0xee, .shadow = 0xe2, .palette_bank = 14 },
        );
    }
};

test "options wrap, cycle with horizontal arrows, and apply on Escape or action" {
    var menu: Menu = .{ .settings = .{} };
    menu.key(.up);
    try std.testing.expectEqual(.abort_game, menu.selection);
    menu.key(.down);
    menu.key(.down);
    menu.key(.right);
    try std.testing.expect(!menu.settings.sound_fx);
    menu.key(.escape);
    try std.testing.expectEqual(@as(?Outcome, .resume_game), menu.outcome);
    var abort: Menu = .{ .settings = .{} };
    abort.key(.up);
    abort.key(.enter);
    try std.testing.expectEqual(@as(?Outcome, .abort_game), abort.outcome);
}
