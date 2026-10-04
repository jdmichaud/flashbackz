//! Owned, bounded files at the content import boundary. Runtime providers borrow this pack.
const std = @import("std");
const memory = @import("memory.zig");
const platform = @import("platform.zig");
pub const Pack = struct {
    source: memory.MemoryAssetSource,
    total: usize = 0,
    pub const limit = 32 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) Pack {
        return .{ .source = memory.MemoryAssetSource.init(allocator) };
    }
    pub fn deinit(self: *Pack) void {
        for (self.source.entries.keys(), self.source.entries.values()) |name, bytes| {
            self.source.allocator.free(name);
            self.source.allocator.free(bytes);
        }
        self.source.deinit();
        self.* = undefined;
    }
    pub fn add(self: *Pack, name: []const u8, bytes: []const u8) !void {
        try platform.validateAssetName(name);
        for (self.source.entries.keys(), self.source.entries.values()) |existing, data| {
            if (platform.assetNameEql(existing, name)) {
                if (!std.mem.eql(u8, data, bytes)) return error.ConflictingAsset;
                return;
            }
        }
        if (bytes.len > limit - self.total or self.source.entries.count() >= 4096) return error.TooLarge;
        const allocator = self.source.allocator;
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, bytes);
        errdefer allocator.free(value);
        try self.source.add(key, value);
        self.total += bytes.len;
    }
    pub fn assetSource(self: *Pack) platform.AssetSource {
        return self.source.assetSource();
    }
};
