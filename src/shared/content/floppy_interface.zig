//! Edition-specific interface metadata. Only supplied content is read; no executable
//! instructions, addresses or packed image survive this import boundary.
const std = @import("std");
const platform = @import("../platform.zig");
const palette = @import("palette.zig");
pub const Values = struct {
    continue_labels: [5][48]u8,
    demos: [3]@import("demo.zig").Descriptor,
    actor_colors: [2]palette.Bank,
    score_awards: [16]u16,
    actor_libraries: [4]@import("actor_art.zig").Library,
    text_colors: palette.Bank,
    interface_colors: palette.Bank,
    level_label: [6]u8,
};
fn word(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

/// The EXEPACK variant in the supplied English release. Relocations are unnecessary for
/// these immutable data fields; the image is freed immediately after their conversion.
fn expand(allocator: std.mem.Allocator, encoded: []const u8, size: usize) ![]u8 {
    if (encoded.len == 0 or encoded.len > size or size > 1024 * 1024) return error.InvalidPackedExecutable;
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);
    @memset(output, 0);
    @memcpy(output[0..encoded.len], encoded);
    var cursor = encoded.len;
    var padding: usize = 0;
    while (cursor != 0 and encoded[cursor - 1] == 255 and padding < 16) : (padding += 1) cursor -= 1;
    var end = size;
    while (true) {
        if (cursor < 3) return error.InvalidPackedExecutable;
        const opcode = encoded[cursor - 1];
        const count = word(encoded, cursor - 3);
        cursor -= 3;
        if (count > end) return error.InvalidPackedExecutable;
        end -= count;
        switch (opcode & 0xfe) {
            0xb0 => {
                if (cursor == 0) return error.InvalidPackedExecutable;
                cursor -= 1;
                @memset(output[end..][0..count], encoded[cursor]);
            },
            0xb2 => {
                if (count > cursor) return error.InvalidPackedExecutable;
                cursor -= count;
                @memcpy(output[end..][0..count], encoded[cursor..][0..count]);
            },
            else => return error.InvalidPackedExecutable,
        }
        if (opcode & 1 != 0) break;
    }
    if (cursor != end) return error.InvalidPackedExecutable;
    return output;
}

pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Values {
    var file = source.readAll("FB.EXE", 256 * 1024) catch |err| switch (err) {
        error.NotFound => try source.readAll("DATA/FB.EXE", 256 * 1024),
        else => return err,
    };
    defer file.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file.bytes, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "d5abe9fde0af738d91933a727ad9a0e186210f1ccbf8630092fd80c8b457e777");
    if (!std.mem.eql(u8, &digest, &expected)) return error.UnrecognizedFloppyExecutable;
    const image_start: usize = @as(usize, word(file.bytes, 8)) * 16;
    const stub: usize = image_start + @as(usize, word(file.bytes, 22)) * 16;
    const image = try expand(allocator, file.bytes[image_start..stub], @as(usize, word(file.bytes, stub + 12)) * 16);
    defer allocator.free(image);
    const data = image[0x1bcc0..];
    var interface_colors: palette.Bank = undefined;
    for (&interface_colors, 0..) |*color, i| color.* = .{
        .r = palette.expandComponent(data[0xf91 + i * 3]),
        .g = palette.expandComponent(data[0xf92 + i * 3]),
        .b = palette.expandComponent(data[0xf93 + i * 3]),
    };
    var demos: [3]@import("demo.zig").Descriptor = undefined;
    for (&demos, 0..) |*descriptor, index| {
        const name = word(data, 0xfe0 + index * 4);
        const source_level = word(data, 0xfe2 + index * 4);
        if (source_level >= 7) return error.InvalidDemoLevel;
        var filename: [12]u8 = @splat(0);
        const length = std.mem.indexOfScalar(u8, data[name..][0..12], 0) orelse return error.InvalidDemoFilename;
        @memcpy(filename[0..length], data[name..][0..length]);
        const room: i16 = @bitCast(word(data, 0xfec + index * 8));
        if (room >= 64) return error.InvalidDemoRoom;
        descriptor.* = .{ .filename = filename, .level = @fromBackingInt(@as(u3, @intCast(source_level))), .start = if (room < 0) null else .{ .room = @fromBackingInt(@as(u16, @intCast(room)) + 1), .position = .{ .x = @bitCast(word(data, 0xfee + index * 8)), .y = @bitCast(word(data, 0xff0 + index * 8)) } } };
    }
    var continue_labels: [5][48]u8 = @splat(@splat(0));
    for ([_]usize{ 0x215f, 0x217d, 0x2185, 0x218e, 0x2194 }, &continue_labels) |offset, *label| {
        const length = std.mem.indexOfScalar(u8, data[offset..][0..48], 0) orelse return error.InvalidContinueLabel;
        @memcpy(label[0..length], data[offset..][0..length]);
    }
    var score_awards: [16]u16 = undefined;
    for (&score_awards, 0..) |*score, i| score.* = word(data, 0xd3b + i * 2);
    var actor_libraries: [4]@import("actor_art.zig").Library = undefined;
    for (&actor_libraries, 0..) |*library, i| {
        const name = word(data, 0xe42 + i * 2);
        const length = std.mem.indexOfScalar(u8, data[name..][0..12], 0) orelse return error.InvalidActorLibrary;
        library.name = @splat(0);
        for (data[name..][0..length], library.name[0..length]) |character, *out| out.* = std.ascii.toUpper(character);
        const colors = word(data, 0xea9 + i * 2);
        library.colors = try palette.decodeActorBank(data[colors..][0..32]);
    }
    return .{
        .actor_libraries = actor_libraries,
        .score_awards = score_awards,
        .continue_labels = continue_labels,
        .demos = demos,
        .actor_colors = .{ try palette.decodeActorBank(data[0xf31..0xf51]), try palette.decodeActorBank(data[0xf51..0xf71]) },
        .text_colors = try palette.decodeActorBank(data[0xf71..0xf91]),
        .interface_colors = interface_colors,
        .level_label = data[0x13e2..0x13e8].*,
    };
}

test "packed metadata image preserves the prefix and validates packet boundaries" {
    const allocator = std.testing.allocator;
    const result = try expand(allocator, &.{ 1, 2, 3, 7, 10, 0, 0xb1 }, 13);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, result[0..3]);
    try std.testing.expect(std.mem.allEqual(u8, result[3..], 7));
    try std.testing.expectError(error.InvalidPackedExecutable, expand(allocator, &.{ 1, 255 }, 8));
    try std.testing.expectError(error.InvalidPackedExecutable, expand(allocator, &.{ 1, 255, 0, 0xb3 }, 8));
}
