//! Recover the jungle's starting supplies into named definitions. Source states and
//! instruction numbers are checked here and never dispatched by the equipment system.
const std = @import("std");
const equipment = @import("../equipment.zig");
const placement = @import("placement.zig");
const animation = @import("animation.zig");
const strings = @import("string_table.zig");
const credential_cards = @import("credential_cards.zig");
const credit_wallet = @import("credit_wallet.zig");
const table = @import("rule_table.zig");

pub const Recovered = struct { definitions: []equipment.Definition, sources: []u16 };

pub fn recover(
    allocator: std.mem.Allocator,
    placements: placement.Table,
    animations: []const u8,
    rules: []const u8,
    names: []const u8,
    resolver: anytype,
) !Recovered {
    const Spec = struct { kind: equipment.Kind, state: u16, target: u16, operations: [3]u8 };
    // Ascending source activation order determines simultaneous item-arrival order. The
    // definitions contain semantic kinds, resolved icons and durations. Source provenance
    // is returned separately for import-time bindings and is discarded after assembly.
    const specs = [_]Spec{
        .{ .kind = .gun, .state = 327, .target = 314, .operations = .{ 0, 0, 48 } },
        .{ .kind = .shield, .state = 322, .target = 321, .operations = .{ 89, 0, 48 } },
        .{ .kind = .credits, .state = 329, .target = 330, .operations = .{ 0, 48, 67 } },
        .{ .kind = .id_card, .state = 331, .target = 332, .operations = .{ 48, 0, 67 } },
        .{ .kind = .work_permit, .state = 340, .target = 341, .operations = .{ 0, 0, 48 } },
        .{ .kind = .papers, .state = 340, .target = 338, .operations = .{ 0, 0, 48 } },
        .{ .kind = .force_field, .state = 424, .target = 427, .operations = .{ 0, 48, 0 } },
    };
    var count: usize = 0;
    for (0..placements.count) |i| {
        const record = try placements.record(@intCast(i));
        for (specs) |spec| if (record.initial_state == spec.state and
            record.initially_active != 0 and
            matchesKind(
                spec.kind,
                try table.group(rules, record.rule_group),
            ))
        {
            count += 1;
        };
    }
    const definitions = try allocator.alloc(equipment.Definition, count);
    errdefer allocator.free(definitions);
    const sources = try allocator.alloc(u16, count);
    errdefer allocator.free(sources);
    var loaded: usize = 0;
    errdefer for (definitions[0..loaded]) |definition| allocator.free(definition.label);
    for (0..placements.count) |i| {
        const source = try placements.record(@intCast(i));
        if (source.initially_active == 0) continue;
        const spec = for (specs) |candidate| {
            if (candidate.state == source.initial_state and matchesKind(
                candidate.kind,
                try table.group(rules, source.rule_group),
            )) break candidate;
        } else continue;
        const definition = &definitions[loaded];
        if (source.initial_state != spec.state or
            source.kind != 3 or
            source.minimum_difficulty != 0 or
            source.initially_active == 0)
            return error.UnsupportedStartingEquipment;
        const rule = try firstRule(rules, source.rule_group, source.initial_state);
        if (rule[2] != 0 or rule[3] != 0 or rule[8] != 0 or word(rule, 4) != spec.target or
            !std.mem.eql(u8, &.{ rule[7], rule[6], rule[9] }, &spec.operations) or
            (spec.operations[0] != 0 and word(
                rule,
                12,
            ) != 0) or word(rule, 14) != 0 or word(rule, 16) != 0)
            return error.UnsupportedStartingEquipmentRule;
        var introduction = try animation.decode(allocator, animations, source.initial_state);
        defer introduction.deinit();
        if (introduction.sound != null or
            introduction.header_metadata != (if (spec.kind == .force_field) @as(
                u8,
                2,
            ) else 0)) return error.UnsupportedEquipmentIntroduction;
        // Offstage inventory grants may animate their unused source position.
        // The loadout owns arrival timing, without creating an invisible world actor.
        for (introduction.frames) |frame| switch (frame) {
            .hold => {},
            .frame => |value| if (spec.kind != .force_field and
                (value.dx != 0 or value.dy != 0)) return error.UnsupportedEquipmentIntroduction,
        };
        if (spec.kind == .credits and
            (credit_wallet.signal(try table.group(
                rules,
                source.rule_group,
            )) == null or source.parameters[0] != 3)) return error.UnsupportedCreditUse;
        const card = if (spec.kind == .id_card) credential_cards.starting(try table.group(
            rules,
            source.rule_group,
        )) orelse return error.UnsupportedStartingCard else null;
        const papers = if (spec.kind == .papers) credential_cards.papers(try table.group(
            rules,
            source.rule_group,
        )) orelse return error.UnsupportedStartingPapers else null;
        var use_steps: ?u16 = null;
        if (card) |capability| {
            var clip = try animation.decode(allocator, animations, capability.using);
            defer clip.deinit();
            use_steps = @intCast(clip.frames.len);
        }
        if (papers) |capability| {
            var clip = try animation.decode(allocator, animations, capability.using);
            defer clip.deinit();
            use_steps = @intCast(clip.frames.len);
        }
        definition.* = .{
            .consumption_movie = if (papers != null) .card_delivery else null,
            .recharge = if (spec.kind == .shield) try shieldRecharge(
                allocator,
                source,
                rules,
                animations,
            ) else null,
            .use_motion = if (source.object_id == 3) .reach else .direct,
            .kind = spec.kind,
            .use_action = if (spec.kind == .credits) .pay else if (card != null or
                papers != null or
                spec.kind == .work_permit) .{ .unlock = .{
                .credential = .{ .fixed = source.life },
                .consume_after_steps = use_steps,
                .movie = if (card != null) .card_delivery else null,
            } } else null,
            .icon = try resolver.icon(source.inventory_icon),
            .introduction_steps = @as(u16, @intCast(introduction.frames.len)),
            .initial_quantity = source.life,
            .label = try strings.copy(allocator, names, source.text_id),
            .show_quantity = source.visual_flags & 4 != 0,
        };
        placements.register(@intCast(i), .starting_equipment);
        if (card != null) placements.register(@intCast(i), .credential_use);
        sources[loaded] = @intCast(i);
        loaded += 1;
    }
    return .{ .definitions = definitions, .sources = sources };
}

