//! Circuit-triggered inventory rewards, with no invented world placement for offstage items.
const std = @import("std");
const equipment = @import("equipment.zig");
pub const Definition = struct {
    item: equipment.ItemHandle,
    movie: ?@import("story_cue.zig").Cue,
};
pub const Binding = struct {
    circuit: @import("world_props.zig").CircuitId,
    target: usize,
    next_step: bool,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    pending: []bool,
    applied: []bool,
    movie: ?@import("story_cue.zig").Cue = null,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const pending = try allocator.alloc(bool, count);
        errdefer allocator.free(pending);
        @memset(pending, false);
        const applied = try allocator.alloc(bool, count);
        @memset(applied, false);
        return .{ .allocator = allocator, .pending = pending, .applied = applied };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.pending);
        self.allocator.free(self.applied);
    }
    fn grant(self: *World, definitions: []const Definition, index: usize, items: *equipment.Loadout) !void {
        if (self.applied[index]) return;
        try items.grant(definitions[index].item);
        self.applied[index] = true;
        if (definitions[index].movie) |movie| self.movie = movie;
    }
    pub fn beginStep(self: *World, definitions: []const Definition, items: *equipment.Loadout) !void {
        @memset(self.applied, false);
        self.movie = null;
        for (self.pending, 0..) |*pending, index| if (pending.*) {
            pending.* = false;
            try self.grant(definitions, index, items);
        };
    }
    pub fn deliver(self: *World, definitions: []const Definition, bindings: []const Binding, pulses: []const @import("world_props.zig").CircuitId, items: *equipment.Loadout) !void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.pending[binding.target] = true else try self.grant(definitions, binding.target, items);
        };
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.pending) |pending| hash.update(&.{@intFromBool(pending)});
    }
};
