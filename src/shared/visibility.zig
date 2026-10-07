//! Ordered contact groups and authored visibility continuations. Entity references and
//! groups are game concepts; source addresses and binary records remain in the importer.
const std = @import("std");
const contacts = @import("contacts.zig");
const geometry = @import("geometry.zig");
const motion = @import("motion.zig");
pub const Entity = enum(u16) { _ };
pub const Group = enum(u7) { _ };
pub const Category = enum { player, enemy, interactive, other };
pub const Pick = union(enum) {
    group: ?Group,
    when_active: struct { entity: Entity, active: ?Group, inactive: ?Group },
};
pub const continuation_length = 64;
pub const Definition = struct {
    category: Category,
    priority: u16,
    initially_active: bool,
    initial_body: ?contacts.Footprint,
    wake_nearby: bool,
    continuation: [continuation_length]Pick,
};
pub const Observation = struct { body: ?contacts.Footprint, active: bool };
const Entry = struct { observation: Observation, room_order: u64 };
const Cell = contacts.Cell;
const Node = struct { entity: Entity, next: ?usize, valid: bool = true };
const Bucket = struct { cell: Cell, first: ?usize };
pub const World = struct {
    allocator: std.mem.Allocator,
    definitions: []const Definition,
    entries: []Entry,
    order: []Entity,
    nodes: []Node,
    groups: []Bucket,
    node_count: usize = 0,
    group_count: usize = 0,
    serial: u64,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, capacity: usize) !World {
        const entries = try allocator.alloc(Entry, definitions.len);
        errdefer allocator.free(entries);
        var serial: u64 = 0;
        for (entries, definitions) |*entry, definition| {
            entry.* = .{ .observation = .{ .body = definition.initial_body, .active = definition.initially_active }, .room_order = definition.priority };
            serial = @max(serial, @as(u64, definition.priority) + 1);
        }
        const order = try allocator.alloc(Entity, definitions.len);
        errdefer allocator.free(order);
        const nodes = try allocator.alloc(Node, capacity);
        errdefer allocator.free(nodes);
        @memset(nodes, .{ .entity = @fromBackingInt(0), .next = null, .valid = false });
        const groups = try allocator.alloc(Bucket, capacity);
        for (groups) |*group| group.* = .{ .cell = undefined, .first = null };
        return .{ .allocator = allocator, .definitions = definitions, .entries = entries, .order = order, .nodes = nodes, .groups = groups, .serial = serial };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.order);
        self.allocator.free(self.nodes);
        self.allocator.free(self.groups);
    }
    pub fn observe(self: *World, entity: Entity, observation: Observation) void {
        const entry = &self.entries[@backingInt(entity)];
        const previous_room = if (entry.observation.body) |body| body.room else null;
        const room = if (observation.body) |body| body.room else null;
        if (self.initialized and previous_room != room) {
            entry.room_order = self.serial;
            self.serial += 1;
        }
        entry.observation = observation;
    }
    pub fn setActive(self: *World, entity: Entity, active: bool) void {
        self.entries[@backingInt(entity)].observation.active = active;
    }
    fn earlier(self: World, a: Entity, b: Entity, view_room: geometry.RoomId) bool {
        const left = self.entries[@backingInt(a)];
        const right = self.entries[@backingInt(b)];
        const left_here = if (left.observation.body) |body| body.room == view_room else false;
        const right_here = if (right.observation.body) |body| body.room == view_room else false;
        if (left_here != right_here) return left_here;
        return if (left_here) left.room_order > right.room_order else self.definitions[@backingInt(a)].priority < self.definitions[@backingInt(b)].priority;
    }
    pub fn rebuild(self: *World, map: geometry.Map, view_room: geometry.RoomId) !void {
        self.node_count = 0;
        self.group_count = 0;
        for (self.entries, self.definitions) |*entry, definition| if (definition.wake_nearby) {
            if (entry.observation.body) |body| {
                const near = try @import("activation.zig").around(map, view_room, body.room, body.position.y);
                if (near.wake) entry.observation.active = true;
            }
        };
        for (self.order, 0..) |*entity, index| entity.* = @fromBackingInt(@as(u16, @intCast(index)));
        const Context = struct {
            world: *const World,
            room: geometry.RoomId,
            fn less(context: @This(), a: Entity, b: Entity) bool {
                return context.world.earlier(a, b, context.room);
            }
        };
        std.mem.sort(Entity, self.order, Context{ .world = self, .room = view_room }, Context.less);
        const layout: contacts.Layout = .{};
        for (self.order) |entity| {
            const entry = &self.entries[@backingInt(entity)];
            const body = entry.observation.body orelse continue;
            if (body.room != view_room and !entry.observation.active) continue;
            for (0..body.width) |offset| {
                if (self.node_count == self.nodes.len) break;
                const node_index = self.node_count;
                self.node_count += 1;
                const cell = try layout.cell(map, body.room, .{ .x = body.position.x +% @as(i16, @intCast(offset)) *% 16, .y = body.position.y }) orelse break;
                const group_index = for (self.groups[0..self.group_count], 0..) |group, index| {
                    if (std.meta.eql(group.cell, cell)) break index;
                } else fresh: {
                    const index = self.group_count;
                    self.group_count += 1;
                    self.groups[index] = .{ .cell = cell, .first = null };
                    break :fresh index;
                };
                self.nodes[node_index] = .{ .entity = entity, .next = self.groups[group_index].first };
                self.groups[group_index].first = node_index;
            }
        }
        self.initialized = true;
    }
    fn select(self: World, pick: Pick) ?Group {
        return switch (pick) {
            .group => |group| group,
            .when_active => |choice| if (self.entries[@backingInt(choice.entity)].observation.active) choice.active else choice.inactive,
        };
    }
    const Cursor = union(enum) { spatial: i32, continuation: struct { entity: Entity, distance: usize } };
    fn move(cursor: *Cursor, delta: i32) void {
        switch (cursor.*) {
            .spatial => |*index| index.* += delta,
            .continuation => |*route| route.distance += @intCast(-delta),
        }
    }
    fn occupants(self: World, cursor: Cursor, rooms: [3]?geometry.RoomId) ?usize {
        const group_index: usize = switch (cursor) {
            .spatial => |index| blk: {
                if (index < 0 or index >= 144) return null;
                const room = rooms[@intCast(@divTrunc(index, 48))] orelse return null;
                const local = @mod(index, 48);
                for (self.groups[0..self.group_count], 0..) |group, i| {
                    if (group.cell.room == room and group.cell.row == @divTrunc(local, 16) and group.cell.column == @mod(local, 16)) break :blk i;
                }
                return null;
            },
            .continuation => |route| blk: {
                if (route.distance == 0 or route.distance > continuation_length) return null;
                const selected = self.select(self.definitions[@backingInt(route.entity)].continuation[route.distance - 1]) orelse return null;
                break :blk @backingInt(selected);
            },
        };
        if (group_index >= self.groups.len or group_index >= 128) return null;
        return self.groups[group_index].first;
    }
    pub fn touching(self: World, map: geometry.Map, observer: Entity, category: Category) !?Entity {
        const body = self.entries[@backingInt(observer)].observation.body orelse return null;
        const layout: contacts.Layout = .{};
        for (0..body.width) |offset| {
            const cell = try layout.cell(map, body.room, .{ .x = body.position.x +% @as(i16, @intCast(offset)) *% 16, .y = body.position.y }) orelse break;
            var next = for (self.groups[0..self.group_count]) |group| {
                if (std.meta.eql(group.cell, cell)) break group.first;
            } else null;
            var visited: usize = 0;
            while (next) |index| {
                if (index >= self.nodes.len or !self.nodes[index].valid or visited >= self.nodes.len) break;
                visited += 1;
                const node = self.nodes[index];
                next = node.next;
                if (node.entity != observer and self.definitions[@backingInt(node.entity)].category == category) return node.entity;
            }
        }
        return null;
    }

    pub fn scan(self: World, map: geometry.Map, view_room: geometry.RoomId, observer: Entity, pose: motion.Pose, observer_room: geometry.RoomId, category: Category, distance: u8, behind: bool) !?u8 {
        const view = try map.room(view_room);
        const rooms: [3]?geometry.RoomId = .{ if (view.edges.left == .room) view.edges.left.room else null, view_room, if (view.edges.right == .room) view.edges.right.room else null };
        var sector: i32 = if (rooms[1] == observer_room) 1 else if (rooms[0] == observer_room) 0 else if (rooms[2] == observer_room) 2 else return null;
        var column: i16 = (pose.position.x +% 8) >> 4;
        const band = @divTrunc(pose.position.y, 72);
        if (band < 0 or band > 2) return null;
        const left = (pose.facing == .left) != behind;
        var cursor: Cursor = .{ .spatial = sector * 48 + @as(i32, band) * 16 + column + @as(i32, if (left) 0 else 1) };
        var last_cell = cursor;
        var terrain_room = observer_room;
        for (1..@as(usize, @min(distance, 16)) + 1) |step| {
            column += if (left) @as(i16, -1) else 1;
            if (column < 0) {
                sector -= 1;
                if (sector < 0) return null;
                column += 16;
                const edge = (try map.room(terrain_room)).edges.left;
                terrain_room = if (edge == .room) edge.room else return null;
                cursor = last_cell;
                move(&cursor, -31);
            } else if (column >= 16) {
                sector += 1;
                if (sector >= 3) return null;
                column -= 16;
                const edge = (try map.room(terrain_room)).edges.right;
                terrain_room = if (edge == .room) edge.room else return null;
                cursor = last_cell;
                move(&cursor, 32);
            }
            move(&cursor, if (left) -1 else 1);
            last_cell = cursor;
            var next = self.occupants(cursor, rooms);
            var visited: usize = 0;
            while (next) |index| {
                if (index >= self.nodes.len or !self.nodes[index].valid or visited >= self.nodes.len) break;
                visited += 1;
                const node = self.nodes[index];
                next = node.next;
                if (node.entity == observer or !self.entries[@backingInt(node.entity)].observation.active) continue;
                if (self.definitions[@backingInt(node.entity)].category == category) return @intCast(step);
                if (left) cursor = .{ .continuation = .{ .entity = node.entity, .distance = 0 } };
            }
            if (try map.blocked(terrain_room, column, band * 2 + 1)) return null;
        }
        return null;
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.entries) |entry| {
            hash.update(&.{@intFromBool(entry.observation.active)});
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, entry.room_order)));
            if (entry.observation.body) |body| {
                for ([_]u16{ @backingInt(body.room), @bitCast(body.position.x), @bitCast(body.position.y), body.width }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, value)));
            } else hash.update(&.{ 0, 0 });
        }
        for (self.nodes) |node| {
            hash.update(&.{@intFromBool(node.valid)});
            if (node.valid) for ([_]u32{ @backingInt(node.entity), if (node.next) |next| @intCast(next + 1) else 0 }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
        for (self.groups) |group| {
            const first: u32 = if (group.first) |index| @intCast(index + 1) else 0;
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, first)));
        }
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.serial)));
    }
};

