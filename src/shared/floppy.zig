//! Read-only FAT12 import. Validate geometry, both FAT copies, cluster ownership and lengths
//! before exposing files. No DOS execution, installation or host filesystem writes.
const std = @import("std");
const Pack = asset_pack.Pack;
const asset_pack = @import("asset_pack.zig");
const platform = @import("platform.zig");

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
const Volume = struct {
    bytes: []const u8,
    fat: []const u8,
    cluster_bytes: usize,
    data_offset: usize,
    cluster_count: usize,
    claimed: [4086]bool = @splat(false),

    /// A FAT12 entry has 12 bits, so two entries share 3 bytes. Values from 0xff8 end a chain.
    fn next(self: *const Volume, cluster: usize) !usize {
        const at = cluster + cluster / 2;
        if (at + 2 > self.fat.len) return error.InvalidFat;
        const pair = word(self.fat, at);
        return if (cluster % 2 == 0) pair & 0xfff else pair >> 4;
    }
    fn chain(self: *Volume, allocator: std.mem.Allocator, first: usize, length: ?usize) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var cluster = first;
        if (length == 0) {
            if (cluster != 0) return error.InvalidChain;
            return try result.toOwnedSlice(allocator);
        }
        while (true) {
            if (cluster < 2 or
                cluster >= self.cluster_count + 2 or
                cluster >= 0xff0) {
                return error.InvalidChain;
            }
            if (self.claimed[cluster]) return error.CrossLinkedCluster;
            self.claimed[cluster] = true;
            const offset = self.data_offset + (cluster - 2) * self.cluster_bytes;
            try result.appendSlice(allocator, self.bytes[offset..][0..self.cluster_bytes]);
            cluster = try self.next(cluster);
            if (cluster >= 0xff8) break;
            if (length) |size| {
                if (result.items.len >= size) return error.InvalidChainLength;
            }
        }
        if (length) |size| {
            if (size > result.items.len or
                result.items.len - size >= self.cluster_bytes) {
                return error.InvalidChainLength;
            }
            result.shrinkRetainingCapacity(size);
        }
        return try result.toOwnedSlice(allocator);
    }
    fn directory(
        self: *Volume,
        pack: *Pack,
        bytes: []const u8,
        prefix: []const u8,
        depth: usize,
    ) anyerror!void {
        if (depth > 8) return error.DirectoryTooDeep;
        const allocator = pack.source.allocator;
        var offset: usize = 0;
        while (offset + 32 <= bytes.len) : (offset += 32) {
            const record = bytes[offset..][0..32];
            // Byte 0: 0 ends the directory, 0xe5 marks a deleted entry. Byte 11 holds the
            // attributes: 0x0f is a long name part, bit 3 a volume label, bit 4 a directory.
            if (record[0] == 0) break;
            if (record[0] == 0xe5 or record[11] == 0x0f or record[11] & 8 != 0) continue;
            if (record[0] == '.') continue;
            if (word(record, 20) != 0 or record[11] & 0xc0 != 0) return error.InvalidDirectory;
            const stem = std.mem.trimEnd(u8, record[0..8], " ");
            const ext = std.mem.trimEnd(u8, record[8..11], " ");
            const name = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
                prefix,
                stem,
                if (ext.len == 0) "" else ".",
                ext,
            });
            defer allocator.free(name);
            try platform.validateAssetName(name);
            const size = std.mem.readInt(u32, record[28..32], .little);
            const is_directory = record[11] & 0x10 != 0;
            if (is_directory and size != 0) return error.InvalidDirectory;
            const data = try self.chain(
                allocator,
                word(record, 26),
                if (is_directory) null else size,
            );
            defer allocator.free(data);
            if (is_directory) {
                const child = try std.mem.concat(allocator, u8, &.{ name, "/" });
                defer allocator.free(child);
                try self.directory(pack, data, child, depth + 1);
            } else {
                try pack.add(name, data);
            }
        }
    }
};

