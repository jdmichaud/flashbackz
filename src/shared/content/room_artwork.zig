//! DOS room artwork import. Packed horizontal strips and raw VGA planes become row-major
//! images here; the renderer consumes neither compression codes nor directory offsets.
//! Evidence: flashback-re/docs/room-artwork-map.md.
const std = @import("std");
const bitmap = @import("bitmap.zig");
const palette = @import("palette.zig");

pub const room_count = 64;
pub const width = 256;
pub const height = 224;
const directory_size = room_count * 6;
const pixel_count = width * height;
const strip_size = pixel_count / 4;

pub const Artwork = struct {
    image: bitmap.IndexedImage,
    colors: palette.Palette,
    foreground: []bool,

    pub fn deinit(self: *Artwork) void {
        self.image.allocator.free(self.foreground);
        self.image.deinit();
        self.* = undefined;
    }
};

/// Decode one room using its four background palette banks. Actor and interface palettes
/// are separate content. Absent rooms, invalid banks and unbound pixel indices are errors.
pub fn decode(allocator: std.mem.Allocator, map: []const u8, color_file: []const u8, room: u8) !Artwork {
    if (room >= room_count) return error.InvalidRoom;
    if (map.len < directory_size) return error.TruncatedRoomDirectory;
    const entry = map[@as(usize, room) * 6 ..][0..6];
    const offset = std.mem.readInt(i32, entry[0..4], .little);
    if (offset == 0) return error.AbsentRoom;
    const start: usize = @abs(offset);
    const size = std.mem.readInt(u16, entry[4..6], .little);
    if (start < directory_size or start > map.len or size > map.len - start) return error.InvalidRoomRange;
    if (size < 4) return error.TruncatedRoomPalette;
    const payload = map[start..][0..size];

    var colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 });
    for (payload[0..4], 0..) |bank, slot| {
        const decoded = try palette.decodeLevelBank(color_file, bank);
        @memcpy(colors[slot * 16 ..][0..16], &decoded);
        @memcpy(colors[(slot + 8) * 16 ..][0..16], &decoded);
    }

    var image: bitmap.IndexedImage = undefined;
    if (offset < 0) {
        image = try bitmap.decodePlanar(allocator, payload[4..], width, height);
    } else {
        const pixels = try allocator.alloc(u8, pixel_count);
        errdefer allocator.free(pixels);
        var cursor: usize = 4;
        for (0..4) |strip| {
            if (payload.len - cursor < 2) return error.TruncatedStripLength;
            const size_compressed = std.mem.readInt(u16, payload[cursor..][0..2], .little);
            cursor += 2;
            if (size_compressed > payload.len - cursor) return error.TruncatedStrip;
            try decodeRuns(payload[cursor..][0..size_compressed], pixels[strip * strip_size ..][0..strip_size]);
            cursor += size_compressed;
        }
        if (cursor != payload.len) return error.TrailingRoomData;
        image = .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
    }
    errdefer image.deinit();
    for (image.pixels) |index| {
        if (!(index < 0x40 or (index >= 0x80 and index < 0xc0))) return error.UnboundBackgroundColor;
    }
    const foreground = try allocator.alloc(bool, pixel_count);
    for (image.pixels, foreground) |index, *covered| covered.* = index & 0x80 != 0;
    return .{ .image = image, .colors = colors, .foreground = foreground };
}

/// Nonnegative codes copy 1..128 literals; negative codes repeat the following byte
/// 2..129 times. Both input consumption and the exact expanded length are checked.
fn decodeRuns(encoded: []const u8, output: []u8) !void {
    var read: usize = 0;
    var written: usize = 0;
    while (read < encoded.len) {
        const code = encoded[read];
        read += 1;
        const repeated = code >= 128;
        const count: usize = if (repeated) 257 - @as(usize, code) else @as(usize, code) + 1;
        const input_count = if (repeated) 1 else count;
        if (input_count > encoded.len - read) return error.TruncatedRun;
        if (count > output.len - written) return error.StripOverflow;
        if (repeated) @memset(output[written..][0..count], encoded[read]) else @memcpy(output[written..][0..count], encoded[read..][0..count]);
        written += count;
        read += input_count;
    }
    if (written != output.len) return error.ShortStrip;
}

