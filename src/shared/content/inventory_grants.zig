//! Import direct inventory grants; these items need no artificial physical placement.
const std = @import("std");
const rules = @import("rule_table.zig");
const runtime = @import("../inventory_grants.zig");
pub const Spec = struct { idle: u16, signal: i16 };
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 2) return null;
    const a = group.at(0);
    const b = group.at(1);
    for ([_]rules.Rule{ a, b }) |r| if (r.source != a.source or r.target != a.source or r.next != 0 or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (a.conditions[0].code != 34 or a.conditions[1].code != 48 or a.conditions[1].argument != 0 or a.effect.code != 90 or a.effect.argument != 49) return null;
    if (b.conditions[0].code != 0 or b.conditions[1].code != 0 or b.effect.code != 67) return null;
    return .{ .idle = a.source, .signal = a.conditions[0].argument };
}
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    bindings: []runtime.Binding,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
    }
};
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, rule_bytes: []const u8, sources: []const u16, first_item: @import("../equipment.zig").ItemHandle, routes: []const @import("first_world_props.zig").Connection) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (sources, 0..) |source, index| {
        const record = try table.record(source);
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        const target = definitions.items.len;
        try definitions.append(allocator, .{ .item = .{ .index = first_item.index + @as(u16, @intCast(index)), .generation = first_item.generation }, .movie = .anti_g_received });
        for (routes) |route| if (route.recipient == source and route.message == spec.signal) {
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = target, .next_step = route.sender >= source });
        };
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    return .{ .allocator = allocator, .definitions = owned, .bindings = try bindings.toOwnedSlice(allocator) };
}
