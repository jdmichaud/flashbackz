//! Convert signal-started decorative loops into animation and circuit definitions.
const std = @import("std");
const runtime = @import("../triggered_effects.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const first_world_props = @import("first_world_props.zig");
const motion = @import("../motion.zig");
const placement = @import("placement.zig");
const settings = @import("../settings.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
const Spec = struct {
    waiting: u16,
    running: u16,
    signal: i16,
    delta: motion.Position,
};
fn recognize(group: rules.Group) ?Spec {
    if (group.count() != 4) return null;
    const a = group.at(0);
    const b = group.at(1);
    const c = group.at(2);
    const d = group.at(3);
    if (a.source != b.source or
        b.target != a.source or
        c.source != a.target or
        d.source != a.target or
        c.target != a.target or
        d.target != a.target or
        a.source == a.target) return null;
    if (a.next != 2 or
        b.next != 0 or
        c.next != 2 or
        d.next != 2 or
        a.dx != 0 or
        a.dy != 0 or
        b.dx != 0 or
        b.dy != 0 or
        c.dx != d.dx or
        c.dy != d.dy) return null;
    for ([_]rules.Rule{
        a,
        b,
        c,
        d,
    }) |r| if (r.flags != 0 or r.conditions[1].code != 0) return null;
    if (a.conditions[0].code != 34 or
        a.effect.code != 0 or
        b.conditions[0].code != 0 or
        b.effect.code != 67 or
        c.conditions[0].code != 77 or
        c.effect.code != 67 or
        d.conditions[0].code != 0 or
        d.effect.code != 0) return null;
    return .{
        .waiting = a.source,
        .running = a.target,
        .signal = a.conditions[0].argument,
        .delta = .{ .x = c.dx, .y = c.dy },
    };
}
pub fn load(
    allocator: std.mem.Allocator,
    table: placement.Table,
    rule_bytes: []const u8,
    animations: []const u8,
    rooms: *const [64]geometry.RoomId,
    difficulty: settings.Difficulty,
    connections: []const first_world_props.Connection,
    resolver: anytype,
) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    for (0..table.count) |index| {
        const record = try table.record(@intCast(index));
        if (record.minimum_difficulty > @backingInt(difficulty) or
            record.room >= rooms.len or
            record.kind != 0) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.waiting) return error.UnsupportedEffectStart;
        var resolved: [2]motion.Clip = undefined;
        for ([_]u16{ spec.waiting, spec.running }, &resolved) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        for (connections) |connection| if (connection.recipient == index and
            connection.message == spec.signal)
        {
            try bindings.append(
                allocator,
                .{
                    .circuit = connection.circuit,
                    .target = definitions.items.len,
                    .next_step = connection.sender >= index,
                },
            );
        };
        table.register(@intCast(index), .triggered_effects);
        try definitions.append(
            allocator,
            .{
                .room = rooms[record.room],
                .position = record.position,
                .facing = if (record.facing_right == 0) .left else .right,
                .waiting = resolved[0],
                .running = resolved[1],
                .loop_delta = spec.delta,
                .palette_bank = @intCast(record.visual_flags & 3),
                .behind_player = record.visual_flags & 8 != 0,
                .initially_active = record.initially_active != 0,
                .wake_nearby = record.flags & 4 != 0,
                .accepts_signals = record.flags & 1 != 0,
            },
        );
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    return .{
        .allocator = allocator,
        .definitions = owned,
        .bindings = owned_bindings,
        .clips = try clips.toOwnedSlice(allocator),
    };
}
