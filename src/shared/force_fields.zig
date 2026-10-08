//! Reusable projectile barriers deployed by equipment. Each emitter owns its animation,
//! recovery and impact response; Conrad remains free to move and use his weapon.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const combat = @import("combat.zig");
const contacts = @import("contacts.zig");
const terrain = @import("terrain.zig");
pub const Phase = enum { ready, checking_rear, shielding, recovering, absorbing };
pub const Definition = struct {
    rear: bool,
    deploy: motion.Position,
    impact: motion.Position,
    idle: motion.Clip,
    checking: motion.Clip,
    shielding: motion.Clip,
    recovery: motion.Clip,
    absorption: motion.Clip,
    rear_range: u16,
    width: u8,
    palette_bank: u4,
    behind_player: bool,
};
pub const Emitter = struct {
    phase: Phase = .ready,
    room: ?geometry.RoomId = null,
    pose: motion.Pose = .{
        .position = .{ .x = 0, .y = 0 },
        .visual = .{ .id = @fromBackingInt(0) },
        .facing = .right,
    },
    playback: motion.Playback = .{},
    hit: bool = false,
    sound: ?motion.SoundId = null,
    fn currentClip(self: Emitter, definition: Definition) motion.Clip {
        return switch (self.phase) {
            .ready => definition.idle,
            .checking_rear => definition.checking,
            .shielding => definition.shielding,
            .recovering => definition.recovery,
            .absorbing => definition.absorption,
        };
    }
    pub fn body(self: Emitter, definition: Definition) ?contacts.Footprint {
        return if (self.room) |room| .{
            .room = room,
            .position = self.pose.position,
            .width = definition.width,
        } else null;
    }
    pub fn target(
        self: Emitter,
        definition: Definition,
        id: combat.Id,
        fallback_room: geometry.RoomId,
    ) combat.Target {
        return .{
            .id = id,
            .category = .mechanism,
            .footprint = self.body(definition) orelse .{
                .room = fallback_room,
                .position = self.pose.position,
                .width = 0,
            },
            .facing = self.pose.facing,
            .active = self.room != null and self.phase == .shielding,
            .vulnerable = .{
                .front_high = true,
                .front_low = true,
                .rear_high = true,
                .rear_low = true,
            },
        };
    }
    fn attach(
        self: *Emitter,
        player: motion.Pose,
        room: geometry.RoomId,
        delta: motion.Position,
        map: geometry.Map,
    ) !void {
        self.pose = player;
        self.pose.position.x +%= if (player.facing == .left) delta.x else -delta.x;
        self.pose.position.y +%= delta.y;
        var location = room;
        _ = try map.handoff(&location, &self.pose.position);
        self.room = location;
    }
    pub fn advance(
        self: *Emitter,
        definition: Definition,
        deploy: bool,
        player: motion.Pose,
        room: geometry.RoomId,
        view: terrain.View,
        targets: []const combat.Target,
    ) !void {
        self.sound = null;
        var clip = self.currentClip(definition);
        if (self.hit and
            self.phase == .shielding) self.playback.completeDisplacement(clip, &self.pose);
        if (self.playback.exhausted(clip)) {
            switch (self.phase) {
                .ready => if (deploy) {
                    try self.attach(player, room, definition.deploy, view.geometry);
                    self.phase = if (definition.rear) .checking_rear else .shielding;
                },
                .checking_rear => {
                    if (try enemyBehind(
                        view,
                        self.room.?,
                        self.pose,
                        definition.rear_range,
                        targets,
                    )) self.phase = .shielding else {
                        self.room = null;
                        self.phase = .ready;
                    }
                },
                .shielding => if (self.hit) {
                    try self.attach(player, room, definition.impact, view.geometry);
                    self.phase = .absorbing;
                } else {
                    self.room = null;
                    self.phase = if (definition.rear) .ready else .recovering;
                },
                .recovering => self.phase = .ready,
                .absorbing => {
                    self.room = null;
                    self.phase = .ready;
                },
            }
            self.playback = .{};
            clip = self.currentClip(definition);
        }
        self.hit = false;
        self.sound = self.playback.soundOnEntry(clip);
        _ = self.playback.advance(clip, &self.pose);
    }
    pub fn hashInto(self: Emitter, hash: *std.hash.Wyhash) void {
        for ([_]u64{
            @backingInt(self.phase),
            if (self.room) |room| 1 + @as(u64, @backingInt(room)) else 0,
            @as(u16, @bitCast(self.pose.position.x)),
            @as(u16, @bitCast(self.pose.position.y)),
            @backingInt(self.pose.facing),
            @backingInt(self.pose.visual.id),
            @intFromBool(self.pose.visual.mirrored),
            self.playback.next_step,
            @intFromBool(self.hit),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};

/// Rear deployment is conditional on a living actor along the unobstructed rear ray.
/// Unlike a shot, this query does not require a damage-vulnerable animation pose.
fn enemyBehind(
    view: terrain.View,
    room: geometry.RoomId,
    pose: motion.Pose,
    range: u16,
    targets: []const combat.Target,
) !bool {
    const row = @divTrunc(pose.position.y, 72);
    if (row < 0 or row > 2) return false;
    const direction: i16 = if (pose.facing == .right) -1 else 1;
    var column = ((pose.position.x +% 8) >> 4) + direction;
    var location = room;
    const layout: contacts.Layout = .{};
    for (0..@as(usize, range) + 1) |_| {
        const cell = try view.geometry.locate(location, column, row * 2 + 1) orelse return false;
        for (targets) |target| {
            if (!target.active or
                (target.category != .player and target.category != .enemy)) continue;
            for (0..target.footprint.width) |offset| {
                const other = try layout.cell(
                    view.geometry,
                    target.footprint.room,
                    .{
                        .x = target.footprint.position.x +% @as(i16, @intCast(offset)) *% 16,
                        .y = target.footprint.position.y,
                    },
                ) orelse continue;
                if (other.room == cell.room and
                    other.column == cell.column and
                    other.row == row) return true;
            }
        }
        if (try view.sample(location, column, row * 2 + 1) != .empty) return false;
        location = cell.room;
        column = @as(i16, @intCast(cell.column)) + direction;
    }
    return false;
}
