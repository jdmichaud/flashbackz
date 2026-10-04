//! Recover door aperture tracks, clearance landmarks and circuit meanings from complete
//! rule families. Source states identify content only; the runtime never dispatches them.
const std = @import("std");
const runtime = @import("../doors.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const terrain = @import("../terrain.zig");
const collision = @import("collision.zig");
const connections = @import("first_world_props.zig");
const Spec = struct {
    closed: u16,
    open: u16,
    opening: [32]u16 = undefined,
    opening_count: usize = 0,
    closing: [32]u16 = undefined,
    closing_count: usize = 0,
    open_message: ?i16 = null,
    close_message: ?i16 = null,
    reset_messages: [2]?i16 = @splat(null),
    automatic: bool,
    shoot_to_open: bool = false,
    hold_parameter: ?u2 = null,
    height: i16,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    bindings: []runtime.Binding,
    clips: []animation.OwnedClip,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.definitions);
        self.allocator.free(self.bindings);
        for (self.profiles) |profile| {
            self.allocator.free(profile.opening);
            self.allocator.free(profile.closing);
        }
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
    }
};
fn ops(rule: rules.Rule) [3]rules.Operation {
    return .{ rule.conditions[0], rule.conditions[1], rule.effect };
}
fn has(rule: rules.Rule, code: u8) bool {
    for (ops(rule)) |op| if (op.code == code) return true;
    return false;
}
fn material(rule: rules.Rule) ?terrain.Material {
    for (ops(rule)) |op| switch (op.code) {
        54 => return .solid,
        55 => return .empty,
        104 => return .restricted,
        else => {},
    };
    return null;
}
fn progress(group: rules.Group, state: u16) ?rules.Rule {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source != state or (r.conditions[0].code != 0 and r.conditions[0].code != 67)) continue;
        switch (r.conditions[1].code) {
            0, 54, 55, 67, 68, 104 => return r,
            else => {},
        }
    }
    return null;
}
fn received(group: rules.Group, state: u16, message: ?i16) ?rules.Rule {
    const value = message orelse return null;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == state and r.conditions[0].code == 34 and r.conditions[0].argument == value) return r;
    }
    return null;
}
fn discover(group: rules.Group) !?Spec {
    if (group.count() < 10 or group.count() > 80) return null;
    const closed = group.at(0).source;
    const rest = progress(group, closed) orelse return null;
    if (material(rest) != .solid) return null;
    var spec: Spec = .{ .closed = closed, .open = undefined, .automatic = rest.target != closed, .height = 0 };
    var height: ?i16 = null;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        if (r.next >= group.count() or group.at(r.next).source != r.target) return error.InvalidDoorTransition;
        for (ops(r)) |op| switch (op.code) {
            54, 55, 104 => {
                if (height != null and height.? != op.argument) return error.InconsistentDoorClearanceRow;
                height = op.argument;
            },
            0, 34, 62, 63, 67, 68, 80, 107 => {},
            else => return null,
        };
        if (r.source == closed and r.conditions[0].code == 34 and r.target != closed) spec.open_message = r.conditions[0].argument;
        if (r.source == closed and r.conditions[0].code == 107) spec.shoot_to_open = true;
    }
    spec.height = height orelse return null;
    var state = if (spec.automatic) rest.target else (received(group, closed, spec.open_message) orelse return null).target;
    while (true) {
        const next = progress(group, state) orelse return error.MissingDoorOpeningContinuation;
        if (next.target == state) {
            spec.open = state;
            break;
        }
        if (spec.opening_count == spec.opening.len or std.mem.indexOfScalar(u16, spec.opening[0..spec.opening_count], state) != null) return error.InvalidDoorOpeningTrack;
        spec.opening[spec.opening_count] = state;
        spec.opening_count += 1;
        state = next.target;
    }
    if (spec.opening_count == 0 or spec.open == closed or material(progress(group, spec.open).?) != .empty) return null;
    var closing_start: ?u16 = null;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == spec.open and r.conditions[0].code == 34 and r.target != spec.open and r.target != closed) {
            spec.close_message = r.conditions[0].argument;
            closing_start = r.target;
        }
        if (r.conditions[0].code == 34 and r.target == closed and material(r) == .solid) {
            const message = r.conditions[0].argument;
            if (spec.reset_messages[0] == message or spec.reset_messages[1] == message) continue;
            if (spec.reset_messages[0] == null) spec.reset_messages[0] = message else if (spec.reset_messages[1] == null) spec.reset_messages[1] = message else return error.TooManyDoorResetSignals;
        }
        if (r.source == spec.open and r.conditions[0].code == 63) {
            if (r.conditions[0].argument != 0) return error.UnsupportedDoorTimer;
            const final = progress(group, spec.opening[spec.opening_count - 1]).?;
            if (final.conditions[1].code != 68 or final.conditions[1].argument < 0 or final.conditions[1].argument > 3) return error.UnsupportedDoorTimer;
            spec.hold_parameter = @intCast(final.conditions[1].argument);
        }
    }
    for (&spec.reset_messages) |*message| if (message.* == spec.close_message) {
        message.* = null;
    };
    if (closing_start) |start| {
        state = start;
        while (state != closed) {
            const next = progress(group, state) orelse return error.MissingDoorClosingContinuation;
            if (spec.closing_count == spec.closing.len or std.mem.indexOfScalar(u16, spec.closing[0..spec.closing_count], state) != null) return error.InvalidDoorClosingTrack;
            spec.closing[spec.closing_count] = state;
            spec.closing_count += 1;
            state = next.target;
        }
    }
    return spec;
}
fn resolve(allocator: std.mem.Allocator, animations: []const u8, state: u16, clips: *std.ArrayList(animation.OwnedClip), resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingDoorAnchor,
    };
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try clips.append(allocator, clip);
    return clip.clip();
}
fn track(allocator: std.mem.Allocator, group: rules.Group, states: []const u16, opposite: []const u16, reverse_message: ?i16, animations: []const u8, clips: *std.ArrayList(animation.OwnedClip), resolver: anytype) ![]runtime.Segment {
    const result = try allocator.alloc(runtime.Segment, states.len);
    errdefer allocator.free(result);
    for (states, result) |state, *segment| {
        segment.* = .{ .clip = try resolve(allocator, animations, state, clips, resolver), .clearance_after = material(progress(group, state).?) };
        if (received(group, state, reverse_message)) |reverse| segment.reverse = .{ .segment = std.mem.indexOfScalar(u16, opposite, reverse.target) orelse return error.InvalidDoorReversal, .clearance = material(reverse) };
    }
    return result;
}
fn recoverProfile(allocator: std.mem.Allocator, spec: Spec, group: rules.Group, animations: []const u8, clips: *std.ArrayList(animation.OwnedClip), resolver: anytype) !runtime.Profile {
    const opening = try track(allocator, group, spec.opening[0..spec.opening_count], spec.closing[0..spec.closing_count], spec.close_message, animations, clips, resolver);
    errdefer allocator.free(opening);
    const closing = try track(allocator, group, spec.closing[0..spec.closing_count], spec.opening[0..spec.opening_count], spec.open_message, animations, clips, resolver);
    errdefer allocator.free(closing);
    var snap: [4]bool = @splat(false);
    for (spec.reset_messages) |message| {
        if (received(group, spec.closed, message) != null) snap[@backingInt(runtime.Phase.closed)] = true;
        if (received(group, spec.open, message) != null) snap[@backingInt(runtime.Phase.open)] = true;
        if (received(group, spec.opening[0], message) != null) snap[@backingInt(runtime.Phase.opening)] = true;
        if (spec.closing_count != 0 and received(group, spec.closing[0], message) != null) snap[@backingInt(runtime.Phase.closing)] = true;
    }
    var hold_player = false;
    var hold_enemies = false;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == spec.open and r.conditions[0].code == 80) {
            if (r.conditions[1].code != 68 or spec.hold_parameter == null or r.conditions[1].argument != spec.hold_parameter.?) return error.UnsupportedDoorOccupancy;
            switch (r.conditions[0].argument) {
                1 => hold_player = true,
                10 => hold_enemies = true,
                else => return error.UnsupportedDoorOccupantKind,
            }
        }
    }
    return .{ .closed = try resolve(allocator, animations, spec.closed, clips, resolver), .open = try resolve(allocator, animations, spec.open, clips, resolver), .opening = opening, .closing = closing, .automatic_open = spec.automatic, .shoot_to_open = spec.shoot_to_open, .snap_closed = snap, .keep_open_request = received(group, spec.open, spec.open_message) != null, .hold_player = hold_player, .hold_enemies = hold_enemies, .sleep_closed = has(progress(group, spec.closed).?, 67), .sleep_open = has(progress(group, spec.open).?, 67), .start_closing_clearance = if (received(group, spec.open, spec.close_message)) |r| material(r) else null };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: []const connections.Connection, player_projectile: u16, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer definitions.deinit(allocator);
    var profiles: std.ArrayList(runtime.Profile) = .empty;
    errdefer {
        for (profiles.items) |p| {
            allocator.free(p.opening);
            allocator.free(p.closing);
        }
        profiles.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    var families: [256]?struct { index: usize, spec: Spec } = @splat(null);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.minimum_difficulty > @backingInt(difficulty)) continue;
        if (record.rule_group >= families.len) return error.InvalidDoorGroup;
        if (families[record.rule_group] == null) {
            const group = try rules.group(rule_bytes, record.rule_group);
            const spec = try discover(group) orelse continue;
            const recovered = try recoverProfile(allocator, spec, group, animations, &clips, resolver);
            errdefer {
                allocator.free(recovered.opening);
                allocator.free(recovered.closing);
            }
            const index = profiles.items.len;
            try profiles.append(allocator, recovered);
            families[record.rule_group] = .{ .index = index, .spec = spec };
        }
        const family = families[record.rule_group].?;
        const spec = family.spec;
        var initial_segment: usize = 0;
        const phase: runtime.Phase = if (record.initial_state == spec.closed) .closed else if (record.initial_state == spec.open) .open else initial: {
            if (std.mem.indexOfScalar(u16, spec.opening[0..spec.opening_count], record.initial_state)) |segment| {
                initial_segment = segment;
                break :initial .opening;
            }
            if (std.mem.indexOfScalar(u16, spec.closing[0..spec.closing_count], record.initial_state)) |segment| {
                initial_segment = segment;
                break :initial .closing;
            }
            return error.UnsupportedDoorStart;
        };
        const column = ((record.position.x +% 8) >> 4) - (if (record.facing_right != 0) @as(i16, record.collision_width) - 1 else 0);
        const row = (@divTrunc(record.position.y, 36) & ~@as(i16, 1)) + spec.height;
        if (record.room >= rooms.len or record.collision_width == 0 or column < 0 or row < 0 or row >= 7 or column + record.collision_width > 16) return error.InvalidDoorFootprint;
        for (routes) |route| if (route.recipient == i) {
            const action: runtime.Action = if (spec.open_message != null and route.message == spec.open_message.?) .open else if (spec.close_message != null and route.message == spec.close_message.?) .close else reset: {
                for (spec.reset_messages) |message| if (message != null and message.? == route.message) break :reset .snap_closed;
                break :reset .wake;
            };
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = definitions.items.len, .action = action, .next_step = route.sender >= i });
        };
        try definitions.append(allocator, .{ .profile = family.index, .footprint = .{ .room = rooms[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .span = .{ .origin = .{ .room = rooms[record.room], .column = @intCast(column), .row = @intCast(row) }, .length = record.collision_width, .history_weight = collision.snapshotWeight(record.collision_width), .reuse = collision.snapshotReuse(record.collision_width, record.facing_right != 0) }, .initial_phase = phase, .initial_segment = initial_segment, .pass = if (i < player_projectile) .before_fire else .after_fire, .hold_steps = if (spec.hold_parameter) |p| record.parameters[p] else null, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .enemy_contact = record.kind == 10 });
    }
    const defs = try definitions.toOwnedSlice(allocator);
    errdefer allocator.free(defs);
    const profs = try profiles.toOwnedSlice(allocator);
    errdefer {
        for (profs) |p| {
            allocator.free(p.opening);
            allocator.free(p.closing);
        }
        allocator.free(profs);
    }
    const links = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(links);
    return .{ .allocator = allocator, .definitions = defs, .profiles = profs, .bindings = links, .clips = try clips.toOwnedSlice(allocator) };
}
