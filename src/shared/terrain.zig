//! Session-owned terrain edits. Each origin remembers the cells it replaced the first
//! time; restoration preserves that history, including overlapping edits and later rewrites.
const std = @import("std");
const geometry = @import("geometry.zig");

pub const Material = enum { empty, solid, restricted };
pub const Address = geometry.CellAddress;
pub const Reuse = enum { matching_origin, latest_only };
pub const Span = struct { origin: Address, length: u16, history_weight: usize = 1, reuse: Reuse = .matching_origin };
pub const Options = struct { history_limit: ?usize = null };
const Snapshot = struct { offset: usize, saved_length: u16, restore_length: u16 };

/// Read-only materials over the same room connectivity used by occupancy queries.
/// Slices remain valid when the owning State value moves; edits are immediately visible.
pub const View = struct {
    geometry: geometry.Map,
    materials: []const Material,

    pub fn sample(self: View, room: geometry.RoomId, column: i16, row: i16) !Material {
        const address = try self.geometry.locate(room, column, row) orelse return .solid;
        var base: usize = 0;
        for (self.geometry.rooms) |candidate| {
            if (candidate.id == address.room) return self.materials[base + @as(usize, address.row) * candidate.columns + address.column];
            base += candidate.blocking.len;
        }
        return error.UnknownRoom;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    rooms: []geometry.Room,
    materials: []Material,
    occupancy: []bool,
    history: []Snapshot,
    saved: []Material,
    history_length: usize = 0,
    stride: usize,
    history_limit: ?usize,
    history_used: usize = 0,

    /// Storage is bounded by the grid and the edit allowance. No allocation occurs when
    /// an object changes or restores its footprint, including limited snapshot reuse.
    pub fn init(allocator: std.mem.Allocator, base: geometry.Map, cells: []const Material, options: Options) !State {
        var count: usize = 0;
        var stride: usize = 0;
        for (base.rooms, 0..) |room, i| {
            if (room.columns == 0 or room.rows == 0 or room.blocking.len != @as(usize, room.columns) * room.rows) return error.InvalidTerrain;
            for (base.rooms[0..i]) |previous| if (previous.id == room.id) return error.DuplicateRoomId;
            count = try std.math.add(usize, count, room.blocking.len);
            stride = @max(stride, room.columns);
        }
        if (cells.len != count) return error.InvalidTerrain;
        const rooms = try allocator.dupe(geometry.Room, base.rooms);
        errdefer allocator.free(rooms);
        const materials = try allocator.dupe(Material, cells);
        errdefer allocator.free(materials);
        const occupancy = try allocator.alloc(bool, count);
        errdefer allocator.free(occupancy);
        const capacity = @max(count, options.history_limit orelse count);
        const history = try allocator.alloc(Snapshot, capacity);
        errdefer allocator.free(history);
        const saved = try allocator.alloc(Material, try std.math.mul(usize, capacity, stride));
        var offset: usize = 0;
        for (rooms) |*room| {
            const length = room.blocking.len;
            room.blocking = occupancy[offset..][0..length];
            offset += length;
        }
        for (occupancy, materials) |*blocked, material| blocked.* = material != .empty;
        return .{ .allocator = allocator, .rooms = rooms, .materials = materials, .occupancy = occupancy, .history = history, .saved = saved, .stride = stride, .history_limit = options.history_limit };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.rooms);
        self.allocator.free(self.materials);
        self.allocator.free(self.occupancy);
        self.allocator.free(self.history);
        self.allocator.free(self.saved);
        self.* = undefined;
    }

    pub fn map(self: *const State) geometry.Map {
        return .{ .rooms = self.rooms };
    }

    pub fn view(self: *const State) View {
        return .{ .geometry = self.map(), .materials = self.materials };
    }

    fn offsetOf(self: *const State, address: Address, length: u16) !usize {
        var base: usize = 0;
        for (self.rooms) |room| {
            if (room.id == address.room) {
                if (length == 0 or address.row >= room.rows or address.column >= room.columns or length > room.columns - address.column)
                    return error.TerrainSpanOutsideRoom;
                return base + @as(usize, address.row) * room.columns + address.column;
            }
            base += room.blocking.len;
        }
        return error.UnknownRoom;
    }

    pub fn at(self: *const State, address: Address) !Material {
        return self.materials[try self.offsetOf(address, 1)];
    }

    fn remembered(self: *const State, offset: usize, reuse: Reuse) ?usize {
        var i = self.history_length;
        while (i != 0) {
            i -= 1;
            if (self.history[i].offset == offset) return i;
            if (reuse == .latest_only) break;
        }
        return null;
    }

    /// False means a new edit exhausted the level's history allowance. Existing origins
    /// remain editable; restoration retains their snapshots and does not refund allowance.
    pub fn replace(self: *State, span: Span, material: Material) !bool {
        const offset = try self.offsetOf(span.origin, span.length);
        if (span.history_weight == 0) return error.InvalidHistoryWeight;
        if (self.remembered(offset, span.reuse)) |index| {
            const entry = &self.history[index];
            // Growth beyond the first snapshot can expose unrelated original memory.
            // Shrinking, and growth back within the remembered extent, remain defined.
            if (entry.saved_length < span.length) return error.UnverifiedTerrainSpanGrowth;
            entry.restore_length = span.length;
        } else {
            if (self.history_limit) |limit| if (self.history_used >= limit) return false;
            const used = try std.math.add(usize, self.history_used, span.history_weight);
            const index = self.history_length;
            if (index == self.history.len) return error.TerrainHistoryFull;
            self.history[index] = .{ .offset = offset, .saved_length = span.length, .restore_length = span.length };
            @memcpy(self.saved[index * self.stride ..][0..span.length], self.materials[offset..][0..span.length]);
            self.history_length += 1;
            self.history_used = used;
        }
        @memset(self.materials[offset..][0..span.length], material);
        @memset(self.occupancy[offset..][0..span.length], material != .empty);
        return true;
    }

    pub fn restore(self: *State, origin: Address) !bool {
        const offset = try self.offsetOf(origin, 1);
        if (self.remembered(offset, .matching_origin)) |index| {
            const entry = self.history[index];
            const saved = self.saved[index * self.stride ..][0..entry.restore_length];
            @memcpy(self.materials[offset..][0..entry.restore_length], saved);
            for (saved, self.occupancy[offset..][0..entry.restore_length]) |material, *blocked| blocked.* = material != .empty;
            return true;
        }
        return false;
    }

    pub fn hashInto(self: *const State, hash: *std.hash.Wyhash) void {
        hash.update(&.{@intFromBool(self.history_limit != null)});
        for ([_]u64{ self.history_limit orelse 0, self.history_used }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        for (self.materials) |material| hash.update(&.{@intCast(@backingInt(material))});
        for (self.history[0..self.history_length], 0..) |entry, index| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, entry.offset)));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, entry.saved_length)));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, entry.restore_length)));
            for (self.saved[index * self.stride ..][0..entry.saved_length]) |material| hash.update(&.{@intCast(@backingInt(material))});
        }
    }
};

