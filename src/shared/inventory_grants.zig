//! Circuit-triggered inventory rewards, with no invented world placement for offstage items.
const std = @import("std");
const equipment = @import("equipment.zig");
const story_cue = @import("story_cue.zig");
const world_props = @import("world_props.zig");
pub const Followup = struct { steps: u16, circuit: world_props.CircuitId };
pub const Definition = struct {
    followup: ?Followup = null,
    on_grant: ?world_props.CircuitId = null,
    on_consumed: ?world_props.CircuitId = null,
    item: equipment.ItemHandle,
    movie: ?story_cue.Cue,
};
pub const Binding = struct {
    circuit: world_props.CircuitId,
    target: usize,
    next_step: bool,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    pending: []bool,
    applied: []bool,
    waiting_consumption: []bool,
    followup_in: []?u16,
    pulses: []world_props.CircuitId,
    pulse_count: usize = 0,
    movie: ?story_cue.Cue = null,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const pending = try allocator.alloc(bool, count);
        errdefer allocator.free(pending);
        @memset(pending, false);
        const applied = try allocator.alloc(bool, count);
        errdefer allocator.free(applied);
        @memset(applied, false);
        const waiting_consumption = try allocator.alloc(bool, count);
        errdefer allocator.free(waiting_consumption);
        @memset(waiting_consumption, false);
        const followup_in = try allocator.alloc(?u16, count);
        errdefer allocator.free(followup_in);
        @memset(followup_in, null);
        return .{
            .allocator = allocator,
            .pending = pending,
            .applied = applied,
            .waiting_consumption = waiting_consumption,
            .followup_in = followup_in,
            .pulses = try allocator.alloc(world_props.CircuitId, count * 3),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.pending);
        self.allocator.free(self.applied);
        self.allocator.free(self.waiting_consumption);
        self.allocator.free(self.followup_in);
        self.allocator.free(self.pulses);
    }
    fn grant(
        self: *World,
        definitions: []const Definition,
        index: usize,
        items: *equipment.Loadout,
    ) !void {
        if (self.applied[index]) return;
        try items.grant(definitions[index].item);
        self.applied[index] = true;
        if (definitions[index].on_grant) |circuit| {
            self.pulses[self.pulse_count] = circuit;
            self.pulse_count += 1;
        }
        self.waiting_consumption[index] = definitions[index].on_consumed != null;
        if (definitions[index].followup) |followup| self.followup_in[index] = followup.steps;
        if (definitions[index].movie) |movie| self.movie = movie;
    }
    pub fn beginStep(
        self: *World,
        definitions: []const Definition,
        items: *equipment.Loadout,
    ) !void {
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
    pub fn deliver(
        self: *World,
        definitions: []const Definition,
        bindings: []const Binding,
        pulses: []const world_props.CircuitId,
        items: *equipment.Loadout,
    ) !void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            if (binding.next_step) self.pending[binding.target] = true else try self.grant(
                definitions,
                binding.target,
                items,
            );
        };
    }
    pub fn observeConsumptions(
        self: *World,
        definitions: []const Definition,
        items: *const equipment.Loadout,
    ) !void {
        for (
            self.waiting_consumption,
            definitions,
        ) |*waiting, definition| if (waiting.* and
            (try items.item(definition.item)).state == .consumed)
        {
            self.pulses[self.pulse_count] = definition.on_consumed.?;
            self.pulse_count += 1;
            waiting.* = false;
        };
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.pending) |pending| hash.update(&.{@intFromBool(pending)});
        for (self.waiting_consumption) |waiting| hash.update(&.{@intFromBool(waiting)});
        for (self.followup_in) |remaining| {
            const value: u32 = if (remaining) |steps| @as(u32, steps) + 1 else 0;
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
    }
};