test "literal and repeated run boundaries preserve their exact lengths" {
    var encoded: [135]u8 = undefined;
    @memcpy(encoded[0..6], &[_]u8{ 0, 7, 255, 8, 128, 9 });
    encoded[6] = 127;
    for (encoded[7..], 0..) |*value, i| value.* = @intCast(i);
    var pixels: [260]u8 = undefined;
    try decodeRuns(&encoded, &pixels);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 8 }, pixels[0..3]);
    for (pixels[3..132]) |value| try std.testing.expectEqual(@as(u8, 9), value);
    try std.testing.expectEqualSlices(u8, encoded[7..], pixels[132..]);
    try std.testing.expectError(error.TruncatedRun, decodeRuns(&.{128}, &pixels));
    try std.testing.expectError(error.TruncatedRun, decodeRuns(&.{ 1, 4 }, &pixels));
    try std.testing.expectError(error.StripOverflow, decodeRuns(&.{ 255, 8 }, pixels[0..1]));
    try std.testing.expectError(error.ShortStrip, decodeRuns(&.{ 0, 8 }, pixels[0..2]));
}

test "compressed strips cover consecutive rows while raw planes interleave columns" {
    const allocator = std.testing.allocator;
    var colors: [128]u8 = @splat(0);
    // A different first color in every source bank; room slots reverse their order.
    for (0..4) |bank| colors[bank * 32 + 1] = @intCast(bank + 1);
    var raw: [directory_size + 4 + pixel_count]u8 = @splat(0);
    std.mem.writeInt(i32, raw[0..4], -directory_size, .little);
    std.mem.writeInt(u16, raw[4..6], 4 + pixel_count, .little);
    @memcpy(raw[directory_size..][0..4], &[_]u8{ 3, 2, 1, 0 });
    for (0..4) |plane| @memset(raw[directory_size + 4 + plane * strip_size ..][0..strip_size], @intCast(plane * 16));
    var planar = try decode(allocator, &raw, &colors, 0);
    defer planar.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 16, 32, 48, 0, 16, 32, 48 }, planar.image.pixels[0..8]);
    try std.testing.expectEqual(palette.Rgb{ .r = 77, .g = 12, .b = 12 }, planar.colors[0]);
    try std.testing.expectEqual(planar.colors[0], planar.colors[128]);
    const strip_encoded_size = (strip_size / 128) * 2;
    var compressed: [directory_size + 4 + 4 * (2 + strip_encoded_size)]u8 = @splat(0);
    std.mem.writeInt(i32, compressed[0..4], directory_size, .little);
    std.mem.writeInt(u16, compressed[4..6], compressed.len - directory_size, .little);
    @memcpy(compressed[directory_size..][0..4], raw[directory_size..][0..4]);
    for (0..4) |strip| {
        const start = directory_size + 4 + strip * (2 + strip_encoded_size);
        std.mem.writeInt(u16, compressed[start..][0..2], strip_encoded_size, .little);
        for (0..strip_size / 128) |run| {
            compressed[start + 2 + run * 2] = 129;
            compressed[start + 3 + run * 2] = @intCast(strip * 16);
        }
    }
    var linear = try decode(allocator, &compressed, &colors, 0);
    defer linear.deinit();
    for (0..4) |strip| {
        for (linear.image.pixels[strip * strip_size ..][0..strip_size]) |value| try std.testing.expectEqual(@as(u8, @intCast(strip * 16)), value);
    }
    try std.testing.expectError(error.AbsentRoom, decode(allocator, &compressed, &colors, 1));
    try std.testing.expectError(error.InvalidRoom, decode(allocator, &compressed, &colors, 64));
    try std.testing.expectError(error.InvalidRoomRange, decode(allocator, compressed[0 .. compressed.len - 1], &colors, 0));
    compressed[directory_size] = 4;
    try std.testing.expectError(error.InvalidPaletteBank, decode(allocator, &compressed, &colors, 0));
    compressed[directory_size] = 0;
    compressed[directory_size + 7] = 0x40;
    try std.testing.expectError(error.UnboundBackgroundColor, decode(allocator, &compressed, &colors, 0));
    std.mem.writeInt(i32, compressed[0..4], std.math.minInt(i32), .little);
    try std.testing.expectError(error.InvalidRoomRange, decode(allocator, &compressed, &colors, 0));
    try std.testing.expectError(error.TruncatedRoomDirectory, decode(allocator, &.{}, &colors, 0));
}
