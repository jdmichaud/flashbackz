//! Recover the static Continue illustration and labels into an owned indexed picture.
//! The cinematic command layout is consumed once at import; the UI contains no interpreter.
const std = @import("std");
const platform = @import("../platform.zig");
const palette = @import("palette.zig");
const font_mod = @import("font.zig");
const shapes = @import("../render/indexed_shapes.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    colors: palette.Palette,
    font: font_mod.Font,
    executable: platform.OwnedBytes,
    title: []const u8,
    time: []const u8,
    retry: []const u8,
    abort: []const u8,
    score: []const u8,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.pixels);
        self.font.deinit();
        self.executable.deinit();
        self.* = undefined;
    }
};
fn word(bytes: []const u8, at: usize) !u16 {
    if (at > bytes.len or bytes.len - at < 2) return error.TruncatedPicture;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}
fn label(bytes: []const u8, offset: usize) ![]const u8 {
    if (offset >= bytes.len) return error.InvalidLabel;
    const end = std.mem.indexOfScalar(u8, bytes[offset..@min(bytes.len, offset + 80)], 0) orelse return error.InvalidLabel;
    return bytes[offset..][0..end];
}
fn shape(pixels: []u8, pol: []const u8, index: u16, budget: *usize) !void {
    if (index & 0xf800 != 0) return error.UnsupportedPictureTransform;
    var at = @as(usize, try word(pol, 14)) + try word(pol, @as(usize, try word(pol, 2)) + @as(usize, index) * 2);
    const count = try word(pol, at);
    at += 2;
    if (count > 1024) return error.InvalidPictureShape;
    if (count > budget.*) return error.UnsupportedPictureComplexity;
    budget.* -= count;
    const canvas: shapes.Canvas = .{ .pixels = pixels, .width = 256, .height = 224, .clip = .{ .x = 8, .y = 50, .width = 240, .height = 128 } };
    for (0..count) |_| {
        const reference = try word(pol, at);
        at += 2;
        var dx: i16 = 8;
        var dy: i16 = 50;
        if (reference & 0x8000 != 0) {
            dx +%= @bitCast(try word(pol, at));
            dy +%= @bitCast(try word(pol, at + 2));
            at += 4;
        }
        if (at >= pol.len) return error.TruncatedPicture;
        const color = pol[at];
        at += 1;
        if (color > 15) return error.InvalidPictureInk;
        const vertex = @as(usize, try word(pol, 18)) + try word(pol, @as(usize, try word(pol, 10)) + @as(usize, reference & 0x3fff) * 2);
        if (vertex >= pol.len) return error.TruncatedPicture;
        const deltas = pol[vertex];
        if (deltas >= 64) return error.UnsupportedPictureCurve;
        if (pol.len - vertex < 5 + @as(usize, deltas) * 2) return error.TruncatedPicture;
        var points: [64]shapes.Point = undefined;
        var x: i16 = @bitCast(try word(pol, vertex + 1));
        var y: i16 = @bitCast(try word(pol, vertex + 3));
        points[0] = .{ .x = x +% dx, .y = y +% dy };
        for (0..deltas) |i| {
            x +%= @as(i8, @bitCast(pol[vertex + 5 + i * 2]));
            y +%= @as(i8, @bitCast(pol[vertex + 6 + i * 2]));
            points[i + 1] = .{ .x = x +% dx, .y = y +% dy };
        }
        const ink: shapes.Ink = if (reference & 0x4000 != 0 and color >= 8 and deltas >= 2) .{ .mask = 0xc8 } else .{ .color = 0xc0 + color };
        try canvas.draw(points[0 .. @as(usize, deltas) + 1], ink);
    }
}
pub fn picture(cmd: []const u8, pol: []const u8, pixels: []u8, colors: *palette.Palette) !void {
    if (pixels.len != 256 * 224) return error.InvalidPictureDimensions;
    @memset(pixels, 0xc0);
    const entries = try word(cmd, 0);
    var at: usize = (@as(usize, entries) + 1) * 2;
    if (entries != 0) return error.UnsupportedPictureDirectory;
    var primitive_budget: usize = 256;
    var ink_base: u8 = 0xc0;
    var has_shapes = false;
    var drawing_finished = false;
    while (at < cmd.len) {
        const op = cmd[at];
        at += 1;
        if (op & 0x80 != 0) return;
        switch (op >> 2) {
            0, 5 => {
                if (has_shapes) drawing_finished = true;
            }, // Static picture presentation has no remaining timed commands.
            1 => {
                if (at >= cmd.len) return error.TruncatedPicture;
                if (has_shapes and cmd[at] != 0) return error.UnsupportedAnimatedPicture;
                ink_base = if (cmd[at] == 0) 0xd0 else 0xc0;
                at += 1;
            },
            3 => {
                if (drawing_finished) return error.UnsupportedAnimatedPicture;
                has_shapes = true;
                const index = try word(cmd, at);
                at += 2;
                if (ink_base != 0xc0) return error.UnsupportedPictureLayer;
                try shape(pixels, pol, index, &primitive_budget);
            },
            4 => {
                if (cmd.len - at < 2) return error.TruncatedPicture;
                const bank = cmd[at];
                const destination = cmd[at + 1];
                at += 2;
                if (destination > 1) return error.InvalidPicturePalette;
                const base = @as(usize, try word(pol, 6)) + @as(usize, bank) * 32;
                for (0..16) |i| {
                    const value = try word(pol, base + i * 2);
                    const low: u8 = if (value == 0) 0 else 3;
                    const r: u8 = @intCast(((value >> 8) & 15) * 4 | low);
                    const g: u8 = @intCast(((value >> 4) & 15) * 4 | low);
                    const b: u8 = @intCast((value & 15) * 4 | low);
                    colors[0xc0 + @as(usize, destination ^ 1) * 16 + i] = .{ .r = (r << 2) | (r >> 4), .g = (g << 2) | (g >> 4), .b = (b << 2) | (b >> 4) };
                }
            },
            else => return error.UnsupportedAnimatedPicture,
        }
    }
    return error.MissingPictureEnd;
}
pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Assets {
    var cmd = try source.readAll("DATA/SCORE.CMD", 65536);
    defer cmd.deinit();
    var pol = try source.readAll("DATA/SCORE.POL", 65536);
    defer pol.deinit();
    var fnt = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer fnt.deinit();
    var executable = try source.readAll("GAME_E.OVL", 1024 * 1024);
    errdefer executable.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(executable.bytes, &hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "bf6cef92ae8606180b907c4f901734470699b9bb999fed23a744e27eb19644ea");
    if (!std.mem.eql(u8, &hash, &expected)) return error.UnsupportedGameEdition;
    const pixels = try allocator.alloc(u8, 256 * 224);
    errdefer allocator.free(pixels);
    var colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    try picture(cmd.bytes, pol.bytes, pixels, &colors);
    const data: usize = 5632 + 0x1a680;
    @memcpy(colors[0xe0..0xf0], &(try palette.decodeActorBank(executable.bytes[data + 0xfa1 ..][0..32])));
    var font = try font_mod.decode(allocator, fnt.bytes);
    errdefer font.deinit();
    return .{ .allocator = allocator, .pixels = pixels, .colors = colors, .font = font, .executable = executable, .title = try label(executable.bytes, data + 0x25e7), .time = try label(executable.bytes, data + 0x2605), .retry = try label(executable.bytes, data + 0x260d), .abort = try label(executable.bytes, data + 0x2616), .score = try label(executable.bytes, data + 0x261c) };
}

