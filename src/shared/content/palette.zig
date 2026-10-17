//! The RGB8 palette file is quantized by the original's palette fade routine before reaching
//! the six-bit DAC. Convert it at import to the observed eight-bit colors. Research: map 2.
const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};
pub const Palette = [256]Rgb;
pub const Bank = [16]Rgb;

/// Actor colors are little-endian 0RGB words and leave the two low DAC bits clear.
/// The level-file bank conversion below has a different channel order and brightness rule.
pub fn decodeActorBank(bytes: []const u8) !Bank {
    if (bytes.len != 32) return error.InvalidPaletteLength;
    var result: Bank = undefined;
    for (&result, 0..) |*color, i| {
        const word = std.mem.readInt(u16, bytes[i * 2..][0..2], .little);
        color.* = .{
            .r = expandDac((@as(u8, @truncate(word >> 8)) & 15) << 2),
            .g = expandDac((@as(u8, @truncate(word >> 4)) & 15) << 2),
            .b = expandDac((@as(u8, @truncate(word)) & 15) << 2),
        };
    }
    return result;
}

/// Level palettes store big-endian 0BGR words. For every nonzero word the DOS game
/// sets BOTH low DAC bits in ALL channels, including channels whose nibble is zero.
/// This differs from scaling a four-bit color to eight bits. A completely zero word
/// remains black. Evidence: the original's palette routine and room captures.
pub fn decodeLevelBank(bytes: []const u8, bank: u8) !Bank {
    if (bytes.len == 0 or bytes.len % 32 != 0) return error.InvalidPaletteLength;
    if (@as(usize, bank) >= bytes.len / 32) return error.InvalidPaletteBank;
    var result: Bank = undefined;
    for (&result, 0..) |*color, i| {
        const word = std.mem.readInt(u16, bytes[@as(usize, bank) * 32 + i * 2..][0..2], .big);
        const low: u8 = if (word == 0) 0 else 3;
        color.* = .{
            .r = expandDac((@as(u8, @truncate(word)) & 15) << 2 | low),
            .g = expandDac((@as(u8, @truncate(word >> 4)) & 15) << 2 | low),
            .b = expandDac((@as(u8, @truncate(word >> 8)) & 15) << 2 | low),
        };
    }
    return result;
}

fn expandDac(component: u8) u8 {
    return (component << 2) | (component >> 4);
}

pub fn expandComponent(component: u8) u8 {
    const quantized = component >> 2;
    return expandDac(quantized);
}

pub fn decodeRgb8(bytes: []const u8) !Palette {
    if (bytes.len != 768) return error.InvalidPaletteLength;
    var result: Palette = undefined;
    for (&result, 0..) |*color, i| {
        color.* = .{
            .r = expandComponent(bytes[i * 3]),
            .g = expandComponent(bytes[i * 3 + 1]),
            .b = expandComponent(bytes[i * 3 + 2]),
        };
    }
    return result;
}

pub fn writeRgba(indices: []const u8, colors: *const Palette, destination: []u8) !void {
    if (destination.len % 4 != 0 or
        destination.len / 4 != indices.len) {
        return error.InvalidFrameLength;
    }
    // Each color's four bytes once, then a copy per pixel.
    var rgba: [256][4]u8 = undefined;
    for (&rgba, colors) |*bytes, color| {
        bytes.* = .{ color.r, color.g, color.b, 255 };
    }
    const pixels: [][4]u8 = @ptrCast(destination);
    for (pixels, indices) |*pixel, index| {
        pixel.* = rgba[index];
    }
}

test "component quantization discards the source low bits and spans the full output range" {
    try std.testing.expectEqual(@as(u8, 0), expandComponent(3));
    try std.testing.expectEqual(@as(u8, 4), expandComponent(7));
    try std.testing.expectEqual(@as(u8, 16), expandComponent(19));
    try std.testing.expectEqual(@as(u8, 231), expandComponent(231));
    try std.testing.expectEqual(@as(u8, 255), expandComponent(255));
}

test "RGB and alpha ordering is explicit and invalid buffers are refused" {
    var source: [768]u8 = @splat(0);
    @memcpy(source[3..6], &[_]u8{ 231, 19, 255 });
    const colors = try decodeRgb8(&source);
    var out: [8]u8 = undefined;
    try writeRgba(&.{ 1, 0 }, &colors, &out);
    try std.testing.expectEqualSlices(u8, &.{ 231, 16, 255, 255, 0, 0, 0, 255 }, &out);
    try std.testing.expectError(error.InvalidFrameLength, writeRgba(&.{ 1 }, &colors, &out));
    try std.testing.expectError(error.InvalidPaletteLength, decodeRgb8(source[0..767]));
}

test "level palette black and zero channels in nonblack colors are distinct" {
    var source: [32]u8 = @splat(0);
    @memcpy(source[2..8], &[_]u8{ 0, 1, 0x0f, 0, 0x01, 0x23 });
    const bank = try decodeLevelBank(&source, 0);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, bank[0]);
    try std.testing.expectEqual(Rgb{ .r = 28, .g = 12, .b = 12 }, bank[1]);
    try std.testing.expectEqual(Rgb{ .r = 12, .g = 12, .b = 255 }, bank[2]);
    try std.testing.expectEqual(Rgb{ .r = 60, .g = 44, .b = 28 }, bank[3]);
    try std.testing.expectError(error.InvalidPaletteBank, decodeLevelBank(&source, 1));
    try std.testing.expectError(error.InvalidPaletteLength, decodeLevelBank(source[0..31], 0));
}

test "actor palette uses its own channel order and DAC brightness" {
    var source: [32]u8 = @splat(0);
    @memcpy(source[2..6], &[_]u8{ 0x23, 0x01, 0xff, 0x0f });
    const bank = try decodeActorBank(&source);
    try std.testing.expectEqual(Rgb{ .r = 16, .g = 32, .b = 48 }, bank[1]);
    try std.testing.expectEqual(Rgb{ .r = 243, .g = 243, .b = 243 }, bank[2]);
}
