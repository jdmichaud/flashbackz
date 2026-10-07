//! Recognize complete encounter-relay families and resolve their circuit endpoints.
const std = @import("std");
const runtime = @import("../event_barriers.zig");
const rules = @import("rule_table.zig");
const placement = @import("placement.zig");
const connections = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    /// Temporary provenance, used only while the content pack binds all producers.
    sources: []u16,
    signals: []i16,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.sources);
        self.allocator.free(self.signals);
    }
    pub fn bind(self: Assets, routes: []const connections.Connection) ![]runtime.Binding {
        var bindings: std.ArrayList(runtime.Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        for (self.sources, self.signals, 0..) |source, signal, index| for (routes) |route| {
            if (route.recipient == source and route.message == signal) try bindings.append(self.allocator, .{ .circuit = route.circuit, .target = index, .next_step = route.sender >= source });
        };
        return bindings.toOwnedSlice(self.allocator);
    }
};
const Spec = struct { waiting: u16, armed: u16, signal: i16, output: i16 };
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 4) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    if (a.source != b.source or b.target != a.source or c.source != a.target or d.source != a.target or c.target != a.target or d.target != a.target or a.source == a.target) return null;
    if (a.next != 2 or b.next != 0 or c.next != 2 or d.next != 2) return null;
    for ([_]rules.Rule{ a, b, c, d }) |rule| if (rule.dx != 0 or rule.dy != 0 or rule.flags != 0) return null;
    if (a.conditions[0].code != 34 or a.conditions[1].code != 0 or a.effect.code != 0 or b.conditions[0].code != 0 or b.conditions[1].code != 0 or b.effect.code != 67 or c.conditions[0].code != 34 or c.conditions[0].argument != a.conditions[0].argument or c.conditions[1].code != 35 or c.effect.code != 75 or d.conditions[0].code != 0 or d.conditions[1].code != 0 or d.effect.code != 67) return null;
    return .{ .waiting = a.source, .armed = a.target, .signal = a.conditions[0].argument, .output = c.conditions[1].argument };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, difficulty: @import("../settings.zig").Difficulty, routes: *std.ArrayList(connections.Connection)) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var sources: std.ArrayList(u16) = .empty;
    errdefer sources.deinit(allocator);
    var signals: std.ArrayList(i16) = .empty;
    errdefer signals.deinit(allocator);
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.kind != 0 or record.room < 64 or record.initial_state != spec.waiting or record.flags & 1 == 0) return error.UnsupportedEventBarrier;
        for ([_]u16{ spec.waiting, spec.armed }) |state| {
            var clip = try @import("animation.zig").decode(allocator, animations, state);
            defer clip.deinit();
            if (clip.frames.len != 1 or clip.sound != null) return error.UnsupportedBarrierTiming;
            switch (clip.frames[0]) {
                .hold => {},
                .frame => |frame| if (frame.dx != 0 or frame.dy != 0) return error.MovingEventBarrier,
            }
        }
        const target = record.parameters[0];
        if (target < 0 or target >= table.count) return error.InvalidBarrierOutput;
        const output = try connections.internConnection(allocator, routes, @intCast(index), @intCast(target), spec.output);
        table.register(@intCast(index), .event_barriers);
        try definitions.append(allocator, .{ .required_updates = 2, .output = output });
        try sources.append(allocator, @intCast(index));
        try signals.append(allocator, spec.signal);
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_sources = try sources.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{ .allocator = allocator, .definitions = owned, .sources = owned_sources, .signals = try signals.toOwnedSlice(allocator) };
}