fn matchesKind(kind: equipment.Kind, group: table.Group) bool {
    return switch (kind) {
        .papers => credential_cards.papers(group) != null,
        .work_permit => credential_cards.permit(group) != null,
        else => true,
    };
}

fn shieldRecharge(
    allocator: std.mem.Allocator,
    record: placement.Record,
    rule_bytes: []const u8,
    animations: []const u8,
) !equipment.Recharge {
    const group = try table.group(rule_bytes, record.rule_group);
    if (group.count() != 4) return error.UnsupportedShieldRecharge;
    const intro = group.at(0);
    const use = group.at(1);
    const idle = group.at(2);
    const complete = group.at(3);
    for ([_]table.Rule{
        intro,
        use,
        idle,
        complete,
    }) |r| if (r.dx != 0 or r.dy != 0 or r.flags != 0) return error.UnsupportedShieldRecharge;
    if (use.source != intro.target or
        idle.source != use.source or
        idle.target != use.source or
        complete.source != use.target or
        complete.target != use.source or
        intro.next != 1 or
        use.next != 3 or
        idle.next != 1 or
        complete.next != 1) return error.UnsupportedShieldRecharge;
    if (use.conditions[0].code != 34 or
        use.conditions[0].argument != 102 or
        use.conditions[1].code != 84 or
        use.conditions[1].argument != 9 or
        use.effect.code != 0) return error.UnsupportedShieldRecharge;
    if (idle.conditions[0].code != 89 or
        idle.conditions[0].argument != 0 or
        idle.conditions[1].code != 0 or
        idle.effect.code != 0) return error.UnsupportedShieldRecharge;
    if (complete.conditions[0].code != 90 or
        complete.conditions[0].argument != 5 or
        complete.conditions[1].code != 0 or
        complete.effect.code != 88 or
        complete.effect.argument != 0) return error.UnsupportedShieldRecharge;
    var clip = try animation.decode(allocator, animations, use.target);
    defer clip.deinit();
    if (clip.sound != null) return error.UnsupportedShieldRechargeSound;
    for (clip.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |value| if (value.dx != 0 or value.dy != 0) return error.MovingShieldRecharge,
    };
    return .{
        .delay_steps = @intCast(clip.frames.len),
        .restore = .{ .player_health = record.parameters[0] },
        .movie = .shield_recharge,
    };
}

pub fn release(allocator: std.mem.Allocator, definitions: []equipment.Definition) void {
    for (definitions) |definition| allocator.free(definition.label);
    allocator.free(definitions);
}

fn word(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn firstRule(bytes: []const u8, group: u16, state: u16) ![]const u8 {
    if (bytes.len < 2) return error.InvalidEquipmentRules;
    const count = word(bytes, 0);
    const body = bytes[2..];
    if (count > 256 or @as(
        usize,
        count,
    ) * 4 > body.len or group >= count) return error.InvalidEquipmentRules;
    const offset = std.mem.readInt(u32, body[@as(usize, group) * 4 ..][0..4], .little);
    if (offset < @as(
        usize,
        count,
    ) * 4 or offset > body.len or body.len - offset < 2) return error.InvalidEquipmentRules;
    const records = body[offset..];
    const length = word(records, 0);
    if (@as(usize, length) * 18 > records.len - 2) return error.InvalidEquipmentRules;
    for (0..length) |i| {
        const record = records[2 + i * 18 ..][0..18];
        if (word(record, 0) == state) return record;
    }
    return error.MissingEquipmentRule;
}

test "rule recovery checks the directory and searches the requested initial state" {
    var bytes: [44]u8 = @splat(0);
    bytes[0..8].* = .{ 1, 0, 4, 0, 0, 0, 2, 0 };
    bytes[8] = 7;
    bytes[26] = 9;
    try std.testing.expectEqual(@as(u8, 9), (try firstRule(&bytes, 0, 9))[0]);
    try std.testing.expectError(error.MissingEquipmentRule, firstRule(&bytes, 0, 8));
    try std.testing.expectError(error.InvalidEquipmentRules, firstRule(bytes[0..43], 0, 9));
    bytes[2] = 1;
    try std.testing.expectError(error.InvalidEquipmentRules, firstRule(&bytes, 0, 9));
}
