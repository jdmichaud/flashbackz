//! Raw four-plane bitmaps used by the DOS menu files. The importer produces ordinary row-major
//! palette indices, so rendering does not know about VGA planes. Research: bitmap-port-map 1.
const std = @import("std");

pub const IndexedImage = struct {
    allocator: std.mem.Allocator,
    width: u16,
    height: u16,
    pixels: []u8,

    pub fn deinit(self: *IndexedImage) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn decodePlanar(allocator: std.mem.Allocator, bytes: []const u8, width: u16, height: u16) !IndexedImage {
    if (width == 0 or height == 0 or width % 4 != 0) return error.InvalidDimensions;
    const count: usize = @as(usize, width) * height;
    if (count > 16 * 1024 * 1024) return error.ImageTooLarge;
    if (bytes.len != count) return error.InvalidBitmapLength;
    const pixels = try allocator.alloc(u8, count);
    const plane_size = count / 4;
    const plane_stride = @as(usize, width) / 4;
    for (0..height) |y| {
        for (0..width) |x| {
            pixels[y * width + x] = bytes[(x % 4) * plane_size + y * plane_stride + x / 4];
        }
    }
    return .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
}

test "planes become consecutive pixels across rows and groups of four" {
    const encoded = [_]u8{ 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 };
    var image = try decodePlanar(std.testing.allocator, &encoded, 8, 2);
    defer image.deinit();
    try std.testing.expectEqual(@as(u16, 8), image.width);
    try std.testing.expectEqual(@as(u16, 2), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, image.pixels);
}

test "invalid sizes fail before allocation or indexing" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, decodePlanar(allocator, &.{}, 0, 2));
    try std.testing.expectError(error.InvalidDimensions, decodePlanar(allocator, &.{}, 6, 2));
    try std.testing.expectError(error.InvalidBitmapLength, decodePlanar(allocator, &.{ 1, 2, 3 }, 4, 1));
    try std.testing.expectError(error.InvalidBitmapLength, decodePlanar(allocator, &.{ 1, 2, 3, 4, 5 }, 4, 1));
    try std.testing.expectError(error.ImageTooLarge, decodePlanar(allocator, &.{}, 32768, 32768));
}
