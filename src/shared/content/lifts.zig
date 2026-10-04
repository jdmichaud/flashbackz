//! Translate command-operated and automatic-return lift families into platform trips. Recognition
//! follows movement/arrival links and validates the full family; source states stay here.
const std = @import("std");
const runtime = @import("../lifts.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const placement = @import("placement.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const connections = @import("first_world_props.zig");
const collision = @import("collision.zig");
const TripSpec = struct {
    transfer: ?runtime.Transfer = null,
    parked: u16,
    departure: u16,
    movement: u16,
    arrival: ?u16,
    speed: i16,
    distance_parameter: u2,
    player_message: ?i16,
    call_message: ?i16,
    floor_on_blocked_request: bool,
    arrival_sound: ?motion.SoundId,
    start_output: ?rules.Operation,
    end_output: ?rules.Operation,
};
pub const Spec = struct {
    trips: [2]TripSpec,
    disabled: ?u16,
    enabled_stop: runtime.Stop,
    floor_row: i16,
    automatic_return: ?struct { stop: runtime.Stop, delay: i16, pause_outside_room: bool } = null,
};
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    profiles: []runtime.Profile,
    clips: []animation.OwnedClip,
    bindings: []runtime.Binding,
    /// Explicit coverage report for other lift graphs; no guessed behavior is substituted.
    unsupported: []u16,
    source_indices: []u16,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| self.allocator.free(definition.outputs);
        self.allocator.free(self.definitions);
        self.allocator.free(self.profiles);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.bindings);
        self.allocator.free(self.unsupported);
        self.allocator.free(self.source_indices);
    }
};
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
fn isOutput(value: rules.Operation) bool {
    return value.code >= 35 and value.code <= 38;
}
fn idle(group: rules.Group, state: u16) ?rules.Rule {
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.source == state and r.conditions[0].code == 0 and r.conditions[1].code == 0) return r;
    }
    return null;
}
pub fn recognize(group: rules.Group) ?Spec {
    if (recognizeAutomatic(group)) |spec| return spec;
    if (recognizeCinematic(group)) |spec| return spec;
    // The command-operated graphs share a contact safety check and acknowledgement.
    // Other command-operated graphs share the same safety and acknowledgement paths.
    if (group.count() != 22 and group.count() != 24) return null;
    var trips: [2]?TripSpec = @splat(null);
    var row: ?i16 = null;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (r.dx != 0 or r.dy != 0 or r.flags != 0 or r.next >= group.count() or group.at(r.next).source != r.target) return null;
        if (r.effect.code == 54 or r.conditions[1].code == 54) {
            const value = if (r.effect.code == 54) r.effect.argument else r.conditions[1].argument;
            if (row != null and row.? != value) return null;
            row = value;
        }
        if (r.conditions[0].code != 127 or r.conditions[1].code != 111) continue;
        const start = for (0..group.count()) |j| {
            const d = group.at(j);
            if (d.source == r.target and d.conditions[0].code == 68 and d.conditions[1].code == 114 and d.effect.code == 78) break d;
        } else return null;
        if (start.conditions[0].argument < 0 or start.conditions[0].argument > 3 or start.effect.argument == 0) return null;
        const movement = idle(group, start.target) orelse return null;
        if (movement.target != movement.source or !op(movement.effect, 78, start.effect.argument)) return null;
        const end = for (0..group.count()) |j| {
            const candidate = group.at(j);
            if (candidate.source == movement.source and op(candidate.conditions[0], 63, 0)) break candidate;
        } else return null;
        if (end.effect.code != 54 or start.conditions[1].argument != end.effect.argument) return null;
        const arrival = idle(group, end.target);
        const arrived_state = if (arrival) |a| a.target else end.target;
        const arrival_clip: ?u16 = if (arrival) |a| if (a.target != a.source and op(a.effect, 0, 0)) a.source else null else null;
        if (arrival != null and arrival_clip == null) return null;
        const index: usize = if (start.effect.argument < 0) 0 else 1;
        if (trips[index] != null) return null;
        var call: ?i16 = null;
        var fallback_floor = false;
        var ready_rules: usize = 0;
        for (0..group.count()) |j| {
            const a = group.at(j);
            if (a.source != r.source) continue;
            ready_rules += 1;
            if (op(a.conditions[0], 127, 0) and a.conditions[1].code == 34 and a.target == r.target) call = a.conditions[1].argument;
            if (a.conditions[0].code == 34 and op(a.conditions[1], 126, 132)) fallback_floor = a.effect.code == 54;
        }
        if (ready_rules != 6 or call == null) return null;
        const sound = if (end.conditions[1].code == 125 and end.conditions[1].argument >= 0 and end.conditions[1].argument < 66) @as(?motion.SoundId, @fromBackingInt(@as(u8, @intCast(end.conditions[1].argument)))) else null;
        if (end.conditions[1].code != 0 and sound == null and !isOutput(end.conditions[1])) return null;
        if (r.effect.code != 0 and r.effect.code != 68 and !isOutput(r.effect)) return null;
        trips[index] = .{ .parked = r.source, .departure = r.target, .movement = movement.source, .arrival = arrival_clip, .speed = start.effect.argument, .distance_parameter = @intCast(start.conditions[0].argument), .player_message = r.conditions[1].argument, .call_message = call.?, .floor_on_blocked_request = fallback_floor, .arrival_sound = sound, .start_output = if (isOutput(r.effect)) r.effect else null, .end_output = if (isOutput(end.conditions[1])) end.conditions[1] else null };
        // The opposite parked state is checked after both trips have been recovered.
        if (arrived_state == r.source) return null;
    }
    if (trips[0] == null or trips[1] == null or row == null) return null;
    const complete = [2]TripSpec{ trips[0].?, trips[1].? };
    for (complete, 0..) |trip, index| {
        const end = for (0..group.count()) |j| {
            const r = group.at(j);
            if (r.source == trip.movement and op(r.conditions[0], 63, 0)) break r;
        } else unreachable;
        const destination = if (trip.arrival) |a| (idle(group, a) orelse return null).target else end.target;
        if (destination != complete[1 - index].parked) return null;
    }
    var disabled: ?u16 = null;
    var enabled: runtime.Stop = undefined;
    for (0..group.count()) |i| {
        const r = group.at(i);
        if (!op(r.conditions[0], 34, 30) or r.conditions[1].code != 0 or r.effect.code != 0) continue;
        if (r.target == complete[0].parked) enabled = .bottom else if (r.target == complete[1].parked) enabled = .top else continue;
        disabled = r.source;
    }
    if (disabled == null) return null;
    // Validate every operation, including the rider invitation and disabled support paths.
    for (0..group.count()) |i| {
        const r = group.at(i);
        for ([_]rules.Operation{ r.conditions[0], r.conditions[1], r.effect }) |a| switch (a.code) {
            0, 34, 35, 36, 37, 38, 54, 63, 67, 68, 70, 71, 78, 111, 114, 125, 126, 127 => {},
            else => return null,
        };
    }
    return .{ .trips = complete, .disabled = disabled.?, .enabled_stop = enabled, .floor_row = row.? };
}
/// A pressure call lowers this platform; a resettable parked timer returns it upward.
/// Every row is checked, while animation IDs, signal, timing and distance stay data values.
fn recognizeAutomatic(group: rules.Group) ?Spec {
    if (group.count() != 14) return null;
    var r: [14]rules.Rule = undefined;
    const codes = [_][3]u8{ .{ 77, 0, 0 }, .{ 63, 68, 78 }, .{ 34, 62, 54 }, .{ 0, 126, 54 }, .{ 0, 0, 54 }, .{ 34, 68, 0 }, .{ 67, 0, 54 }, .{ 63, 125, 54 }, .{ 0, 0, 78 }, .{ 63, 62, 54 }, .{ 0, 0, 78 }, .{ 0, 114, 78 }, .{ 0, 114, 78 }, .{ 0, 0, 0 } };
    const next = [_]u16{ 0, 12, 0, 0, 0, 11, 5, 5, 7, 13, 9, 9, 7, 0 };
    for (&r, codes, next, 0..) |*row, expected, target, i| {
        row.* = group.at(i);
        if (row.dx != 0 or row.dy != 0 or row.flags != 0 or row.next != target or row.target != group.at(target).source) return null;
        const operations = [_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect };
        for (operations, expected) |operation, code| if (operation.code != code) return null;
    }
    for ([_]usize{ 1, 2, 3, 4 }) |i| if (r[i].source != r[0].source) return null;
    if (r[6].source != r[5].source or r[8].source != r[7].source or r[10].source != r[9].source) return null;
    if (r[0].source == r[5].source or r[7].source == r[9].source) return null;
    const height = r[2].effect.argument;
    for ([_]usize{ 3, 4, 6, 7, 9 }) |i| if (r[i].effect.argument != height) return null;
    if (r[11].conditions[1].argument != height or r[12].conditions[1].argument != height) return null;
    const parameter = r[1].conditions[1].argument;
    if (parameter < 0 or parameter > 3 or r[5].conditions[1].argument != parameter) return null;
    const delay = r[2].conditions[1].argument;
    const signal = r[2].conditions[0].argument;
    if (delay <= 0 or r[9].conditions[1].argument != delay or r[5].conditions[0].argument != signal) return null;
    if (r[0].conditions[0].argument != 0 or r[1].conditions[0].argument != 0 or r[7].conditions[0].argument != 0 or r[9].conditions[0].argument != 0 or r[1].effect.argument != 0 or r[3].conditions[1].argument != 130) return null;
    const up = r[8].effect.argument;
    const down = r[10].effect.argument;
    const sound = r[7].conditions[1].argument;
    if (up >= 0 or down <= 0 or r[12].effect.argument != up or r[11].effect.argument != down or sound < 0 or sound >= 66) return null;
    return .{ .trips = .{
        .{ .parked = r[0].source, .departure = r[12].source, .movement = r[7].source, .arrival = null, .speed = up, .distance_parameter = @intCast(parameter), .player_message = null, .call_message = null, .floor_on_blocked_request = false, .arrival_sound = @fromBackingInt(@as(u8, @intCast(sound))), .start_output = null, .end_output = null },
        .{ .parked = r[5].source, .departure = r[11].source, .movement = r[9].source, .arrival = r[13].source, .speed = down, .distance_parameter = @intCast(parameter), .player_message = null, .call_message = signal, .floor_on_blocked_request = false, .arrival_sound = null, .start_output = null, .end_output = null },
    }, .disabled = null, .enabled_stop = .top, .floor_row = height, .automatic_return = .{ .stop = .bottom, .delay = delay, .pause_outside_room = true } };
}

