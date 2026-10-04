//! Translate the repeatable relay-control family into clips, contact hints and circuit
//! outputs. Recognition checks the complete rule shape, independent of group/object IDs.
const std = @import("std");
const runtime = @import("../operated_controls.zig");
const placement = @import("placement.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const props = @import("first_world_props.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
pub const Relay = struct { idle: u16, pressed: u16, target_parameter: u2, signal: i16, sound: motion.SoundId };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn recognize(group: rules.Group) ?Relay {
    if (group.count() != 4) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    for ([_]rules.Rule{ a, b, c, d }) |r| if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
    if (a.source != a.target or c.source != a.source or c.target != a.source or b.source != a.source or d.source != b.target or d.target != a.source or b.target == a.source) return null;
    if (a.next != 0 or b.next != 3 or c.next != 0 or d.next != 0) return null;
    if (!op(a.conditions[0], 77, 0) or !op(a.conditions[1], 0, 0) or !op(a.effect, 67, 0)) return null;
    // Scene 23 is explicitly unassigned (FFFF) in the pinned English floppy movie table.
    if (!op(b.conditions[0], 34, 30) or !op(b.conditions[1], 90, 23) or b.effect.code < 35 or b.effect.code > 38) return null;
    if (!op(c.conditions[0], 0, 0) or !op(c.conditions[1], 0, 0) or !op(c.effect, 0, 0)) return null;
    if (d.conditions[0].code != 125 or d.conditions[0].argument < 0 or d.conditions[0].argument >= 66 or !op(d.conditions[1], 0, 0) or !op(d.effect, 0, 0)) return null;
    return .{ .idle = a.source, .pressed = b.target, .target_parameter = @intCast(b.effect.code - 35), .signal = b.effect.argument, .sound = @fromBackingInt(@as(u8, @intCast(d.conditions[0].argument))) };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, room_ids: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(props.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| allocator.free(definition.label);
        definitions.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 5) continue;
        const relay = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != relay.idle or record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.room >= room_ids.len or record.contact_icon == 0) return error.InvalidControlPlacement;
        const target = record.parameters[relay.target_parameter];
        if (target < 0 or target >= table.count) return error.InvalidControlConnection;
        const circuit = for (connections.items) |connection| {
            if (connection.recipient == target and connection.message == relay.signal) break connection.circuit;
        } else fresh: {
            const id: @import("../world_props.zig").CircuitId = @fromBackingInt(@as(u16, @intCast(connections.items.len)));
            try connections.append(allocator, .{ .circuit = id, .recipient = @intCast(target), .message = relay.signal });
            break :fresh id;
        };
        var pair: [2]motion.Clip = undefined;
        for ([_]u16{ relay.idle, relay.pressed }, &pair) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingControlAnchor,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .footprint = .{ .room = room_ids[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .idle = pair[0], .pressed = pair[1], .release_sound = relay.sound, .circuit = circuit, .initially_active = record.initially_active != 0, .wake_when_near = record.flags & 4 != 0, .hint = try resolver.icon(record.contact_icon - 1), .label = label });
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |definition| allocator.free(definition.label);
        allocator.free(owned);
    }
    return .{ .allocator = allocator, .definitions = owned, .clips = try clips.toOwnedSlice(allocator) };
}

test "relay recognition accepts renamed states and parameter routes but rejects altered behavior" {
    var records: [72]u8 = @splat(0);
    const sources = [_]u16{ 101, 101, 101, 212 };
    const targets = [_]u16{ 101, 212, 101, 101 };
    for (sources, targets, 0..) |source, target, i| {
        std.mem.writeInt(u16, records[i * 18 ..][0..2], source, .little);
        std.mem.writeInt(u16, records[i * 18 + 4 ..][0..2], target, .little);
    }
    records[7] = 77;
    records[9] = 67;
    records[18 + 7] = 34;
    records[18 + 12] = 30;
    records[18 + 6] = 90;
    records[18 + 14] = 23;
    records[18 + 9] = 37;
    records[18 + 16] = 91;
    records[18 + 10] = 3;
    records[54 + 7] = 125;
    records[54 + 12] = 7;
    const group: rules.Group = .{ .records = &records };
    const relay = recognize(group).?;
    try std.testing.expectEqual(@as(u16, 101), relay.idle);
    try std.testing.expectEqual(@as(u16, 212), relay.pressed);
    try std.testing.expectEqual(@as(u2, 2), relay.target_parameter);
    try std.testing.expectEqual(@as(i16, 91), relay.signal);
    records[18 + 10] = 0;
    try std.testing.expect(recognize(group) == null);
}
