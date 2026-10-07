//! Reusable weapon channels. Several actors can share a channel; content supplies event
//! latency, while each channel owns its effect and processes one discharge per update.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const combat = @import("combat.zig");
const pistol = @import("pistol_shot.zig");
pub const Request = struct { pose: motion.Pose, room: geometry.RoomId, height: combat.Height, airborne: bool = false };
pub const Channel = struct {
    state: pistol.State = .{},
    ready: ?Request = null,
    pending: ?Request = null,
    fn merge(slot: *?Request, request: Request) void {
        // Standing, crouched, then airborne discharges have priority; equal styles
        // retain the latest sender through a shared emitter.
        const order = struct {
            fn rank(value: Request) u2 {
                return if (value.height == .standing) 0 else if (value.airborne) 2 else 1;
            }
        }.rank;
        if (slot.* == null or order(request) <= order(slot.*.?)) slot.* = request;
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    channels: []Channel,
    pub fn init(allocator: std.mem.Allocator, count: usize) !World {
        const channels = try allocator.alloc(Channel, count);
        @memset(channels, .{});
        return .{ .allocator = allocator, .channels = channels };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.channels);
    }
    pub fn beginStep(self: *World) void {
        for (self.channels) |*channel| {
            channel.ready = channel.pending;
            channel.pending = null;
        }
    }
    pub fn fire(self: *World, channel: usize, request: Request, next_step: bool) void {
        Channel.merge(if (next_step) &self.channels[channel].pending else &self.channels[channel].ready, request);
    }
    pub fn advance(self: *World, definitions: []const pistol.Definition, terrain: @import("terrain.zig").View, targets: []const combat.Target) !void {
        for (self.channels, definitions) |*channel, definition| {
            const request = channel.ready;
            channel.ready = null;
            if (request) |shot| try channel.state.advanceWithVariant(definition, shot.height, shot.airborne, shot.pose, shot.room, terrain, targets) else if (channel.state.effect) |effect| try channel.state.advanceWithTargets(definition, null, effect.pose, effect.room, terrain, targets) else {
                channel.state.hit_requested = null;
                channel.state.sound_requested = null;
            }
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.channels) |channel| {
            channel.state.hashInto(hash);
            for ([_]?Request{ channel.ready, channel.pending }) |request| {
                hash.update(&.{@intFromBool(request != null)});
                if (request) |shot| for ([_]u16{ @bitCast(shot.pose.position.x), @bitCast(shot.pose.position.y), @backingInt(shot.pose.facing), @backingInt(shot.room), @backingInt(shot.height), @intFromBool(shot.airborne) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, value)));
            }
        }
    }
};
