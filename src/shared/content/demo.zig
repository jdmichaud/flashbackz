//! Import original demo controls and immutable starting metadata. DOS bytes stop here.
const std = @import("std");
const platform = @import("../platform.zig");
const level = @import("level.zig");
const floppy_interface = @import("floppy_interface.zig");
/// Where Conrad starts a demo: a room (0-based) and a position.
pub const Start = struct { room: u8, x: i16, y: i16 };
pub const Descriptor = struct { filename: [12]u8, level: level.Id, start: ?Start };
/// A demo: Conrad's input byte for each update (the game's own: directions, then Return, Space,
/// Shift and the inventory), and where it starts.
pub const Recording = struct { controls: []u8, descriptor: Descriptor };

pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource, index: usize) !Recording {
    if (index >= 3) return error.InvalidDemoIndex;
    const metadata = try floppy_interface.load(allocator, source);
    const descriptor = metadata.demos[index];
    var path: [64]u8 = undefined;
    var data = try source.readAll(
        try std.fmt.bufPrint(&path, "DATA/{s}", .{std.mem.sliceTo(&descriptor.filename, 0)}),
        2048,
    );
    defer data.deinit();
    return .{ .descriptor = descriptor, .controls = try decode(allocator, data.bytes) };
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len != 2048) return error.InvalidDemoLength;
    // The original tests the advanced pointer before processing input. The last byte
    // is consumed as end-of-recording and never reaches gameplay or inventory.
    return allocator.dupe(u8, data[0 .. data.len - 1]);
}

test "demo import decodes combinations and excludes the terminal byte" {
    var data: [2048]u8 = @splat(0);
    data[0] = 0x48;
    data[2047] = 255;
    const controls = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(controls);
    try std.testing.expectEqual(@as(usize, 2047), controls.len);
    try std.testing.expectEqual(@as(u8, 0x48), controls[0]);
    try std.testing.expectError(
        error.InvalidDemoLength,
        decode(std.testing.allocator, data[0..2047]),
    );
}
