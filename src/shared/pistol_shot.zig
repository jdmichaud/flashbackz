//! A pistol discharge owns its short flash and wall-impact effect. Authored motion
//! supplies artwork; terrain queries resolve the shot without a moving bullet actor.
const std = @import("std");
const combat = @import("combat.zig");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const terrain = @import("terrain.zig");
const Environment = @import("actors/conrad_environment.zig").Environment;
const shift = @import("actors/conrad_roll.zig").shiftForward;
pub const Height = @import("pistol_casing.zig").Height;
pub const Definition = struct {
    initial_phase: Phase = .ignition,
    retrigger_impact: bool = true,
    impact_forward: [2]i16 = .{ 3, 2 },
    impact_down: [2]i16 = .{ 5, 5 },
    ignition: motion.Clip,
    standing_flash: motion.Clip,
    crouched_flash: motion.Clip,
    airborne_flash: ?motion.Clip = null,
    standing_impact: motion.Clip,
    crouched_impact: motion.Clip,
    range_cells: u16,
    palette_bank: u4,
    behind_player: bool,
};
pub const Phase = enum { ignition, flash, impact };
pub const Effect = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    height: Height,
    airborne: bool = false,
    phase: Phase = .ignition,
    playback: motion.Playback = .{},
    fn clip(self: Effect, definition: Definition) motion.Clip {
        return switch (self.phase) {
            .ignition => definition.ignition,
            .flash => if (self.airborne) definition.airborne_flash orelse definition.crouched_flash else if (self.height == .standing) definition.standing_flash else definition.crouched_flash,
            .impact => if (self.height == .standing) definition.standing_impact else definition.crouched_impact,
        };
    }
};
pub const Hit = struct { room: geometry.RoomId, x: i16 };

/// Walk cell boundaries so an impact has the destination room's coordinate system.
/// The first occupied cell also blocks a point-blank shot.
pub fn traceWall(view: terrain.View, room: geometry.RoomId, pose: motion.Pose, range: u16) !?Hit {
    var current_room = room;
    var column = (pose.position.x +% 8) >> 4;
    const row = (@divTrunc(pose.position.y, 36) & ~@as(i16, 1)) + 1;
    const step: i16 = if (pose.facing == .right) 1 else -1;
    for (0..@as(usize, range) + 1) |_| {
        const address = try view.geometry.locate(current_room, column, row) orelse return .{ .room = current_room, .x = column *% 16 };
        if (try view.sample(current_room, column, row) != .empty) return .{ .room = address.room, .x = @as(i16, @intCast(address.column)) *% 16 };
        current_room = address.room;
        column = @as(i16, @intCast(address.column)) +% step;
    }
    return null;
}

pub const State = struct {
    effect: ?Effect = null,
    shots_fired: u64 = 0,
    sound_requested: ?motion.SoundId = null,
    hit_requested: ?combat.Hit = null,
    pub fn advance(self: *State, definition: Definition, shot: ?Height, pose: motion.Pose, room: geometry.RoomId, materials: terrain.View) !void {
        return self.advanceWithTargets(definition, shot, pose, room, materials, &.{});
    }
    pub fn advanceWithTargets(self: *State, definition: Definition, shot: ?Height, pose: motion.Pose, room: geometry.RoomId, materials: terrain.View, targets: []const combat.Target) !void {
        return self.advanceWithVariant(definition, shot, false, pose, room, materials, targets);
    }
    pub fn advanceWithVariant(self: *State, definition: Definition, shot: ?Height, airborne: bool, pose: motion.Pose, room: geometry.RoomId, materials: terrain.View, targets: []const combat.Target) !void {
        self.sound_requested = null;
        self.hit_requested = null;
        const accepts = if (self.effect) |effect| effect.phase == .impact and definition.retrigger_impact else true;
        if (shot != null and accepts) {
            const height = shot.?;
            self.shots_fired +%= 1;
            self.effect = .{ .pose = pose, .room = room, .height = height, .airborne = airborne, .phase = definition.initial_phase };
        }
        if (self.effect) |*effect| {
            if (effect.playback.exhausted(effect.clip(definition))) {
                if (effect.phase == .impact) {
                    self.effect = null;
                    return;
                }
                const environment: Environment = .{ .map = materials.geometry, .room = effect.room, .materials = materials };
                if (effect.phase == .ignition and !try environment.at(effect.pose, .torso, 1)) {
                    effect.phase = .flash;
                } else {
                    if (try combat.trace(materials, effect.room, effect.pose, effect.height, definition.range_cells, targets)) |impact| {
                        self.hit_requested = impact;
                        self.effect = null;
                        return;
                    }
                    const hit = try traceWall(materials, effect.room, effect.pose, definition.range_cells) orelse {
                        self.effect = null;
                        return;
                    };
                    effect.room = hit.room;
                    effect.pose.position.x = hit.x;
                    shift(&effect.pose, definition.impact_forward[@backingInt(effect.height)]);
                    effect.pose.position.y -%= if (effect.phase == .ignition) (if (effect.height == .standing) @as(i16, 35) else 22) else definition.impact_down[@backingInt(effect.height)];
                    effect.phase = .impact;
                }
                effect.playback = .{};
                _ = try materials.geometry.handoff(&effect.room, &effect.pose.position);
            }
            self.sound_requested = effect.playback.soundOnEntry(effect.clip(definition));
            _ = effect.playback.advance(effect.clip(definition), &effect.pose);
        }
    }
    pub fn hashInto(self: State, hash: *std.hash.Wyhash) void {
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.shots_fired)));
        hash.update(&.{@intFromBool(self.effect != null)});
        if (self.effect) |effect| {
            for ([_]u32{ @backingInt(effect.room), @as(u16, @bitCast(effect.pose.position.x)), @as(u16, @bitCast(effect.pose.position.y)), @backingInt(effect.pose.facing), @backingInt(effect.pose.visual.id), @intFromBool(effect.pose.visual.mirrored), @backingInt(effect.height), @intFromBool(effect.airborne), @backingInt(effect.phase), @intCast(effect.playback.next_step) }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
    }
};

