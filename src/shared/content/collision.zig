//! Compatibility import of room links and blocking occupancy. Source material tags remain
//! owned here for later interaction import; the geometry projection answers occupancy only.
const std = @import("std");
const backward = @import("backward_stream.zig");
const geometry = @import("../geometry.zig");
const terrain = @import("../terrain.zig");

// The original admits a new saved footprint while its accumulated cost is below this
// bound, even if that final footprint takes the total above it. Keep the source-specific
// cost at import; terrain storage and restoration use ordinary owned materials.
pub const history_limit = 762;
pub fn snapshotWeight(width: u16) usize {
    return 3 + @as(usize, width) / 2;
}

pub fn snapshotReuse(width: u16, mirrored: bool) terrain.Reuse {
    // The original search's increment/decrement pair exits after its first nonmatch
    // only for a mirrored one-cell footprint. It can therefore create another snapshot.
    return if (mirrored and width == 1) .latest_only else .matching_origin;
}

pub const Layout = struct {
    allocator: std.mem.Allocator,
    history_allowance: usize = history_limit,
    source: []u8,
    occupancy: []bool,
    materials: []terrain.Material,
    rooms: []geometry.Room,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.rooms);
        self.allocator.free(self.occupancy);
        self.allocator.free(self.materials);
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn map(self: *const Layout) geometry.Map {
        return .{ .rooms = self.rooms };
    }
};

/// The caller allocates room IDs in its content namespace, independently of source indices.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, room_ids: *const [64]geometry.RoomId) !Layout {
    const source = try backward.decode(allocator, bytes, 7424);
    return importOwned(allocator, source, room_ids);
}

/// Research and synthetic content can supply the decompressed layout directly. Ownership
/// still belongs to the returned layout, independently of the caller's input buffer.
pub fn fromDecoded(allocator: std.mem.Allocator, bytes: []const u8, room_ids: *const [64]geometry.RoomId) !Layout {
    return importOwned(allocator, try allocator.dupe(u8, bytes), room_ids);
}

fn importOwned(allocator: std.mem.Allocator, source: []u8, room_ids: *const [64]geometry.RoomId) !Layout {
    errdefer allocator.free(source);
    if (source.len != 7424) return error.InvalidCollisionLayout;
    for (room_ids, 0..) |id, i| {
        for (room_ids[0..i]) |previous| if (previous == id) return error.DuplicateRoomId;
    }
    const occupancy = try allocator.alloc(bool, 64 * 112);
    errdefer allocator.free(occupancy);
    const materials = try allocator.alloc(terrain.Material, occupancy.len);
    errdefer allocator.free(materials);
    for (source[256..], occupancy, materials) |tag, *cell, *material| {
        if (tag > 2) return error.UnknownCollisionMaterial;
        cell.* = tag != 0;
        material.* = switch (tag) {
            0 => .empty,
            1 => .solid,
            2 => .restricted,
            else => unreachable,
        };
    }
    const rooms = try allocator.alloc(geometry.Room, 64);
    errdefer allocator.free(rooms);
    for (rooms, 0..) |*room, i| {
        room.* = .{
            .id = room_ids[i],
            .columns = 16,
            .rows = 7,
            .blocking = occupancy[i * 112 ..][0..112],
            .width = 256,
            .height = 216,
            .edges = .{
                .up = try edge(source[i], room_ids, false),
                .down = try edge(source[64 + i], room_ids, false),
                .right = try edge(source[128 + i], room_ids, true),
                .left = try edge(source[192 + i], room_ids, false),
            },
        };
    }
    return .{ .allocator = allocator, .source = source, .occupancy = occupancy, .materials = materials, .rooms = rooms };
}

fn edge(index: u8, ids: *const [64]geometry.RoomId, missing_right: bool) !geometry.Edge {
    if (index >= 128) return if (missing_right) .unresolved else .blocked;
    if (index >= ids.len) return error.InvalidRoomLink;
    return .{ .room = ids[index] };
}

test "source room links resolve independently of occupancy and material metadata" {
    var source: [7424]u8 = @splat(0);
    @memset(source[0..256], 255);
    source[192 + 1] = 0;
    source[256 + 16] = 2;
    var ids: [64]geometry.RoomId = undefined;
    for (&ids, 0..) |*id, i| id.* = @fromBackingInt(@as(u16, @intCast(i)) + 900);
    var layout = try fromDecoded(std.testing.allocator, &source, &ids);
    defer layout.deinit();
    source[256 + 16] = 0;
    try std.testing.expect(try layout.map().blocked(ids[0], 0, 1));
    try std.testing.expectEqual(@as(u8, 2), layout.source[256 + 16]);
    try std.testing.expect(!try layout.map().blocked(ids[1], -1, 1));
    try std.testing.expectError(error.UnresolvedBoundary, layout.map().blocked(ids[1], 16, 1));
    try std.testing.expectError(error.InvalidCollisionLayout, fromDecoded(std.testing.allocator, source[0..7423], &ids));
    source[0] = 64;
    try std.testing.expectError(error.InvalidRoomLink, fromDecoded(std.testing.allocator, &source, &ids));
    source[0] = 255;
    source[256] = 3;
    try std.testing.expectError(error.UnknownCollisionMaterial, fromDecoded(std.testing.allocator, &source, &ids));
}
