//! The RGB8 palette file is quantized by the original's palette fade routine before reaching
//! the six-bit DAC. Convert it at import to the observed eight-bit colors. Research: map 2.
const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Palette = [256]Rgb;

pub fn expandComponent(component: u8) u8 {
    const quantized = component >> 2;
    return (quantized << 2) | (quantized >> 4);
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
    if (destination.len % 4 != 0 or destination.len / 4 != indices.len) return error.InvalidFrameLength;
    for (indices, 0..) |index, i| {
        const color = colors[index];
        @memcpy(destination[i * 4 ..][0..4], &[_]u8{ color.r, color.g, color.b, 255 });
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
    try std.testing.expectError(error.InvalidFrameLength, writeRgba(&.{1}, &colors, &out));
    try std.testing.expectError(error.InvalidPaletteLength, decodeRgb8(source[0..767]));
}
