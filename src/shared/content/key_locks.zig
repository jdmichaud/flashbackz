//! Recover one-use credential locks and their outgoing circuits from the complete
//! family graph. Item/lock iteration order becomes explicit delivery latency.
const std = @import("std");
const runtime = @import("../key_locks.zig");
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
    bindings: []runtime.Binding,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.label);
        self.allocator.free(self.definitions);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.bindings);
    }
};
pub const Spec = struct { idle: u16, used: u16, target_parameter: u2, input: i16, output: i16, sound: motion.SoundId, forward: i16, down: i16 };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
pub fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 5) return null;
    const use = group.at(0);
    if (use.source == use.target or use.flags != 0 or use.next != 3 or use.conditions[0].code != 34 or use.conditions[1].code < 35 or use.conditions[1].code > 38 or use.effect.code != 125 or use.effect.argument < 0 or use.effect.argument >= 66) return null;
    for (1..5) |i| {
        const r = group.at(i);
        const used = i >= 3;
        const sleeping = i == 1 or i == 3;
        const state = if (used) use.target else use.source;
        if (r.source != state or r.target != state or r.next != (if (used) @as(u16, 3) else 0) or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        if (!op(r.conditions[0], if (sleeping) 77 else 0, 0) or !op(r.conditions[1], 0, 0) or !op(r.effect, if (sleeping) 67 else 0, 0)) return null;
    }
    return .{ .idle = use.source, .used = use.target, .target_parameter = @intCast(use.conditions[1].code - 35), .input = use.conditions[0].argument, .output = use.conditions[1].argument, .sound = @fromBackingInt(@as(u8, @intCast(use.effect.argument))), .forward = -@as(i16, use.dx), .down = use.dy };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, room_ids: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(props.Connection), item_sources: []const u16, first_item: @import("../equipment.zig").ItemHandle, resolver: anytype) !Assets {
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
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 5 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.idle and record.initial_state != spec.used) return error.UnsupportedLockStart;
        if (record.room >= room_ids.len or record.contact_icon == 0) return error.InvalidLockPlacement;
        const target = record.parameters[spec.target_parameter];
        if (target < 0 or target >= table.count) return error.InvalidLockConnection;
        const circuit = try props.internConnection(allocator, connections, @intCast(i), @intCast(target), spec.output);
        var pair: [2]motion.Clip = undefined;
        for ([_]u16{ spec.idle, spec.used }, &pair) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingLockAnimation,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        for (item_sources, 0..) |source, index| {
            const item = try table.record(source);
            const key = @import("key_pickups.zig").recognize(try rules.group(rule_bytes, item.rule_group)) orelse continue;
            if (key.signal != spec.input or item.parameters[0] != record.kind) continue;
            try bindings.append(allocator, .{ .item = .{ .index = first_item.index + @as(u16, @intCast(index)), .generation = first_item.generation }, .lock = definitions.items.len, .next_step = source >= i });
        }
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        try definitions.append(allocator, .{ .footprint = .{ .room = room_ids[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .idle = pair[0], .used = pair[1], .credential = record.life, .unlock_forward = spec.forward, .unlock_down = spec.down, .unlock_sound = spec.sound, .circuit = circuit, .initially_used = record.initial_state == spec.used, .initially_active = record.initially_active != 0, .wake_when_near = record.flags & 4 != 0, .hint = try resolver.icon(record.contact_icon - 1), .label = label });
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |definition| allocator.free(definition.label);
        allocator.free(owned);
    }
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    return .{ .allocator = allocator, .definitions = owned, .clips = owned_clips, .bindings = try bindings.toOwnedSlice(allocator) };
}