/// Long transit is represented by a cinematic between authored physical endpoints.
/// The ordinary approach and passengers use the same motion system as every other lift.
fn recognizeCinematic(group: rules.Group) ?Spec {
    if (group.count() != 20) return null;
    var r: [20]rules.Rule = undefined;
    const codes = [_][3]u8{ .{ 127, 111, 68 }, .{ 127, 34, 68 }, .{ 34, 126, 0 }, .{ 34, 126, 0 }, .{ 0, 126, 54 }, .{ 67, 0, 54 }, .{ 127, 111, 68 }, .{ 127, 34, 68 }, .{ 34, 126, 0 }, .{ 34, 126, 0 }, .{ 0, 126, 54 }, .{ 67, 0, 54 }, .{ 63, 0, 54 }, .{ 0, 0, 78 }, .{ 63, 0, 54 }, .{ 0, 0, 78 }, .{ 68, 114, 78 }, .{ 68, 114, 78 }, .{ 0, 90, 78 }, .{ 0, 90, 78 } };
    const next = [_]u16{ 17, 17, 0, 0, 0, 0, 16, 16, 6, 6, 6, 6, 19, 12, 18, 14, 14, 12, 0, 6 };
    for (&r, codes, next, 0..) |*row, expected, target, i| {
        row.* = group.at(i);
        if (row.dx != 0 or row.dy != 0 or row.flags != 0 or row.next != target or row.target != group.at(target).source) return null;
        for ([_]rules.Operation{ row.conditions[0], row.conditions[1], row.effect }, expected) |operation, code| if (operation.code != code) return null;
    }
    for ([_]usize{ 1, 2, 3, 4, 5 }) |i| if (r[i].source != r[0].source) return null;
    for ([_]usize{ 7, 8, 9, 10, 11 }) |i| if (r[i].source != r[6].source) return null;
    if (r[13].source != r[12].source or r[15].source != r[14].source or r[0].source == r[6].source) return null;
    const height = r[4].effect.argument;
    for ([_]usize{ 5, 10, 11, 12, 14 }) |i| if (r[i].effect.argument != height) return null;
    for ([_]usize{ 16, 17 }) |i| if (r[i].conditions[1].argument != height or r[i].conditions[0].argument < 0 or r[i].conditions[0].argument > 3) return null;
    for ([_]usize{ 0, 1, 6, 7 }) |i| if (r[i].effect.argument < 0 or r[i].effect.argument > 3) return null;
    if (r[12].conditions[0].argument != 0 or r[14].conditions[0].argument != 0 or r[4].conditions[1].argument != 130 or r[10].conditions[1].argument != 130) return null;
    for ([_]usize{ 2, 3, 8, 9 }) |i| if (r[i].conditions[1].argument != 132) return null;
    if (r[2].conditions[0].argument != r[0].conditions[1].argument or r[3].conditions[0].argument != r[1].conditions[1].argument or r[8].conditions[0].argument != r[6].conditions[1].argument or r[9].conditions[0].argument != r[7].conditions[1].argument) return null;
    if (r[13].effect.argument >= 0 or r[15].effect.argument <= 0 or r[17].effect.argument != r[13].effect.argument or r[16].effect.argument != r[15].effect.argument) return null;
    // Immutable floppy movie directory: LIFT entry 0 ascends, entry 1 descends.
    if (r[19].conditions[1].argument != 54 or r[18].conditions[1].argument != 55) return null;
    return .{ .trips = .{
        .{ .parked = r[0].source, .departure = r[17].source, .movement = r[12].source, .arrival = r[19].source, .speed = r[13].effect.argument, .distance_parameter = @intCast(r[17].conditions[0].argument), .player_message = r[0].conditions[1].argument, .call_message = r[1].conditions[1].argument, .floor_on_blocked_request = false, .arrival_sound = null, .start_output = null, .end_output = null, .transfer = .{ .movie = .lift_ascent, .displacement = r[19].effect.argument } },
        .{ .parked = r[6].source, .departure = r[16].source, .movement = r[14].source, .arrival = r[18].source, .speed = r[15].effect.argument, .distance_parameter = @intCast(r[16].conditions[0].argument), .player_message = r[6].conditions[1].argument, .call_message = r[7].conditions[1].argument, .floor_on_blocked_request = false, .arrival_sound = null, .start_output = null, .end_output = null, .transfer = .{ .movie = .lift_descent, .displacement = r[18].effect.argument } },
    }, .disabled = null, .enabled_stop = .top, .floor_row = height };
}

