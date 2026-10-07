//! Circuit-triggered inventory rewards, with no invented world placement for offstage items.
const std = @import("std");
const equipment = @import("equipment.zig");
pub const Followup = struct { steps: u16, circuit: @import("world_props.zig").CircuitId };
pub const Definition = struct {
    followup: ?Followup = null,
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
    followup_in: []?u16,
    pulses: []@import("world_props.zig").CircuitId,
    pulse_count: usize = 0,
    movie: ?@import("story_cue.zig").Cue = null,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const pending = try allocator.alloc(bool, count);
        errdefer allocator.free(pending);
        @memset(pending, false);
        const applied = try allocator.alloc(bool, count);
        errdefer allocator.free(applied);
        @memset(applied, false);
        const followup_in = try allocator.alloc(?u16, count);
        errdefer allocator.free(followup_in);
        @memset(followup_in, null);
        return .{ .allocator = allocator, .pending = pending, .applied = applied, .followup_in = followup_in, .pulses = try allocator.alloc(@import("world_props.zig").CircuitId, count) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.pending);
        self.allocator.free(self.applied);
        self.allocator.free(self.followup_in);
        self.allocator.free(self.pulses);
    }
    fn grant(self: *World, definitions: []const Definition, index: usize, items: *equipment.Loadout) !void {
        if (self.applied[index]) return;
        try items.grant(definitions[index].item);
        self.applied[index] = true;
        if (definitions[index].followup) |followup| self.followup_in[index] = followup.steps;
        if (definitions[index].movie) |movie| self.movie = movie;
    }
    pub fn beginStep(self: *World, definitions: []const Definition, items: *equipment.Loadout) !void {
        @memset(self.applied, false);
        self.movie = null;
        self.pulse_count = 0;
        for (self.followup_in, definitions) |*remaining, definition| if (remaining.*) |steps| {
            if (steps <= 1) {
                self.pulses[self.pulse_count] = definition.followup.?.circuit;
                self.pulse_count += 1;
                remaining.* = null;
            } else remaining.* = steps - 1;
        };
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
        for (self.followup_in) |remaining| {
            const value: u32 = if (remaining) |steps| @as(u32, steps) + 1 else 0;
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
    }
};
