//! Resolve supplied level codes to a named level and difficulty.
const std = @import("std");
const level = @import("level.zig");
pub const Destination = struct {
    level: level.Id,
    difficulty: @import("../settings.zig").Difficulty,
};
pub const Table = [7][3][7]u8;

pub fn match(codes: Table, input: []const u8) ?Destination {
    if (input.len == 0 or input.len > 6) return null;
    for (codes, 0..) |difficulties, level_index| for (difficulties, 0..) |code, difficulty| {
        const expected = std.mem.sliceTo(&code, 0);
        if (expected.len != 0 and std.ascii.eqlIgnoreCase(input, expected)) return .{
            .level = @fromBackingInt(@as(u3, @intCast(level_index))),
            .difficulty = @fromBackingInt(@as(u2, @intCast(difficulty))),
        };
    };
    return null;
}

pub fn lookup(
    allocator: std.mem.Allocator,
    source: @import("../platform.zig").AssetSource,
    input: []const u8,
) !?Destination {
    const values = try @import("floppy_interface.zig").load(allocator, source);
    return match(values.passwords, input);
}

test "level codes select their difficulty, retain spaces and reject partial input" {
    var codes: Table = @splat(@splat(@splat(0)));
    @memcpy(codes[1][1][0..4], "CITY");
    @memcpy(codes[6][2][0..6], "END GO");
    try std.testing.expectEqualDeep(
        @as(?Destination, .{ .level = .city, .difficulty = .normal }),
        match(codes, "city"),
    );
    try std.testing.expectEqualDeep(
        @as(?Destination, .{ .level = .alien_base, .difficulty = .expert }),
        match(codes, "END GO"),
    );
    for ([_][]const u8{
        "",
        "CIT",
        "CITYXX",
        "END",
        "ENDGO",
        "END GOX",
    }) |input| try std.testing.expect(match(codes, input) == null);
}
