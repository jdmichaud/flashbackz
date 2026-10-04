//! One reusable casing emitter with authored ejection trajectories. Some trajectories
//! finish before accepting another ejection; the standing alternate can be replaced.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
pub const Height = enum { standing, crouched };
pub const Path = enum { standing_a, standing_b, crouched_a, crouched_b };
pub const Definition = struct {
    trajectories: [4]motion.Clip,
    initial_pose: motion.Pose,
    initial_room: ?geometry.RoomId,
    initial_path: Path,
    palette_bank: u4,
    behind_player: bool,
    fn clip(self: Definition, path: Path) motion.Clip {
        return self.trajectories[@backingInt(path)];
    }
};
pub const Flight = struct {
    pose: motion.Pose,
    room: ?geometry.RoomId,
    path: Path,
    playback: motion.Playback = .{},
};
pub const State = struct {
    first_ejection: bool = true,
    flight: ?Flight = null,
    pub fn advance(self: *State, definition: Definition, shot: ?Height, pose: motion.Pose, room: geometry.RoomId, random: anytype) void {
        const accepts = if (self.flight) |flight| flight.path == .standing_a else true;
        if (shot != null and accepts) {
            if (self.first_ejection) {
                self.flight = .{ .pose = definition.initial_pose, .room = definition.initial_room, .path = definition.initial_path };
                self.first_ejection = false;
            } else {
                const alternate = random.next() & 1 != 0;
                const path: Path = if (shot.? == .standing) (if (alternate) .standing_b else .standing_a) else (if (alternate) .crouched_b else .crouched_a);
                self.flight = .{ .pose = pose, .room = room, .path = path };
            }
        }
        if (self.flight) |*flight| {
            const clip = definition.clip(flight.path);
            if (flight.playback.exhausted(clip)) {
                self.flight = null;
            } else _ = flight.playback.advance(clip, &flight.pose);
        }
    }
    pub fn hashInto(self: State, hash: *std.hash.Wyhash) void {
        hash.update(&.{ @intFromBool(self.first_ejection), @intFromBool(self.flight != null) });
        if (self.flight) |flight| {
            for ([_]u32{ if (flight.room) |room| @backingInt(room) else std.math.maxInt(u32), @as(u16, @bitCast(flight.pose.position.x)), @as(u16, @bitCast(flight.pose.position.y)), @backingInt(flight.pose.facing), @backingInt(flight.pose.visual.id), @intFromBool(flight.pose.visual.mirrored), @backingInt(flight.path), @intCast(flight.playback.next_step) }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        }
    }
};

test "a busy casing suppresses both another ejection and its random draw" {
    const hold = [_]motion.Step{ .hold, .hold };
    const clip: motion.Clip = .{ .steps = &hold };
    const pose: motion.Pose = .{ .position = .{ .x = 10, .y = 70 }, .facing = .right, .visual = .{ .id = @fromBackingInt(0) } };
    const definition: Definition = .{ .trajectories = .{ clip, clip, clip, clip }, .initial_pose = pose, .initial_room = null, .initial_path = .standing_b, .palette_bank = 2, .behind_player = false };
    const CountingRandom = struct {
        calls: usize = 0,
        pub fn next(self: *@This()) u16 {
            self.calls += 1;
            return 0;
        }
    };
    var random: CountingRandom = .{};
    var state: State = .{};
    const room: geometry.RoomId = @fromBackingInt(1);
    for (0..3) |_| state.advance(definition, .standing, pose, room, &random);
    try std.testing.expect(state.flight == null);
    try std.testing.expectEqual(@as(usize, 0), random.calls);
    state.advance(definition, .standing, pose, room, &random);
    state.advance(definition, .standing, pose, room, &random);
    try std.testing.expectEqual(@as(usize, 2), random.calls);
    try std.testing.expectEqual(@as(usize, 1), state.flight.?.playback.next_step);
}
