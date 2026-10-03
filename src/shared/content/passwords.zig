//! Import checkpoint codes from the supported English edition into semantic destinations.
const std = @import("std");
const platform = @import("../platform.zig");
const Difficulty = @import("../settings.zig").Difficulty;
pub const Destination = struct { level: u8, difficulty: Difficulty };

pub fn lookup(source: platform.AssetSource, password: []const u8) !?Destination {
    var file = try source.readAll("GAME_E.OVL", 1024 * 1024);
    defer file.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file.bytes, &hash, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "bf6cef92ae8606180b907c4f901734470699b9bb999fed23a744e27eb19644ea");
    if (!std.mem.eql(u8, &hash, &expected)) return error.UnsupportedGameEdition;
    for (0..8) |level| for (0..3) |skill| {
        var code: [7]u8 = undefined;
        const offset = 5632 + 0x1a680 + 0x1745 + level * 21 + skill * 7;
        for (&code, file.bytes[offset..][0..7]) |*out, byte| out.* = byte ^ 0x55;
        if (std.mem.eql(u8, std.mem.sliceTo(&code, 0), password)) return .{ .level = @intCast(level), .difficulty = @fromBackingInt(@as(u2, @intCast(skill))) };
    };
    return null;
}
