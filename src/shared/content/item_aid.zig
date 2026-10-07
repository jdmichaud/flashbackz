//! Recover the full item-aid civilian family into attention/dialogue/reward definitions.
const std = @import("std");
const runtime = @import("../actors/item_aid.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const props = @import("first_world_props.zig");
pub const Spec = struct { states: [14]u16, range: i16, wait: i16, end: i16, call: i16, request: i16, thanks: i16, accept: i16, return_parameter: u2, return_signal: i16, reward_parameter: u2, reward_signal: i16 };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    bindings: []runtime.Binding,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.bindings);
    }
};
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 26) return null;
    var r: [26]rules.Rule = undefined;
    const codes = [_][3]u8{ .{ 76, 0, 0 }, .{ 0, 0, 67 }, .{ 0, 0, 123 }, .{ 0, 64, 0 }, .{ 77, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 34, 0, 123 }, .{ 34, 35, 36 }, .{ 80, 0, 0 }, .{ 0, 64, 0 }, .{ 62, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 64, 0 }, .{ 63, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 64, 0 }, .{ 77, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 34, 35, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 75 }, .{ 0, 123, 36 }, .{ 0, 0, 0 } };
    const next = [_]u16{ 2, 0, 3, 6, 0, 3, 7, 21, 24, 7, 7, 12, 13, 6, 16, 13, 17, 20, 0, 17, 7, 24, 7, 23, 25, 23 };
    const source = [_]usize{ 0, 0, 2, 3, 3, 3, 6, 7, 7, 7, 7, 7, 12, 13, 13, 13, 16, 17, 17, 17, 20, 21, 21, 23, 24, 25 };
    for (&r, codes, next, source, 0..) |*row, operations, target, origin, i| {
        row.* = group.at(i);
        if (row.source != group.at(origin).source or row.target != group.at(target).source or row.next != target or row.dx != 0 or row.dy != 0 or row.flags != 0) return null;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, operations) |operation, code| if (operation.code != code) return null;
    }
    for ([_]usize{ 0, 4, 18 }) |i| if (r[i].conditions[0].argument != 0) return null;
    if (r[7].conditions[0].argument != 30 or r[9].conditions[0].argument != 1 or r[8].conditions[0].argument != r[21].conditions[0].argument or r[8].conditions[1].argument != r[21].conditions[1].argument or r[8].effect.argument != r[24].effect.argument) return null;
    const range = r[3].conditions[1].argument;
    for ([_]usize{ 3, 10, 13, 17 }) |i| if (r[i].conditions[0].argument != 1 or r[i].conditions[1].argument != range) return null;
    for ([_]i16{ r[2].effect.argument, r[7].effect.argument, r[24].conditions[1].argument }) |id| if (id < 0) return null;
    return .{ .states = .{ r[0].source, r[2].source, r[3].source, r[6].source, r[7].source, r[12].source, r[13].source, r[16].source, r[17].source, r[20].source, r[21].source, r[24].source, r[25].source, r[23].source }, .range = range, .wait = r[11].conditions[0].argument, .end = r[14].conditions[0].argument, .call = r[2].effect.argument, .request = r[7].effect.argument, .thanks = r[24].conditions[1].argument, .accept = r[8].conditions[0].argument, .return_parameter = 0, .return_signal = r[8].conditions[1].argument, .reward_parameter = 1, .reward_signal = r[8].effect.argument };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: *std.ArrayList(props.Connection), item_sources: []const u16, first_item: @import("../equipment.zig").ItemHandle, supplies: []const @import("../equipment.zig").Definition, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.label);
        definitions.deinit(allocator);
    }
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer profiles.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var groups: std.AutoHashMap(u16, usize) = .init(allocator);
    defer groups.deinit();
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 3 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0] or record.contact_icon == 0) return error.UnsupportedCivilianStart;
        const profile = groups.get(record.rule_group) orelse fresh: {
            var result: runtime.Profile = .{ .clips = undefined, .attention_cells = @intCast(@max(1, @min(@abs(spec.range), 16))), .look_behind = spec.range < 0, .wait_steps = spec.wait, .wait_end = spec.end, .call_message = @fromBackingInt(@as(u16, @intCast(spec.call))), .request_message = @fromBackingInt(@as(u16, @intCast(spec.request))), .thanks_message = @fromBackingInt(@as(u16, @intCast(spec.thanks))) };
            for (spec.states, &result.clips) |state, *destination| {
                var source = try animation.decode(allocator, animations, state);
                defer source.deinit();
                var clip = try source.resolve(allocator, resolver);
                errdefer clip.deinit();
                try clips.append(allocator, clip);
                destination.* = clip.clip();
            }
            const index = profiles.items.len;
            try profiles.append(allocator, result);
            try groups.put(record.rule_group, index);
            break :fresh index;
        };
        const return_target = record.parameters[spec.return_parameter];
        const reward_target = record.parameters[spec.reward_parameter];
        if (return_target < 0 or return_target >= table.count or reward_target < 0 or reward_target >= table.count) return error.InvalidCivilianConnection;
        const return_item = try props.internConnection(allocator, routes, @intCast(i), @intCast(return_target), spec.return_signal);
        const reward = try props.internConnection(allocator, routes, @intCast(i), @intCast(reward_target), spec.reward_signal);
        for (item_sources, 0..) |source, index| {
            const item = try table.record(source);
            const offer = @import("quest_items.zig").teleporter(try rules.group(rule_bytes, item.rule_group)) orelse continue;
            if (item.parameters[0] != record.kind or offer.signal != spec.accept) continue;
            try bindings.append(allocator, .{ .item = .{ .index = first_item.index + @as(u16, @intCast(index)), .generation = first_item.generation }, .actor = definitions.items.len, .next_step = source >= i });
        }
        // Wallets offer the same signal after a minimum-value check. The civilian
        // decides the response, so no credit debit is invented for this receiver.
        for (0..table.count) |source| {
            const item = try table.record(@intCast(source));
            if (item.initially_active == 0 or item.parameters[0] != record.kind) continue;
            const signal = @import("credit_wallet.zig").signal(try rules.group(rule_bytes, item.rule_group)) orelse continue;
            if (signal != spec.accept) continue;
            for (supplies, 0..) |supply, index| if (supply.kind == .credits) {
                try bindings.append(allocator, .{ .item = .{ .index = @intCast(index), .generation = 1 }, .actor = definitions.items.len, .next_step = source >= i });
                break;
            };
        }
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        table.register(@intCast(i), .item_aid);
        try definitions.append(allocator, .{ .profile = profile, .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0, .credential = record.life, .interaction_priority = @intCast(i), .hint = try resolver.icon(record.contact_icon - 1), .label = label, .return_item = return_item, .reward = reward });
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |d| allocator.free(d.label);
        allocator.free(owned);
    }
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    return .{ .allocator = allocator, .definitions = owned, .profiles = owned_profiles, .clips = owned_clips, .bindings = try bindings.toOwnedSlice(allocator) };
}
