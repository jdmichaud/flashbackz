//! Import direct inventory grants; these items need no artificial physical placement.
const std = @import("std");
const rules = @import("rule_table.zig");
const runtime = @import("../inventory_grants.zig");
pub const Spec = struct { idle: u16, signal: i16, kind: @import("../equipment.zig").Kind, object_kind: u8, starting: ?u16 = null, movie: ?@import("../story_cue.zig").Cue };
pub fn recognize(group: rules.Group) ?Spec {
    if (@import("credential_cards.zig").parcel(group)) |p| return .{ .idle = p.idle, .signal = p.grant_signal, .kind = .parcel, .object_kind = 3, .movie = .parcel_received };
    if (@import("credential_cards.zig").permit(group) != null) return .{ .idle = group.at(0).source, .signal = group.at(0).conditions[0].argument, .kind = .work_permit, .object_kind = 3, .movie = .permit_received };
    if (group.count() != 2 and group.count() != 3) return null;
    const a = group.at(0);
    const b = group.at(1);
    for ([_]rules.Rule{ a, b }) |r| if (r.source != a.source or r.target != a.source or r.next != 0 or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (a.conditions[0].code != 34 or a.conditions[1].code != 48 or a.conditions[1].argument != 0) return null;
    if (b.conditions[0].code != 0 or b.conditions[1].code != 0 or b.effect.code != 67) return null;
    if (group.count() == 2) {
        if (a.effect.code != 90 or a.effect.argument != 49) return null;
        return .{ .idle = a.source, .signal = a.conditions[0].argument, .kind = .anti_g_belt, .object_kind = 10, .movie = .anti_g_received };
    }
    const intro = group.at(2);
    if (a.effect.code != 0 or intro.source == a.source or intro.target != a.source or intro.next != 0 or intro.dx != 0 or intro.dy != 0 or intro.flags != 0 or intro.conditions[0].code != 0 or intro.conditions[1].code != 48 or intro.conditions[1].argument != 0 or intro.effect.code != 0) return null;
    return .{ .idle = a.source, .signal = a.conditions[0].argument, .kind = .force_field, .object_kind = 6, .starting = intro.source, .movie = null };
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
/// Register delayed grant outputs before the level freezes its complete circuit catalog.
pub fn outputs(allocator: std.mem.Allocator, table: @import("placement.zig").Table, bytes: []const u8, sources: []const u16, connections: *std.ArrayList(@import("first_world_props.zig").Connection)) !void {
    for (sources) |source| {
        const record = try table.record(source);
        const spec = @import("credential_cards.zig").parcel(try rules.group(bytes, record.rule_group)) orelse continue;
        const target = record.parameters[spec.followup_parameter];
        if (target < 0 or target >= table.count) return error.InvalidGrantFollowup;
        _ = try @import("first_world_props.zig").internConnection(allocator, connections, source, @intCast(target), spec.followup_signal);
    }
}
pub fn load(allocator: std.mem.Allocator, table: @import("placement.zig").Table, rule_bytes: []const u8, animations: []const u8, sources: []const u16, first_item: @import("../equipment.zig").ItemHandle, routes: []const @import("first_world_props.zig").Connection) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (sources, 0..) |source, index| {
        const record = try table.record(source);
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        const target = definitions.items.len;
        var followup: ?runtime.Followup = null;
        if (@import("credential_cards.zig").parcel(try rules.group(rule_bytes, record.rule_group))) |parcel| {
            var clip = try @import("animation.zig").decode(allocator, animations, parcel.received);
            defer clip.deinit();
            const recipient = record.parameters[parcel.followup_parameter];
            const circuit = for (routes) |route| {
                if (route.sender == source and route.recipient == recipient and route.message == parcel.followup_signal) break route.circuit;
            } else return error.MissingGrantFollowup;
            followup = .{ .steps = @intCast(clip.frames.len), .circuit = circuit };
        }
        table.register(@intCast(source), .inventory_grants);
        try definitions.append(allocator, .{ .item = .{ .index = first_item.index + @as(u16, @intCast(index)), .generation = first_item.generation }, .movie = spec.movie, .followup = followup });
        for (routes) |route| if (route.recipient == source and route.message == spec.signal) {
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = target, .next_step = route.sender >= source });
        };
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    return .{ .allocator = allocator, .definitions = owned, .bindings = try bindings.toOwnedSlice(allocator) };
}
