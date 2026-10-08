//! One-shot event barriers release a circuit after the required number of signal updates.
//! Multiple pulses in one update coalesce, matching the authored encounter relays.
const std = @import("std");
const Circuit = world_props.CircuitId;
const world_props = @import("world_props.zig");
pub const Definition = struct { required_updates: u8, output: Circuit };
pub const Binding = struct { circuit: Circuit, target: usize, next_step: bool };
pub const State = struct {
    received: u8 = 0,
    ready: bool = false,
    pending: bool = false,
    released: bool = false,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    barriers: []State,
    pulses: []Circuit,
    pulse_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const barriers = try allocator.alloc(State, count);
        errdefer allocator.free(barriers);
        @memset(barriers, .{});
        return .{
            .allocator = allocator,
            .barriers = barriers,
            .pulses = try allocator.alloc(Circuit, count),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.barriers);
        self.allocator.free(self.pulses);
    }
    pub fn beginStep(self: *World) void {
        self.pulse_count = 0;
        for (self.barriers) |*barrier| {
            barrier.ready = barrier.pending;
            barrier.pending = false;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const Circuit) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            const barrier = &self.barriers[binding.target];
            if (binding.next_step) barrier.pending = true else barrier.ready = true;
        };
    }
    pub fn advance(self: *World, definitions: []const Definition) void {
        for (self.barriers, definitions) |*barrier, definition| {
            if (barrier.released or !barrier.ready) continue;
            barrier.ready = false;
            barrier.received += 1;
            if (barrier.received >= definition.required_updates) {
                barrier.released = true;
                self.pulses[self.pulse_count] = definition.output;
                self.pulse_count += 1;
            }
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.barriers) |barrier| hash.update(&.{
            barrier.received,
            @intFromBool(barrier.ready),
            @intFromBool(barrier.pending),
            @intFromBool(barrier.released),
        });
    }
};

test "encounter barrier coalesces simultaneous pulses and releases once after deferred delivery" {
    const incoming: Circuit = @fromBackingInt(5);
    const outgoing: Circuit = @fromBackingInt(8);
    const definitions = [_]Definition{.{ .required_updates = 2, .output = outgoing }};
    var world = try World.init(std.testing.allocator, 1);
    defer world.deinit();
    const immediate = [_]Binding{.{ .circuit = incoming, .target = 0, .next_step = false }};
    const deferred = [_]Binding{.{ .circuit = incoming, .target = 0, .next_step = true }};
    world.beginStep();
    world.route(&immediate, &.{ incoming, incoming });
    world.advance(&definitions);
    try std.testing.expectEqual(@as(u8, 1), world.barriers[0].received);
    try std.testing.expectEqual(@as(usize, 0), world.pulse_count);
    world.beginStep();
    world.route(&deferred, &.{incoming});
    world.advance(&definitions);
    try std.testing.expectEqual(@as(usize, 0), world.pulse_count);
    world.beginStep();
    world.advance(&definitions);
    try std.testing.expectEqualSlices(Circuit, &.{outgoing}, world.pulses[0..world.pulse_count]);
    world.beginStep();
    world.route(&immediate, &.{incoming});
    world.advance(&definitions);
    try std.testing.expectEqual(@as(usize, 0), world.pulse_count);
}
