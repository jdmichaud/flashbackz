//! Recover the full trader family into idle choices, price/debit and sale outcomes.
const std = @import("std");
const runtime = @import("../actors/trader.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const equipment = @import("../equipment.zig");
const routes_mod = @import("first_world_props.zig");
pub const Spec = struct { states: [7]u16, sight: i16, look: i16, fidget: i16, introduction: i16, thanks: i16, signal: i16, debit_parameter: u2, outputs: [2]struct { parameter: u2, signal: i16 } };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    bindings: []runtime.Binding,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| {
            self.allocator.free(definition.label);
            self.allocator.free(definition.outputs);
        }
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
    const codes = [_][3]u8{ .{ 77, 0, 67 }, .{ 34, 0, 0 }, .{ 34, 102, 90 }, .{ 0, 64, 0 }, .{ 0, 0, 0 }, .{ 77, 0, 0 }, .{ 34, 0, 0 }, .{ 34, 102, 90 }, .{ 97, 0, 0 }, .{ 97, 0, 0 }, .{ 0, 64, 0 }, .{ 0, 0, 0 }, .{ 77, 0, 0 }, .{ 34, 0, 0 }, .{ 34, 102, 90 }, .{ 0, 64, 0 }, .{ 0, 0, 0 }, .{ 34, 102, 90 }, .{ 34, 0, 0 }, .{ 0, 0, 0 }, .{ 34, 0, 0 }, .{ 34, 102, 90 }, .{ 0, 0, 0 }, .{ 34, 102, 90 }, .{ 0, 0, 123 }, .{ 37, 38, 123 } };
    const next = [_]u16{ 5, 23, 25, 0, 5, 0, 23, 25, 17, 20, 12, 5, 5, 23, 25, 5, 12, 25, 23, 5, 23, 25, 5, 25, 5, 5 };
    const sources = [_]usize{ 0, 0, 0, 0, 0, 5, 5, 5, 5, 5, 5, 5, 12, 12, 12, 12, 12, 17, 17, 17, 20, 20, 20, 23, 23, 25 };
    for (&r, codes, next, sources, 0..) |*rule, operations, target, source, index| {
        rule.* = group.at(index);
        if (rule.source != group.at(source).source or rule.target != group.at(target).source or rule.next != target or rule.dx != 0 or rule.dy != 0 or rule.flags != 0) return null;
        for ([_]rules.Operation{ rule.conditions[0], rule.conditions[1], rule.effect }, operations) |operation, code| if (operation.code != code) return null;
    }
    const payment = r[2].conditions[0].argument;
    const debit = r[2].conditions[1].argument;
    if (debit < 0 or debit > 2) return null;
    for ([_]usize{ 2, 7, 14, 17, 21, 23 }) |i| if (r[i].conditions[0].argument != payment or r[i].conditions[1].argument != debit or r[i].effect.argument != 44) return null;
    for ([_]usize{ 1, 6, 13, 18, 20 }) |i| if (r[i].conditions[0].argument != 30) return null;
    if (r[0].conditions[0].argument != 0 or r[5].conditions[0].argument != 1 or r[12].conditions[0].argument != 1) return null;
    if (r[3].conditions[0].argument != 1 or r[10].conditions[0].argument != 1 or r[15].conditions[0].argument != 1 or r[3].conditions[1].argument <= 0 or r[3].conditions[1].argument != r[15].conditions[1].argument or r[10].conditions[1].argument != -r[3].conditions[1].argument) return null;
    if (r[24].effect.argument < 0 or r[25].effect.argument < 0) return null;
    return .{ .states = .{ r[0].source, r[5].source, r[17].source, r[20].source, r[12].source, r[23].source, r[25].source }, .sight = r[3].conditions[1].argument, .look = r[8].conditions[0].argument, .fidget = r[9].conditions[0].argument, .introduction = r[24].effect.argument, .thanks = r[25].effect.argument, .signal = payment, .debit_parameter = @intCast(debit), .outputs = .{ .{ .parameter = 2, .signal = r[25].conditions[0].argument }, .{ .parameter = 3, .signal = r[25].conditions[1].argument } } };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: *std.ArrayList(routes_mod.Connection), supplies: []const equipment.Definition, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| {
            allocator.free(definition.label);
            allocator.free(definition.outputs);
        }
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
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 3 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.states[0] or record.contact_icon == 0) return error.UnsupportedTraderStart;
        var profile: runtime.Profile = .{ .clips = undefined, .sight_cells = @intCast(@min(spec.sight, 16)), .look_chance = spec.look, .fidget_chance = spec.fidget, .introduction = @fromBackingInt(@as(u16, @intCast(spec.introduction))), .thanks = @fromBackingInt(@as(u16, @intCast(spec.thanks))), .payment_movie = .credit_payment };
        for (spec.states, &profile.clips) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingTrader,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const profile_index = profiles.items.len;
        try profiles.append(allocator, profile);
        const source_purse = record.parameters[spec.debit_parameter];
        if (source_purse < 0 or source_purse >= table.count) return error.InvalidTraderPurse;
        const purse_record = try table.record(@intCast(source_purse));
        const signal = @import("credit_wallet.zig").signal(try rules.group(rule_bytes, purse_record.rule_group)) orelse return error.UnsupportedTraderPurse;
        if (purse_record.kind != 3 or purse_record.initially_active == 0 or purse_record.parameters[0] != record.kind or signal != spec.signal) return error.UnsupportedTraderPurse;
        const purse: equipment.ItemHandle = for (supplies, 0..) |item, index| {
            if (item.kind == .credits) break .{ .index = @intCast(index), .generation = 1 };
        } else return error.MissingTraderPurse;
        try bindings.append(allocator, .{ .item = purse, .trader = definitions.items.len, .next_step = source_purse >= i });
        const outputs = try allocator.alloc(@import("../world_props.zig").CircuitId, spec.outputs.len);
        errdefer allocator.free(outputs);
        for (spec.outputs, outputs) |output, *circuit| {
            const target = record.parameters[output.parameter];
            if (target < 0 or target >= table.count) return error.InvalidTraderOutput;
            circuit.* = try routes_mod.internConnection(allocator, routes, @intCast(i), @intCast(target), output.signal);
        }
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .profile = profile_index, .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0, .interaction_priority = @intCast(i), .hint = try resolver.icon(record.contact_icon - 1), .label = label, .price = record.life, .debit = record.parameters[@as(usize, spec.debit_parameter) + 1], .purse = purse, .outputs = outputs });
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |definition| {
            allocator.free(definition.label);
            allocator.free(definition.outputs);
        }
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
