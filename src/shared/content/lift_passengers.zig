//! Recover loose-object boarding permissions and delivery latency at the import boundary.
const std = @import("std");
const rules = @import("rule_table.zig");
const props = @import("first_world_props.zig");
const runtime = @import("../lift_passengers.zig");
pub fn load(
    allocator: std.mem.Allocator,
    table: @import("placement.zig").Table,
    rule_bytes: []const u8,
    objects: props.Assets,
    first_item_index: u16,
    platform_sources: []const u16,
) ![]runtime.Binding {
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (objects.definitions, 0..) |definition, prop| {
        if (definition.behavior != .collectible) continue;
        const item = definition.behavior.collectible;
        const source = objects.item_sources[item.item.index - first_item_index];
        const record = try table.record(source);
        const group = try rules.group(rule_bytes, record.rule_group);
        const boards = for (0..group.count()) |i| {
            const r = group.at(i);
            if (r.source == record.initial_state and
                r.target == r.source and
                r.conditions[0].code == 34 and
                r.conditions[0].argument == 132 and
                r.conditions[1].code == 115 and
                r.conditions[1].argument == 8 and
                r.effect.code == 67) break true;
        } else false;
        const automatic = @import("quest_items.zig").teleporter(group) != null;
        if (!boards and !automatic) continue;
        for (platform_sources, 0..) |platform, index| try bindings.append(
            allocator,
            .{
                .prop = prop,
                .platform = index,
                .next_step = source <= platform,
                .automatic = automatic,
            },
        );
    }
    return bindings.toOwnedSlice(allocator);
}