fn resolve(allocator: std.mem.Allocator, animations: []const u8, state: u16, clips: *std.ArrayList(animation.OwnedClip), resolver: anytype) !motion.Clip {
    var source = try animation.decode(allocator, animations, state);
    defer source.deinit();
    for (source.frames) |frame| switch (frame) {
        .hold => {},
        .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingLiftArtwork,
    };
    var clip = try source.resolve(allocator, resolver);
    errdefer clip.deinit();
    try clips.append(allocator, clip);
    return clip.clip();
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, rooms: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, routes: *std.ArrayList(connections.Connection), resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |d| allocator.free(d.outputs);
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
    var unsupported: std.ArrayList(u16) = .empty;
    errdefer unsupported.deinit(allocator);
    var source_indices: std.ArrayList(u16) = .empty;
    errdefer source_indices.deinit(allocator);
    var groups: std.AutoHashMap(u16, usize) = .init(allocator);
    defer groups.deinit();
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 8 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse {
            try unsupported.append(allocator, @intCast(i));
            continue;
        };
        const profile_id = groups.get(record.rule_group) orelse fresh: {
            var profile: runtime.Profile = .{ .stops = undefined, .trips = undefined, .enabled_stop = spec.enabled_stop, .disabled = if (spec.disabled) |state| try resolve(allocator, animations, state, &clips, resolver) else null };
            for (spec.trips, 0..) |trip, index| {
                profile.stops[1 - index] = .{ .idle = try resolve(allocator, animations, trip.parked, &clips, resolver), .floor_on_blocked_request = trip.floor_on_blocked_request };
                profile.trips[index] = .{ .departure = try resolve(allocator, animations, trip.departure, &clips, resolver), .movement = try resolve(allocator, animations, trip.movement, &clips, resolver), .arrival = if (trip.arrival) |a| try resolve(allocator, animations, a, &clips, resolver) else null, .speed = trip.speed, .arrival_sound = trip.arrival_sound, .transfer = trip.transfer };
            }
            if (spec.automatic_return) |automatic| {
                for (&profile.stops) |*policy| {
                    policy.accepts_player = false;
                    policy.refuses_unboarded_items = false;
                }
                const returning = &profile.stops[@backingInt(automatic.stop)];
                returning.return_delay = automatic.delay;
                returning.pause_return_outside_room = automatic.pause_outside_room;
                returning.sleep_when_empty = false;
                const resting = &profile.stops[1 - @backingInt(automatic.stop)];
                resting.release_passengers = false;
                resting.sleep_with_contacts = true;
            }
            const id = profiles.items.len;
            try profiles.append(allocator, profile);
            try groups.put(record.rule_group, id);
            break :fresh id;
        };
        if (record.collision_width == 0 or record.collision_width > 16) return error.InvalidLiftFootprint;
        var column = @divFloor(@as(i32, record.position.x) + 8, 16);
        if (record.facing_right != 0) column -= record.collision_width - 1;
        const floor_row = (@divTrunc(@as(i32, record.position.y), 36) & ~@as(i32, 1)) + spec.floor_row;
        if (column < 0 or column + record.collision_width > 16 or floor_row < 0 or floor_row >= 7) return error.InvalidLiftFootprint;
        const disabled = record.initial_state == spec.disabled;
        const stop: runtime.Stop = if (record.initial_state == spec.trips[0].parked) .bottom else if (record.initial_state == spec.trips[1].parked) .top else if (disabled) spec.enabled_stop else return error.UnsupportedLiftStart;
        var durations: [2]i16 = undefined;
        var outputs: std.ArrayList(runtime.Output) = .empty;
        defer outputs.deinit(allocator);
        for (spec.trips, &durations, 0..) |trip, *duration, index| {
            duration.* = record.parameters[trip.distance_parameter];
            // Timer words wrap in the original; zero is valid in a one-way transfer template.
            for ([_]?rules.Operation{ trip.start_output, trip.end_output }, 0..) |value, event_index| if (value) |output| {
                const target = record.parameters[output.code - 35];
                if (target < 0 or target >= table.count) return error.InvalidLiftOutput;
                const circuit = try connections.internConnection(allocator, routes, @intCast(i), @intCast(target), output.argument);
                try outputs.append(allocator, .{ .event = if (event_index == 0) (if (index == 0) .depart_up else .depart_down) else (if (index == 0) .arrive_up else .arrive_down), .circuit = circuit });
            };
        }
        try source_indices.append(allocator, @intCast(i));
        const owned_outputs = try outputs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_outputs);
        try definitions.append(allocator, .{ .profile = profile_id, .room = rooms[record.room], .position = record.position, .facing = if (record.facing_right == 0) .left else .right, .width = record.collision_width, .floor_row_offset = spec.floor_row, .history_weight = collision.snapshotWeight(record.collision_width), .history_reuse = collision.snapshotReuse(record.collision_width, record.facing_right != 0), .travel_steps = durations, .initial_stop = stop, .initially_disabled = disabled, .initially_active = record.initially_active != 0, .wake_nearby = record.flags & 4 != 0, .wake_on_contact = record.flags & 2 != 0, .accepts_signals = record.flags & 1 != 0, .palette_bank = @intCast(record.visual_flags & 3), .behind_player = record.visual_flags & 8 != 0, .outputs = owned_outputs });
    }
    // All lift outputs must exist before resolving inputs, including backward links.
    var definition_index: usize = 0;
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 8 or record.room >= rooms.len or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        for (routes.items) |route| {
            if (route.recipient != i) continue;
            const action: runtime.Action = if (route.message == spec.trips[0].call_message or route.message == spec.trips[0].player_message) .go_up else if (route.message == spec.trips[1].call_message or route.message == spec.trips[1].player_message) .go_down else if (spec.disabled != null and route.message == 30) .enable else .wake;
            try bindings.append(allocator, .{ .circuit = route.circuit, .target = definition_index, .action = action, .next_step = route.sender >= i });
        }
        definition_index += 1;
    }
    const owned_definitions = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned_definitions) |d| allocator.free(d.outputs);
        allocator.free(owned_definitions);
    }
    const owned_profiles = try profiles.toOwnedSlice(allocator);
    errdefer allocator.free(owned_profiles);
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_bindings = try bindings.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bindings);
    const owned_sources = try source_indices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_sources);
    return .{ .allocator = allocator, .source_indices = owned_sources, .definitions = owned_definitions, .profiles = owned_profiles, .clips = owned_clips, .bindings = owned_bindings, .unsupported = try unsupported.toOwnedSlice(allocator) };
}
