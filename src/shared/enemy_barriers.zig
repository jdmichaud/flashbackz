//! Signal-triggered defensive fields copy their owner's pose on deployment, then remain
//! independent. Impact height selects a local absorption offset and reflection.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const combat = @import("combat.zig");
pub const Owner = struct { pose: motion.Pose, room: geometry.RoomId };
pub const Phase = enum { ready, shielding, recovering, absorbing };
pub const Definition = struct {
    initial_position: motion.Position,
    initial_facing: motion.Facing,
    initially_active: bool,
    clips: [4]motion.Clip,
    deploy: motion.Position,
    impact_down: [2]i16,
    width: u8,
    palette_bank: u4,
    behind_player: bool,
};
pub const Binding = struct {
    circuit: @import("world_props.zig").CircuitId,
    emitter: usize,
    owner: usize,
    next_step: bool,
};
pub const Emitter = struct {
    phase: Phase = .ready,
    active: bool = false,
    room: ?geometry.RoomId = null,
    pose: motion.Pose = .{
        .position = .{ .x = 0, .y = 0 },
        .visual = .{ .id = @fromBackingInt(0) },
    },
    playback: motion.Playback = .{},
    requester: ?usize = null,
    pending: ?usize = null,
    hits: combat.ImpactSet = .{},
    sound: ?motion.SoundId = null,
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
        fallback: geometry.RoomId,
    ) combat.Target {
        return .{
            .id = id,
            .category = .enemy,
            .footprint = self.body(definition) orelse .{
                .room = fallback,
                .position = self.pose.position,
                .width = 0,
            },
            .facing = self.pose.facing,
            .active = self.room != null,
            .vulnerable = if (self.phase == .shielding) .{
                .front_high = true,
                .front_low = true,
            } else .{},
        };
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    emitters: []Emitter,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const emitters = try allocator.alloc(Emitter, definitions.len);
        for (emitters, definitions) |*emitter, definition| emitter.* = .{
            .active = definition.initially_active,
            .pose = .{
                .position = definition.initial_position,
                .facing = definition.initial_facing,
                .visual = .{ .id = @fromBackingInt(0) },
            },
        };
        return .{ .allocator = allocator, .emitters = emitters };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.emitters);
    }
    pub fn beginStep(self: *World) void {
        for (self.emitters) |*emitter| {
            emitter.requester = emitter.pending;
            emitter.pending = null;
            emitter.sound = null;
        }
    }
    pub fn route(
        self: *World,
        bindings: []const Binding,
        pulses: []const @import("world_props.zig").CircuitId,
    ) void {
        for (pulses) |pulse| for (bindings) |binding| if (pulse == binding.circuit) {
            if (binding.next_step) self.emitters[binding.emitter].pending = binding.owner else self.emitters[binding.emitter].requester = binding.owner;
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        owners: []const Owner,
        map: geometry.Map,
    ) !void {
        for (self.emitters, definitions) |*emitter, definition| {
            if (emitter.requester != null) emitter.active = true;
            if (!emitter.active) {
                emitter.hits = .{};
                continue;
            }
            var clip = definition.clips[@backingInt(emitter.phase)];
            const request = emitter.requester != null and
                (emitter.phase == .ready or emitter.phase == .absorbing);
            const hit = emitter.phase == .shielding and
                (emitter.hits.front_high or emitter.hits.front_low);
            if (request or hit) emitter.playback.completeDisplacement(clip, &emitter.pose);
            if (emitter.playback.exhausted(clip)) {
                if (request) {
                    const turn = emitter.phase == .absorbing;
                    const owner = owners[emitter.requester.?];
                    emitter.pose = owner.pose;
                    if (turn) emitter.pose.facing = if (emitter.pose.facing == .left) .right else .left;
                    emitter.pose.position.x +%= if (emitter.pose.facing == .left) definition.deploy.x else -definition.deploy.x;
                    emitter.pose.position.y +%= definition.deploy.y;
                    var room = owner.room;
                    _ = try map.handoff(&room, &emitter.pose.position);
                    emitter.room = room;
                    emitter.phase = .shielding;
                } else switch (emitter.phase) {
                    .ready => emitter.active = false,
                    .shielding => if (hit) {
                        emitter.pose.facing = if (emitter.pose.facing == .left) .right else .left;
                        emitter.pose.position.y +%= definition.impact_down[@intFromBool(!emitter.hits.front_high)];
                        emitter.phase = .absorbing;
                    } else {
                        emitter.room = null;
                        emitter.phase = .recovering;
                    },
                    .recovering => emitter.phase = .ready,
                    .absorbing => {
                        emitter.pose.facing = if (emitter.pose.facing == .left) .right else .left;
                        emitter.room = null;
                        emitter.phase = .ready;
                    },
                }
                emitter.playback = .{};
                clip = definition.clips[@backingInt(emitter.phase)];
            }
            emitter.requester = null;
            emitter.hits = .{};
            emitter.sound = emitter.playback.soundOnEntry(clip);
            _ = emitter.playback.advance(clip, &emitter.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.emitters) |emitter| for ([_]u64{
            @backingInt(emitter.phase),
            @intFromBool(emitter.active),
            if (emitter.room) |room| @backingInt(room) else 0,
            @as(u16, @bitCast(emitter.pose.position.x)),
            @as(u16, @bitCast(emitter.pose.position.y)),
            @backingInt(emitter.pose.facing),
            @backingInt(emitter.pose.visual.id),
            @intFromBool(emitter.pose.visual.mirrored),
            emitter.playback.next_step,
            if (emitter.requester) |owner| owner + 1 else 0,
            if (emitter.pending) |owner| owner + 1 else 0,
            @intFromBool(emitter.hits.front_high),
            @intFromBool(emitter.hits.front_low),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
