//! The Mega Drive edition's cartridge, whose tunes play during play when the user names it
//! (PLAN MD-B; flashback-re docs/megadrive-music.md). Its file is read at run time and reaches
//! the game through the asset source, under `asset`; nothing of it is in the repository.
const std = @import("std");

/// The cartridge the tunes are read from: `Flashback (Europe) (En,Fr)`. Where its tunes are
/// depends on the edition, so only this one is accepted.
pub const sha256 = "ff8a315882db2bb01fdc876fb5cffb245ae6a999cde063c63ff5ea312e455c67";
pub const size = 2 * 1024 * 1024;

/// The cartridge's name in the asset source.
pub const asset = "MEGADRIVE.MD";

/// Whether `bytes` are the accepted cartridge.
pub fn isCartridge(bytes: []const u8) bool {
    if (bytes.len != size) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, sha256) catch unreachable;
    return std.mem.eql(u8, &digest, &expected);
}

test "only the accepted cartridge is recognised" {
    const other: [size]u8 = @splat(0);
    try std.testing.expect(!isCartridge(&other));
    try std.testing.expect(!isCartridge("short"));
}
