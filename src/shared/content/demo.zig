//! Import original demo controls and immutable starting metadata. DOS bytes stop here.
const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../input_recording.zig");
const level = @import("level.zig");
const floppy_interface = @import("floppy_interface.zig");
/// Where Conrad starts a demo: a room (0-based) and a position.
pub const Start = struct { room: u8, x: i16, y: i16 };
pub const Descriptor = struct { filename: [12]u8, level: level.Id, start: ?Start };
pub const Recording = struct { controls: []input.Sample, descriptor: Descriptor };

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

pub fn decode(allocator: std.mem.Allocator, data: []const u8) ![]input.Sample {
    if (data.len != 2048) return error.InvalidDemoLength;
    // The original tests the advanced pointer before processing input. The last byte
    // is consumed as end-of-recording and never reaches gameplay or inventory.
    const samples = try allocator.alloc(input.Sample, data.len - 1);
    for (data[0..samples.len], samples) |bits, *sample| sample.* = .{
        .up = bits & 1 != 0,
        .down = bits & 2 != 0,
        .left = bits & 4 != 0,
        .right = bits & 8 != 0,
        .use_item = bits & 16 != 0,
        .weapon = bits & 32 != 0,
        .action = bits & 64 != 0,
        .inventory = bits & 128 != 0,
    };
    return samples;
}

test "demo import decodes combinations and excludes the terminal byte" {
    var data: [2048]u8 = @splat(0);
    data[0] = 0x48;
    data[2047] = 255;
    const samples = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual(@as(usize, 2047), samples.len);
    try std.testing.expect(samples[0].right and samples[0].action and !samples[0].left);
    try std.testing.expectError(
        error.InvalidDemoLength,
        decode(std.testing.allocator, data[0..2047]),
    );
}