test "shot wall search is inclusive, bounded and resolves a neighboring room" {
    const id: geometry.RoomId = @fromBackingInt(1);
    const neighbor: geometry.RoomId = @fromBackingInt(2);
    const empty: [48]bool = @splat(false);
    const rooms = [_]geometry.Room{
        .{ .id = id, .columns = 16, .rows = 3, .width = 256, .height = 72, .blocking = &empty, .edges = .{ .left = .blocked, .right = .{ .room = neighbor }, .up = .blocked, .down = .blocked } },
        .{ .id = neighbor, .columns = 16, .rows = 3, .width = 256, .height = 72, .blocking = &empty, .edges = .{ .left = .{ .room = id }, .right = .blocked, .up = .blocked, .down = .blocked } },
    };
    var materials: [96]terrain.Material = @splat(.empty);
    materials[48 + 16 + 2] = .solid;
    const view: terrain.View = .{ .geometry = .{ .rooms = &rooms }, .materials = &materials };
    const pose: motion.Pose = .{ .position = .{ .x = 240, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
    try std.testing.expect((try traceWall(view, id, pose, 2)) == null);
    try std.testing.expectEqualDeep(@as(?Hit, .{ .room = neighbor, .x = 32 }), try traceWall(view, id, pose, 3));
}

test "a shared emitter ignores new requests during an unfinished flash" {
    const id: geometry.RoomId = @fromBackingInt(1);
    const empty: [48]bool = @splat(false);
    const rooms = [_]geometry.Room{.{ .id = id, .columns = 16, .rows = 3, .width = 256, .height = 72, .blocking = &empty, .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked } }};
    const materials: [48]terrain.Material = @splat(.empty);
    const view: terrain.View = .{ .geometry = .{ .rooms = &rooms }, .materials = &materials };
    const frames = [_]motion.Step{ .hold, .hold, .hold };
    const clip: motion.Clip = .{ .steps = &frames };
    var definition: Definition = .{ .initial_phase = .flash, .retrigger_impact = false, .ignition = clip, .standing_flash = clip, .crouched_flash = clip, .standing_impact = clip, .crouched_impact = clip, .range_cells = 1, .palette_bank = 0, .behind_player = false };
    const first: motion.Pose = .{ .position = .{ .x = 64, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
    var second = first;
    second.position.x = 160;
    var state: State = .{};
    try state.advance(definition, .standing, first, id, view);
    try state.advance(definition, .standing, second, id, view);
    try std.testing.expectEqual(@as(u64, 1), state.shots_fired);
    try std.testing.expectEqual(first.position, state.effect.?.pose.position);
    try std.testing.expectEqual(@as(usize, 2), state.effect.?.playback.next_step);
    state.effect.?.phase = .impact;
    try state.advance(definition, .standing, second, id, view);
    try std.testing.expectEqual(@as(u64, 1), state.shots_fired);
    definition.retrigger_impact = true;
    try state.advance(definition, .standing, second, id, view);
    try std.testing.expectEqual(@as(u64, 2), state.shots_fired);
    try std.testing.expectEqual(second.position, state.effect.?.pose.position);
}
