//! ABA installation archives become ordinary owned assets before scene loading.
const std = @import("std");
const Pack = asset_pack.Pack;
const codec = @import("backward_stream.zig");
const asset_pack = @import("../asset_pack.zig");

/// Adds the files of one ABA archive to `pack`, under `prefix`. The archive starts with a
/// big-endian u16 file count and the record size, 30. A record, in big-endian numbers:
/// - bytes 0-13: the file name, ended by a 0 byte;
/// - bytes 14-17: the offset; bytes 18-21: the stored size; bytes 22-25: the size;
/// - bytes 26-29: the tag "D.M.".
/// The files follow the records in order, and the last file ends the archive. A file whose
/// stored size is smaller than its size is a packed `backward_stream`.
pub fn expand(pack: *Pack, bytes: []const u8, prefix: []const u8) !void {
    if (bytes.len < 4) return error.TruncatedArchive;
    const count = std.mem.readInt(u16, bytes[0..2], .big);
    const stride = std.mem.readInt(u16, bytes[2..4], .big);
    if (stride != 30 or count > 4096) return error.InvalidArchiveHeader;
    var previous_end: usize = 4 + @as(usize, count) * 30;
    if (previous_end > bytes.len) return error.TruncatedArchive;
    for (0..count) |i| {
        const record = bytes[4 + i * 30..][0..30];
        const name_end = std.mem.indexOfScalar(u8, record[0..14], 0) orelse
            return error.InvalidArchiveName;
        const name = record[0..name_end];
        if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidArchiveName;
        const at: usize = std.mem.readInt(u32, record[14..18], .big);
        const stored_size: usize = std.mem.readInt(u32, record[18..22], .big);
        const size: usize = std.mem.readInt(u32, record[22..26], .big);
        if (!std.mem.eql(u8, record[26..30], "D.M.")) return error.InvalidArchiveTag;
        if (at < previous_end or
            at > bytes.len or
            stored_size > bytes.len - at or
            stored_size > size) {
            return error.InvalidArchiveExtent;
        }
        if (size > Pack.limit - pack.total) return error.TooLarge;
        previous_end = at + stored_size;
        const allocator = pack.source.allocator;
        const path = try std.mem.concat(allocator, u8, &.{ prefix, name });
        defer allocator.free(path);
        const input = bytes[at..][0..stored_size];
        if (stored_size == size) {
            try pack.add(path, input);
        } else {
            const output = try codec.decode(allocator, input, size);
            defer allocator.free(output);
            if (output.len != size) return error.ArchiveSizeMismatch;
            try pack.add(path, output);
        }
    }
    if (previous_end != bytes.len) return error.ArchiveTrailingBytes;
}

pub fn expandAll(pack: *Pack) !void {
    const initial_count = pack.source.entries.count();
    for (0..initial_count) |i| {
        // Table growth can move the slices, but each name and payload is separately owned.
        const name = pack.source.entries.keys()[i];
        if (!std.ascii.endsWithIgnoreCase(name, ".ABA")) continue;
        const prefix = if (std.mem.lastIndexOfScalar(u8, name, '/')) |at| name[0..at + 1] else "";
        try expand(pack, pack.source.entries.values()[i], prefix);
    }
}

test "ABA checks decompressed size, checksum, extent and conflicting assets" {
    const allocator = std.testing.allocator;
    var pack = Pack.init(allocator);
    defer pack.deinit();
    var bytes: [46]u8 = @splat(0);
    bytes[1] = 1;
    bytes[3] = 30;
    @memcpy(bytes[4..12], "FILE.DAT");
    bytes[21] = 34;
    bytes[25] = 12;
    bytes[29] = 16;
    @memcpy(bytes[30..34], "D.M.");
    // Distance-one synthetic compressed stream, size deliberately inconsistent at first.
    bytes[34..46].* = .{ 3, 0, 0x30, 0x40, 3, 0, 0x30, 0x40, 0, 0, 0, 4 };
    try std.testing.expectError(error.ArchiveSizeMismatch, expand(&pack, &bytes, "DATA/"));
    bytes[29] = 12; // Stored 12-byte resource.
    try expand(&pack, &bytes, "DATA/");
    try std.testing.expectError(error.ConflictingAsset, pack.add("data/file.dat", "different"));
    bytes[21] = 33;
    try std.testing.expectError(error.InvalidArchiveExtent, expand(&pack, &bytes, "DATA/"));
    bytes[21] = 34;
    bytes[29] = 16;
    bytes[38] ^= 1;
    try std.testing.expectError(error.InvalidBitstreamChecksum, expand(&pack, &bytes, "DATA/"));
}