test "visibility redirects use entity conditions while terrain still limits the scan" {
    const room: geometry.RoomId = @fromBackingInt(81);
    const empty: [16 * 7]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = room, .columns = 16, .rows = 7, .width = 256, .height = 216, .blocking = &empty, .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked } }};
    const map: geometry.Map = .{ .rooms = &rooms };
    var definitions: [4]Definition = undefined;
    for (&definitions, [_]i16{ 80, 32, 32, 112 }, [_]u16{ 50, 10, 20, 60 }, [_]Category{ .enemy, .player, .other, .enemy }) |*definition, x, priority, category| {
        definition.* = .{ .category = category, .priority = priority, .initially_active = true, .initial_body = .{ .room = room, .position = .{ .x = x, .y = 70 } }, .wake_nearby = false, .continuation = @splat(.{ .group = null }) };
    }
    definitions[2].continuation[0] = .{ .when_active = .{ .entity = @fromBackingInt(1), .active = @fromBackingInt(0), .inactive = null } };
    var world = try World.init(std.testing.allocator, &definitions, 256);
    defer world.deinit();
    try world.rebuild(map, room);
    const observer: Entity = @fromBackingInt(0);
    const pose: motion.Pose = .{ .position = .{ .x = 80, .y = 70 }, .facing = .left, .visual = .{ .id = @fromBackingInt(1) } };
    try std.testing.expectEqual(@as(?u8, 4), try world.scan(map, room, observer, pose, room, .enemy, 8, false));
    world.setActive(@fromBackingInt(1), false);
    try std.testing.expectEqual(@as(?u8, null), try world.scan(map, room, observer, pose, room, .enemy, 8, false));
    world.setActive(@fromBackingInt(1), true);
    var blocked = empty;
    blocked[16 + 2] = true;
    var blocked_room = rooms;
    blocked_room[0].blocking = &blocked;
    try std.testing.expectEqual(@as(?u8, null), try world.scan(.{ .rooms = &blocked_room }, room, observer, pose, room, .enemy, 8, false));
}
