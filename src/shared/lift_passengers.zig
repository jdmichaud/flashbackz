//! Ownership and contact sampling for lift passengers. Stable prop slots identify loose
//! objects; inventory transfer ends their ride. Item boarding permissions come from content.
const std = @import("std");
const lifts = @import("lifts.zig");
const props = @import("world_props.zig");
const equipment = @import("equipment.zig");
const contacts = @import("contacts.zig");
const geometry = @import("geometry.zig");
const motion = @import("motion.zig");
pub const Binding = struct {
    prop: usize,
    platform: usize,
    next_step: bool,
    automatic: bool = false,
};
pub const State = struct {
    allocator: std.mem.Allocator,
    player: ?usize = null,
    acknowledged: ?usize = null,
    arrival: bool = false,
    candidate: ?usize = null,
    items: []?usize,
    pending: []?usize,
    occupancy: []lifts.Occupancy,
    automatic_ready: []bool,
    pub fn init(allocator: std.mem.Allocator, platform_count: usize, prop_count: usize) !State {
        const items = try allocator.alloc(?usize, prop_count);
        errdefer allocator.free(items);
        @memset(items, null);
        const pending = try allocator.alloc(?usize, prop_count);
        errdefer allocator.free(pending);
        @memset(pending, null);
        const occupancy = try allocator.alloc(lifts.Occupancy, platform_count);
        @memset(occupancy, .{});
        errdefer allocator.free(occupancy);
        const automatic_ready = try allocator.alloc(bool, prop_count);
        @memset(automatic_ready, false);
        return .{
            .allocator = allocator,
            .items = items,
            .pending = pending,
            .occupancy = occupancy,
            .automatic_ready = automatic_ready,
        };
    }
    pub fn deinit(self: *State) void {
        self.allocator.free(self.items);
        self.allocator.free(self.pending);
        self.allocator.free(self.occupancy);
        self.allocator.free(self.automatic_ready);
    }
    fn board(
        self: *State,
        prop: usize,
        platform: usize,
        objects: *props.World,
        equipment_: *const equipment.Loadout,
        platforms: *const lifts.World,
        definitions: []const lifts.Definition,
        map: geometry.Map,
    ) !void {
        if (!try objects.visible(prop, equipment_) or objects.objects[prop].flight != null) return;
        const layout: contacts.Layout = .{};
        if (!try layout.overlaps(
            map,
            objects.objects[prop].contact,
            platforms.instances[platform].footprint(definitions[platform]),
        )) return;
        self.items[prop] = platform;
        objects.objects[prop].active = false;
    }
    pub fn prepare(
        self: *State,
        map: geometry.Map,
        player: contacts.Footprint,
        platforms: *const lifts.World,
        definitions: []const lifts.Definition,
        objects: *props.World,
        equipment_: *const equipment.Loadout,
        bindings: []const Binding,
    ) !void {
        self.candidate = null;
        for (self.items, self.pending, 0..) |*owner, *pending, index| {
            if (!try objects.visible(
                index,
                equipment_,
            ) or objects.objects[index].flight != null) owner.* = null;
            if (pending.*) |platform| try self.board(
                index,
                platform,
                objects,
                equipment_,
                platforms,
                definitions,
                map,
            );
            pending.* = null;
        }
        for (
            objects.objects,
            objects.definitions,
            self.automatic_ready,
        ) |object, definition, *ready| {
            ready.* = definition.behavior == .collectible and
                object.flight == null and
                object.playback.exhausted(definition.behavior.collectible.idle);
        }
        for (bindings) |binding| if (binding.automatic and
            binding.next_step and
            self.automatic_ready[binding.prop] and
            objects.objects[binding.prop].active and
            try inView(
                map,
                player.room,
                objects.objects[binding.prop].room,
            ))
        {
            try self.board(
                binding.prop,
                binding.platform,
                objects,
                equipment_,
                platforms,
                definitions,
                map,
            );
        };
        const layout: contacts.Layout = .{};
        for (
            platforms.instances,
            definitions,
            self.occupancy,
            0..,
        ) |instance, definition, *occupancy, index| {
            const footprint = instance.footprint(definition);
            const touching = try layout.overlaps(map, footprint, player);
            occupancy.* = .{ .contacts = touching };
            if (touching) self.candidate = index;
            for (objects.objects) |object| {
                if (!object.contact_present or !try layout.overlaps(
                    map,
                    footprint,
                    object.contact,
                )) continue;
                occupancy.contacts = true;
            }
        }
    }
    /// Contact cells were sampled before motion, but item ownership is read when a
    /// platform decides to depart. A pickup earlier in this update already changed it.
    pub fn updateItemOccupancy(
        self: *State,
        map: geometry.Map,
        platforms: *const lifts.World,
        definitions: []const lifts.Definition,
        objects: *const props.World,
        equipment_: *const equipment.Loadout,
    ) !void {
        const layout: contacts.Layout = .{};
        for (
            platforms.instances,
            definitions,
            self.occupancy,
            0..,
        ) |instance, definition, *occupancy, index| {
            occupancy.unboarded_items = false;
            for (objects.objects, objects.definitions, 0..) |object, prop, j| {
                if (!object.contact_present or prop.behavior != .collectible) continue;
                if (!try layout.overlaps(
                    map,
                    instance.footprint(definition),
                    object.contact,
                )) continue;
                const attached = self.items[j] == index and
                    object.flight == null and
                    try objects.visible(
                        j,
                        equipment_,
                    );
                if (!attached) occupancy.unboarded_items = true;
            }
        }
    }
    pub fn includeActor(
        self: *State,
        map: geometry.Map,
        actor: contacts.Footprint,
        platforms: *const lifts.World,
        definitions: []const lifts.Definition,
    ) !void {
        const layout: contacts.Layout = .{};
        for (
            platforms.instances,
            definitions,
            self.occupancy,
        ) |instance, definition, *occupancy| if (try layout.overlaps(
            map,
            instance.footprint(definition),
            actor,
        )) {
            occupancy.contacts = true;
        };
    }
    /// Call after Conrad's movement, before the platform update. Acknowledgements and
    /// releases sent by a platform are therefore consumed on the following player update.
    pub fn playerUpdated(self: *State, boarded: bool, left: bool) void {
        if (boarded) self.player = self.acknowledged;
        if (left) self.player = null;
        self.acknowledged = null;
        self.arrival = false;
    }
    pub fn deliver(
        self: *State,
        platforms: *const lifts.World,
        definitions: []const lifts.Definition,
        bindings: []const Binding,
        map: geometry.Map,
        objects: *props.World,
        equipment_: *const equipment.Loadout,
        player: *motion.Pose,
        player_room: geometry.RoomId,
    ) !void {
        for (platforms.instances, 0..) |instance, index| {
            if (instance.board_player) self.acknowledged = index;
            if (self.player == index) {
                player.position.y +%= instance.displacement;
                if (instance.release_passengers) self.arrival = true;
            }
            if (instance.invite_items) for (bindings) |binding| {
                if (binding.platform != index or binding.automatic) continue;
                const layout: contacts.Layout = .{};
                if (!objects.objects[binding.prop].contact_present or !try layout.overlaps(
                    map,
                    objects.objects[binding.prop].contact,
                    instance.footprint(definitions[index]),
                )) continue;
                if (binding.next_step) self.pending[binding.prop] = index else try self.board(
                    binding.prop,
                    index,
                    objects,
                    equipment_,
                    platforms,
                    definitions,
                    map,
                );
            };
            for (self.items, objects.objects, 0..) |owner, *object, prop_index| {
                if (owner != index) continue;
                if (!try objects.visible(prop_index, equipment_) or object.flight != null) {
                    self.items[prop_index] = null;
                    continue;
                }
                object.pose.position.y +%= instance.displacement;
                // Stones keep their platform owner at arrival; release notifications
                // wake them but only pickup/drop removes their ownership.
                if (instance.release_passengers) object.active = true;
            }
        }
        for (bindings) |binding| if (binding.automatic and
            !binding.next_step and
            self.automatic_ready[binding.prop] and
            objects.objects[binding.prop].active and
            try inView(
                map,
                player_room,
                objects.objects[binding.prop].room,
            ))
        {
            try self.board(
                binding.prop,
                binding.platform,
                objects,
                equipment_,
                platforms,
                definitions,
                map,
            );
        };
    }
    fn inView(map: geometry.Map, player: geometry.RoomId, item: geometry.RoomId) !bool {
        const view = try map.room(player);
        return item == player or
            (view.edges.left == .room and view.edges.left.room == item) or
            (view.edges.right == .room and view.edges.right.room == item);
    }
    pub fn hashInto(self: State, hash: *std.hash.Wyhash) void {
        for ([_]?usize{ self.player, self.acknowledged, self.candidate }) |value| {
            const id: u64 = if (value) |i| i + 1 else 0;
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, id)));
        }
        hash.update(&.{@intFromBool(self.arrival)});
        for (self.items, self.pending) |owner, pending| for ([_]?usize{ owner, pending }) |value| {
            const id: u64 = if (value) |i| i + 1 else 0;
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, id)));
        };
    }
};
