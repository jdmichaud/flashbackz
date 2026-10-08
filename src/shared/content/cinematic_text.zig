//! Cinematic strings and font, resolved to ordinary positioned text during import.
const std = @import("std");
const platform = @import("../platform.zig");
const font_mod = @import("font.zig");
const palette = @import("palette.zig");
const interface = @import("floppy_interface.zig");
const film = @import("../vector_film.zig");

pub const Text = struct {
    strings: []const []const u8,
    font: font_mod.Font,
    colors: palette.Bank,

    pub fn layout(
        self: Text,
        allocator: std.mem.Allocator,
        id: u16,
        x: i16,
        y: i16,
        foreground: u8,
        caption: bool,
    ) ![]const film.TextRun {
        if (id >= self.strings.len) return error.InvalidCinematicText;
        const value = self.strings[id];
        var lines = std.mem.splitScalar(u8, value, '|');
        var widest: usize = if (caption) 30 else 0;
        var count: usize = 0;
        while (lines.next()) |line| {
            widest = @max(widest, line.len);
            count += 1;
        }
        if (count > 28 or widest > 255) return error.CinematicTextTooLarge;
        const result = try allocator.alloc(film.TextRun, count);
        lines.reset();
        for (result, 0..) |*run, row| {
            const line = lines.next().?;
            // Original centering rounds to an eight-pixel character boundary.
            const padding = ((widest - line.len) & ~@as(usize, 1)) * 4;
            run.* = .{
                .text = line,
                .x = @intCast(@as(i32, x) + @as(i32, @intCast(padding))),
                .y = @intCast(@as(i32, y) + @as(i32, @intCast(row * 8))),
                .foreground = foreground,
            };
        }
        return result;
    }
};

fn parseStrings(
    allocator: std.mem.Allocator,
    offsets: []const u8,
    text: []const u8,
) ![]const []const u8 {
    if (offsets.len == 0 or
        offsets.len % 2 != 0 or
        offsets.len > 8192 or
        text.len > 65536) return error.InvalidCinematicStrings;
    const owned_text = try allocator.dupe(u8, text);
    errdefer allocator.free(owned_text);
    const result = try allocator.alloc([]const u8, offsets.len / 2);
    errdefer allocator.free(result);
    for (result, 0..) |*value, i| {
        const at = std.mem.readInt(u16, offsets[i * 2 ..][0..2], .big);
        if (at >= text.len) return error.InvalidCinematicTextOffset;
        const length = std.mem.indexOfScalar(
            u8,
            owned_text[at..],
            '\n',
        ) orelse return error.UnterminatedCinematicText;
        value.* = owned_text[at..][0..length];
    }
    return result;
}

/// The caller owns an arena for the film and all text, so strings/font need no separate lifetime.
pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Text {
    var offsets = try source.readAll("DATA/ENGCINE.BIN", 8192);
    defer offsets.deinit();
    var strings = try source.readAll("DATA/ENGCINE.TXT", 65536);
    defer strings.deinit();
    var font = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer font.deinit();
    const metadata = try interface.load(allocator, source);
    return .{
        .strings = try parseStrings(allocator, offsets.bytes, strings.bytes),
        .font = try font_mod.decode(allocator, font.bytes),
        .colors = metadata.text_colors,
    };
}

test "cinematic lines center independently and malformed offsets are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const strings = try parseStrings(allocator, &.{ 0, 0 }, "ABCD|AB\n");
    const text: Text = .{ .strings = strings, .font = undefined, .colors = undefined };
    const rows = try text.layout(allocator, 0, 16, 58, 0xd8, false);
    try std.testing.expectEqual(@as(i16, 16), rows[0].x);
    try std.testing.expectEqual(@as(i16, 24), rows[1].x);
    try std.testing.expectEqual(@as(i16, 66), rows[1].y);
    try std.testing.expectEqualStrings("AB", rows[1].text);
    try std.testing.expectError(
        error.InvalidCinematicTextOffset,
        parseStrings(allocator, &.{ 0, 10 }, "x\n"),
    );
    try std.testing.expectError(
        error.UnterminatedCinematicText,
        parseStrings(allocator, &.{ 0, 0 }, "x"),
    );
}
