//! Authored throw arcs and terrain responses. The motion data supplies the exact path;
//! this component owns flight, rebound, falling and settling in connected rooms.
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
pub const Stage = struct {
    clip: motion.Clip,
    rebound: ?struct { clip: motion.Clip, may_fall: bool } = null,
    finish: enum { next, drop_or_next, edge_or_next, settle },
};
pub const Definition = struct {
    arc: []const Stage,
    drop_start: motion.Clip,
    drop_continue: motion.Clip,
    drop_rebound: motion.Clip,
    edge_descent: motion.Clip,
    falling: motion.Clip,
    landing: motion.Clip,
    rest: motion.Clip,
    fall_entry_down: i16,
};
pub const Phase = union(enum) { arc: usize, rebound: usize, drop_start, drop_continue, drop_rebound, edge_descent, falling, landing, resting };
pub const Event = struct { sound: ?motion.SoundId = null, settled: bool = false, lost: bool = false };
pub const State = struct {
    phase: Phase = .{ .arc = 0 },
    pub fn clip(self: State, definition: Definition) motion.Clip {
        return switch (self.phase) {
            .arc => |index| definition.arc[index].clip,
            .rebound => |index| definition.arc[index].rebound.?.clip,
            .drop_start => definition.drop_start,
            .drop_continue => definition.drop_continue,
            .drop_rebound => definition.drop_rebound,
            .edge_descent => definition.edge_descent,
            .falling => definition.falling,
            .landing => definition.landing,
            .resting => definition.rest,
        };
    }
    fn blocked(map: geometry.Map, room: geometry.RoomId, pose: motion.Pose, height: enum { body, support }, ahead: i16) !bool {
        const column = (pose.position.x +% 8) >> 4;
        const band = @divTrunc(pose.position.y, 36) & ~@as(i16, 1);
        return map.blocked(room, column +% (if (pose.facing == .right) ahead else -%ahead), band + if (height == .body) @as(i16, 1) else 2);
    }
    fn fall(self: *State, definition: Definition, pose: *motion.Pose) void {
        self.phase = .falling;
        pose.position.y +%= definition.fall_entry_down;
    }
    pub fn advance(self: *State, definition: Definition, playback: *motion.Playback, pose: *motion.Pose, room: *geometry.RoomId, map: geometry.Map) !Event {
        var selected = self.clip(definition);
        if (playback.exhausted(selected)) {
            switch (self.phase) {
                .arc => |index| {
                    const stage = definition.arc[index];
                    if (stage.rebound != null and try blocked(map, room.*, pose.*, .body, 0)) self.phase = .{ .rebound = index } else switch (stage.finish) {
                        .next => self.phase = .{ .arc = index + 1 },
                        .drop_or_next => self.phase = if (!try blocked(map, room.*, pose.*, .support, 0)) .drop_start else .{ .arc = index + 1 },
                        .edge_or_next => self.phase = if (!try blocked(map, room.*, pose.*, .support, 1)) .edge_descent else .{ .arc = index + 1 },
                        .settle => self.phase = .resting,
                    }
                },
                .rebound => |index| {
                    if (definition.arc[index].rebound.?.may_fall and !try blocked(map, room.*, pose.*, .support, 0)) self.fall(definition, pose) else self.phase = .resting;
                },
                .drop_start => self.phase = if (try blocked(map, room.*, pose.*, .body, 0)) .drop_rebound else .drop_continue,
                .drop_continue, .drop_rebound, .falling => {
                    if (!try blocked(map, room.*, pose.*, .support, 0)) self.fall(definition, pose) else self.phase = .landing;
                },
                .edge_descent => {
                    if (!try blocked(map, room.*, pose.*, .support, 0)) self.fall(definition, pose) else self.phase = .resting;
                },
                .landing => self.phase = .resting,
                .resting => {},
            }
            playback.* = .{};
            _ = map.handoff(room, &pose.position) catch |err| switch (err) {
                error.ExitWithoutDestination => return .{ .lost = true },
                else => return err,
            };
            selected = self.clip(definition);
        }
        const sound = playback.soundOnEntry(selected);
        _ = playback.advance(selected, pose);
        return .{ .sound = sound, .settled = self.phase == .resting };
    }
};