test "overlapping edits restore their first snapshots, not an assumed static background" {
    const id: geometry.RoomId = @fromBackingInt(51);
    const blocks = [_]bool{ false, false, false, false, false, false };
    const rooms = [_]geometry.Room{.{ .id = id, .columns = 6, .rows = 1, .width = 96, .height = 36, .first_interior_row = 0, .blocking = &blocks, .edges = .{ .up = .blocked, .down = .blocked, .left = .blocked, .right = .blocked } }};
    const initial: [6]Material = @splat(.empty);
    var state = try State.init(std.testing.allocator, .{ .rooms = &rooms }, &initial, .{});
    defer state.deinit();
    const a: Address = .{ .room = id, .column = 0, .row = 0 };
    const b: Address = .{ .room = id, .column = 2, .row = 0 };
    _ = try state.replace(.{ .origin = a, .length = 4 }, .solid);
    _ = try state.replace(.{ .origin = b, .length = 4 }, .restricted);
    try std.testing.expect(try state.restore(a));
    try std.testing.expect(try state.restore(b));
    try std.testing.expectEqualSlices(Material, &.{ .empty, .empty, .solid, .solid, .empty, .empty }, state.materials);
    _ = try state.replace(.{ .origin = a, .length = 4 }, .restricted);
    _ = try state.restore(a);
    try std.testing.expectEqualSlices(Material, &initial, state.materials);
    try std.testing.expect(!try state.map().blocked(id, 2, 0));
    try std.testing.expectEqual(@as(usize, 2), state.history_length);
    _ = try state.replace(.{ .origin = a, .length = 2 }, .solid);
    _ = try state.restore(a);
    try std.testing.expectError(error.UnverifiedTerrainSpanGrowth, state.replace(.{ .origin = a, .length = 5 }, .solid));
    try std.testing.expectEqualSlices(Material, &initial, state.materials);
    try std.testing.expectError(error.TerrainSpanOutsideRoom, state.replace(.{ .origin = b, .length = 5 }, .solid));
}

test "history admission preserves old origins and latest-only snapshots preserve intermediate terrain" {
    const id: geometry.RoomId = @fromBackingInt(7);
    const empty: [3]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = id, .columns = 3, .rows = 1, .width = 48, .height = 36, .first_interior_row = 0, .blocking = &empty, .edges = .{ .up = .blocked, .down = .blocked, .left = .blocked, .right = .blocked } }};
    const initial: [3]Material = @splat(.empty);
    var state = try State.init(std.testing.allocator, .{ .rooms = &rooms }, &initial, .{ .history_limit = 5 });
    defer state.deinit();
    const a: Span = .{ .origin = .{ .room = id, .column = 0, .row = 0 }, .length = 1, .history_weight = 3 };
    const b: Span = .{ .origin = .{ .room = id, .column = 1, .row = 0 }, .length = 1, .history_weight = 3 };
    const c: Span = .{ .origin = .{ .room = id, .column = 2, .row = 0 }, .length = 1, .history_weight = 3 };
    try std.testing.expect(try state.replace(a, .solid));
    try std.testing.expect(try state.map().blocked(id, 0, 0));
    try std.testing.expect(!rooms[0].blocking[0]); // Content remains immutable.
    try std.testing.expect(try state.replace(b, .restricted)); // Admission can cross the limit.
    try std.testing.expect(!try state.replace(c, .solid));
    try std.testing.expect(try state.restore(a.origin));
    try std.testing.expect(!try state.replace(c, .solid)); // Restoration does not refund history.
    try std.testing.expect(try state.replace(a, .restricted)); // A remembered origin still works.

    var layered = try State.init(std.testing.allocator, .{ .rooms = &rooms }, &initial, .{ .history_limit = 20 });
    defer layered.deinit();
    var latest = a;
    latest.reuse = .latest_only;
    _ = try layered.replace(latest, .solid);
    _ = try layered.replace(b, .restricted);
    _ = try layered.replace(latest, .empty);
    _ = try layered.restore(a.origin);
    try std.testing.expectEqual(Material.solid, try layered.at(a.origin));
    try std.testing.expectEqual(Material.restricted, try layered.at(b.origin));
}
