//! Contact gates request a level transition; the application owns the scene replacement.
const std = @import("std");
const contacts = @import("contacts.zig");
const geometry = @import("geometry.zig");
const equipment = @import("equipment.zig");
pub const Destination = @import("content/level.zig").Id;
pub const Definition = struct {
    footprint: contacts.Footprint,
    required_item: equipment.Kind,
    destination: Destination,
    cadence: u16,
    initially_active: bool,
    wake_nearby: bool,
};
const State = struct { elapsed: u16 = 0, active: bool };
pub const World = struct {
    allocator: std.mem.Allocator,
    gates: []State,
    requested: ?Destination = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const gates = try allocator.alloc(State, definitions.len);
        for (gates, definitions) |*gate, definition| gate.* = .{ .active = definition.initially_active };
        return .{ .allocator = allocator, .gates = gates };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.gates);
    }
    pub fn advance(self: *World, definitions: []const Definition, map: geometry.Map, player: contacts.Footprint, items: *const equipment.Loadout) !void {
        const layout: contacts.Layout = .{};
        for (self.gates, definitions) |*gate, definition| {
            const near = try @import("activation.zig").around(map, player.room, definition.footprint.room, definition.footprint.position.y);
            if (definition.wake_nearby and near.wake) gate.active = true;
            if (!gate.active) continue;
            if (gate.elapsed >= definition.cadence) {
                gate.elapsed = 0;
                if (items.carries(definition.required_item) and try layout.overlaps(map, definition.footprint, player)) self.requested = definition.destination;
                if (!near.same and !(definition.wake_nearby and near.near)) gate.active = false;
            }
            gate.elapsed += 1;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.gates) |gate| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, gate.elapsed)));
            hash.update(&.{@intFromBool(gate.active)});
        }
        hash.update(&.{if (self.requested) |destination| @as(u8, @intCast(@backingInt(destination))) + 1 else 0});
    }
};
