//! Expose a cooked ISO or a single MODE1/2352 track as ordinary 2048-byte logical sectors.
//! Both a native file and a browser/memory source can supply the physical bytes. No extraction.
const std = @import("std");
const iso = @import("iso.zig");
const platform = @import("platform.zig");

pub const Track = struct {
    physical: iso.ByteSource,
    raw: bool,

    pub fn init(source: iso.ByteSource) platform.AssetError!Track {
        var signature: [7]u8 = undefined;
        source.readExact(16 * 2048, &signature) catch return error.Io;
        if (signature[0] == 1 and std.mem.eql(u8, signature[1..], "CD001\x01"))
            return .{ .physical = source, .raw = false };
        source.readExact(16 * 2352 + 16, &signature) catch return error.Io;
        if (signature[0] != 1 or !std.mem.eql(u8, signature[1..], "CD001\x01")) return error.Io;
        if (source.length()) |size| if (size % 2352 != 0) return error.Io;
        const result: Track = .{ .physical = source, .raw = true };
        try result.validateSector(16);
        return result;
    }

    pub fn byteSource(self: *Track) iso.ByteSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = iso.ByteSource.VTable{ .read_at = readAt, .length = length };

    fn validateSector(self: *const Track, lba: u64) platform.AssetError!void {
        var header: [16]u8 = undefined;
        const offset = std.math.mul(u64, lba, 2352) catch return error.Io;
        try self.physical.readExact(offset, &header);
        if (header[0] != 0 or header[11] != 0 or header[15] != 1) return error.Io;
        for (header[1..11]) |byte| if (byte != 255) return error.Io;
    }

    fn readAt(ctx: *anyopaque, offset: u64, destination: []u8) platform.AssetError!usize {
        const self: *Track = @ptrCast(@alignCast(ctx));
        if (!self.raw) return self.physical.readAt(offset, destination);
        if (destination.len == 0) return 0;
        if (self.physical.length()) |size| if (offset >= size / 2352 * 2048) return 0;
        const lba = offset / 2048;
        const within = offset % 2048;
        try self.validateSector(lba);
        const sector_offset = std.math.mul(u64, lba, 2352) catch return error.Io;
        const at = std.math.add(u64, sector_offset, 16 + within) catch return error.Io;
        const count: usize = @intCast(@min(@as(u64, destination.len), 2048 - within));
        return self.physical.readAt(at, destination[0..count]);
    }

    fn length(ctx: *anyopaque) ?u64 {
        const self: *Track = @ptrCast(@alignCast(ctx));
        const physical_length = self.physical.length() orelse return null;
        return if (self.raw) physical_length / 2352 * 2048 else physical_length;
    }
};

pub fn makeTestRaw(allocator: std.mem.Allocator, cooked: []const u8) ![]u8 {
    if (cooked.len % 2048 != 0) return error.Io;
    const raw = try allocator.alloc(u8, cooked.len / 2048 * 2352);
    @memset(raw, 0);
    for (0..cooked.len / 2048) |lba| {
        const at = lba * 2352;
        @memset(raw[at + 1 .. at + 11], 255);
        raw[at + 15] = 1;
        @memcpy(raw[at + 16 ..][0..2048], cooked[lba * 2048 ..][0..2048]);
    }
    return raw;
}

test "cooked and raw images expose identical files and boundary reads" {
    const allocator = std.testing.allocator;
    var payload: [4099]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 13);
    const cooked = try iso.buildTestImage(allocator, &.{.{ .path = "DATA/FILE.DAT", .bytes = &payload }});
    defer allocator.free(cooked);
    const raw = try makeTestRaw(allocator, cooked);
    defer allocator.free(raw);
    for ([_][]const u8{ cooked, raw }) |bytes| {
        var memory = iso.MemoryByteSource.init(bytes);
        memory.max_read = 97;
        var track = try Track.init(memory.byteSource());
        var assets = try iso.IsoAssetSource.init(allocator, track.byteSource());
        defer assets.deinit();
        var file = try assets.assetSource().readAll("data/file.dat", 8192);
        defer file.deinit();
        try std.testing.expectEqualSlices(u8, &payload, file.bytes);
        const logical = track.byteSource();
        var crossing: [10]u8 = undefined;
        try logical.readExact(2045, &crossing);
        try std.testing.expectEqualSlices(u8, cooked[2045..2055], &crossing);
    }
}

test "raw truncation and a bad sector mode are refused" {
    const allocator = std.testing.allocator;
    const cooked = try iso.buildTestImage(allocator, &.{.{ .path = "FILE.DAT", .bytes = "hello" }});
    defer allocator.free(cooked);
    const raw = try makeTestRaw(allocator, cooked);
    defer allocator.free(raw);
    var truncated = iso.MemoryByteSource.init(raw[0 .. raw.len - 1]);
    try std.testing.expectError(error.Io, Track.init(truncated.byteSource()));
    raw[16 * 2352 + 15] = 2;
    var bad_mode = iso.MemoryByteSource.init(raw);
    try std.testing.expectError(error.Io, Track.init(bad_mode.byteSource()));
}