test "static picture import validates resources and resolves a synthetic point" {
    var pixels: [256 * 224]u8 = undefined;
    var colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    var pol: [66]u8 = @splat(0);
    for ([_]usize{ 2, 6, 10, 14, 18 }, [_]u16{ 20, 22, 54, 56, 61 }) |offset, value| std.mem.writeInt(u16, pol[offset..][0..2], value, .big);
    std.mem.writeInt(u16, pol[24..26], 0x123, .big);
    std.mem.writeInt(u16, pol[56..58], 1, .big);
    pol[60] = 1;
    try picture(&.{ 0, 0, 12, 0, 0, 16, 0, 1, 255 }, &pol, &pixels, &colors);
    try std.testing.expectEqual(@as(u8, 0xc1), pixels[50 * 256 + 8]);
    try std.testing.expectEqual(palette.Rgb{ .r = 28, .g = 44, .b = 60 }, colors[0xc1]);
    try std.testing.expectError(error.TruncatedPicture, picture(&.{0}, &pol, &pixels, &colors));
    try std.testing.expectError(error.MissingPictureEnd, picture(&.{ 0, 0 }, &pol, &pixels, &colors));
    try std.testing.expectError(error.UnsupportedAnimatedPicture, picture(&.{ 0, 0, 8, 1, 255 }, &pol, &pixels, &colors));
    try std.testing.expectError(error.InvalidPicturePalette, picture(&.{ 0, 0, 16, 0, 2, 255 }, &pol, &pixels, &colors));
    pol[61] = 128;
    try std.testing.expectError(error.UnsupportedPictureCurve, picture(&.{ 0, 0, 12, 0, 0, 255 }, &pol, &pixels, &colors));
}