/// Reads every file of a FAT12 floppy image into a new pack. The boot sector fields, all
/// little-endian: the sector size at 11, sectors a cluster at 13, reserved sectors at 14,
/// the FAT count at 16, root entries at 17, the sector count at 19 and FAT sectors at 22.
pub fn load(allocator: std.mem.Allocator, image: []const u8) !Pack {
    if (image.len < 512 or word(image, 510) != 0xaa55) return error.InvalidBootSector;
    const sector: usize = word(image, 11);
    const sectors_per_cluster: usize = image[13];
    const reserved: usize = word(image, 14);
    const fats: usize = image[16];
    const root_entries: usize = word(image, 17);
    const sectors: usize = word(image, 19);
    const fat_sectors: usize = word(image, 22);
    if (sector != 512 or
        sectors_per_cluster == 0 or
        sectors_per_cluster > 64 or
        !std.math.isPowerOfTwo(sectors_per_cluster) or
        reserved == 0 or
        fats != 2 or
        root_entries == 0 or
        sectors == 0 or
        fat_sectors == 0) {
        return error.UnsupportedFloppyGeometry;
    }
    if (image.len != sectors * sector) return error.InvalidImageLength;
    const root_offset = (reserved + fats * fat_sectors) * sector;
    const root_size = std.mem.alignForward(usize, root_entries * 32, sector);
    const data_offset = root_offset + root_size;
    if (data_offset >= image.len) return error.InvalidImageLength;
    const cluster_bytes = sector * sectors_per_cluster;
    const count = (image.len - data_offset) / cluster_bytes;
    if (count == 0 or count > 4084) return error.UnsupportedFloppyGeometry;
    const fat = image[reserved * sector..][0..fat_sectors * sector];
    if (fat.len < ((count + 2) * 3 + 1) / 2 or
        fat[0] != image[21] or
        fat[1] != 255 or
        fat[2] != 255) {
        return error.InvalidFat;
    }
    if (!std.mem.eql(u8, fat, image[(reserved + fat_sectors) * sector..][0..fat.len])) {
        return error.FatCopiesDiffer;
    }
    var volume: Volume = .{
        .bytes = image,
        .fat = fat,
        .cluster_bytes = cluster_bytes,
        .data_offset = data_offset,
        .cluster_count = count,
    };
    var pack = Pack.init(allocator);
    errdefer pack.deinit();
    try volume.directory(&pack, image[root_offset..][0..root_entries * 32], "", 0);
    return pack;
}

/// Synthetic fragmented file in a subdirectory, with the second cluster before the first.
pub fn testImage(allocator: std.mem.Allocator) ![]u8 {
    const image = try allocator.alloc(u8, 1474560);
    @memset(image, 0);
    std.mem.writeInt(u16, image[11..13], 512, .little);
    image[13] = 1;
    image[14] = 1;
    image[16] = 2;
    image[17] = 224;
    std.mem.writeInt(u16, image[19..21], 2880, .little);
    image[21] = 0xf0;
    image[22] = 9;
    image[510] = 0x55;
    image[511] = 0xaa;
    for ([_]usize{ 512, 5120 }) |base| {
        image[base..][0..8].* = .{ 0xf0, 255, 255, 255, 255, 255, 3, 0 }; // 2=end, 3=end, 4->3
    }
    const root = image[19 * 512..][0..32];
    @memcpy(root[0..11], "DATA       ");
    root[11] = 16;
    root[26] = 2;
    const file = image[33 * 512..][0..32];
    @memcpy(file[0..11], "FILE    DAT");
    file[26] = 4;
    std.mem.writeInt(u32, file[28..32], 600, .little);
    @memset(image[35 * 512..][0..512], 'A');
    @memset(image[34 * 512..][0..88], 'B');
    return image;
}

test "FAT12 follows fragmented chains and rejects mismatched FATs, loops and truncation" {
    const allocator = std.testing.allocator;
    const image = try testImage(allocator);
    defer allocator.free(image);
    var pack = try load(allocator, image);
    defer pack.deinit();
    var data = try pack.assetSource().readAll("data/file.dat", 600);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 600), data.bytes.len);
    for (data.bytes[0..512]) |byte| {
        try std.testing.expectEqual(@as(u8, 'A'), byte);
    }
    for (data.bytes[512..]) |byte| {
        try std.testing.expectEqual(@as(u8, 'B'), byte);
    }
    try std.testing.expectError(error.InvalidImageLength, load(allocator, image[0..image.len - 1]));
    image[512 + 6] = 4;
    try std.testing.expectError(error.FatCopiesDiffer, load(allocator, image));
    image[5120 + 6] = 4;
    try std.testing.expectError(error.CrossLinkedCluster, load(allocator, image));
}

fn allocationExercise(allocator: std.mem.Allocator, image: []const u8) !void {
    var pack = try load(allocator, image);
    defer pack.deinit();
    var file = try pack.assetSource().readAll("DATA/FILE.DAT", 600);
    defer file.deinit();
}

test "floppy import releases all partial allocations on failure" {
    const image = try testImage(std.testing.allocator);
    defer std.testing.allocator.free(image);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{
        image,
    });
}
