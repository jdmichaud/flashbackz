//! Signal-driven ceiling guns. Deployment, charge and recovery timing come from content;
//! the weapon system owns emitted shots and their damage.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const activation = @import("activation.zig");
pub const CircuitId = world_props.CircuitId;
const world_props = @import("world_props.zig");
pub const Phase = enum { closed, deploying, waiting, charging, firing, cooling, retracting };
pub const Cycle = enum { repeating, retract_after_shot, per_signal };
pub const Profile = struct {
    clips: [7]motion.Clip,
    cycle: Cycle,
    cooling_wait: i16,
    fn clip(self: Profile, phase: Phase) motion.Clip {
        return self.clips[@backingInt(phase)];
    }
};
pub const Definition = struct {
    profile: usize,
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    initial_wait: i16,
    charge_wait: i16,
    repeat_wait: i16,
    weapon: usize,
    shot_next_step: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    palette_bank: u4,
    behind_player: bool,
};
pub const Action = enum { trigger, rearm, stop, wake };
pub const Binding = struct { circuit: CircuitId, target: usize, action: Action, next_step: bool };
const Requests = struct {
    wake: bool = false,
    trigger: bool = false,
    rearm: bool = false,
    stop: bool = false,
    fn add(self: *Requests, action: Action) void {
        self.wake = true;
        switch (action) {
            .trigger => self.trigger = true,
            .rearm => self.rearm = true,
            .stop => self.stop = true,
            .wake => {},
        }
    }
};
pub const Instance = struct {
    pose: motion.Pose,
    phase: Phase = .closed,
    playback: motion.Playback = .{},
    active: bool,
    timer: i16 = 0,
    requests: Requests = .{},
    pending: Requests = .{},
    sound: ?motion.SoundId = null,
    fire: bool = false,
    fn countdown(self: *Instance) bool {
        self.timer -%= 1;
        return self.timer == 0;
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const Definition,
        profiles: []const Profile,
    ) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const first = switch (profiles[definition.profile].clip(.closed).steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingCeilingGunVisual,
            };
            instance.* = .{
                .pose = .{
                    .position = definition.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = first.id,
                        .mirrored = first.mirrored != (definition.facing == .left),
                    },
                },
                .active = definition.initially_active,
            };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        for (self.instances) |*instance| {
            instance.requests = instance.pending;
            instance.pending = .{};
            instance.sound = null;
            instance.fire = false;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const CircuitId) void {
        for (bindings) |binding| for (pulses) |pulse| if (pulse == binding.circuit) {
            const instance = &self.instances[binding.target];
            if (binding.next_step) instance.pending.add(binding.action) else instance.requests.add(binding.action);
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        profiles: []const Profile,
        map: geometry.Map,
        player_room: geometry.RoomId,
    ) !void {
        for (self.instances, definitions) |*instance, definition| {
            const near = try activation.around(
                map,
                player_room,
                definition.room,
                instance.pose.position.y,
            );
            if (definition.wake_nearby and near.wake) instance.active = true;
            if (instance.requests.wake and
                (instance.active or
                    definition.accepts_signals)) instance.active = true else instance.requests = .{};
            if (!instance.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clip(instance.phase);
            const trigger = instance.requests.trigger or instance.requests.rearm;
            const interrupted = switch (instance.phase) {
                .closed => trigger,
                .waiting => if (profile.cycle == .per_signal) trigger else profile.cycle == .retract_after_shot and
                    instance.requests.stop,
                .cooling => profile.cycle == .retract_after_shot and instance.requests.rearm,
                else => false,
            };
            if (interrupted) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                var audible = true;
                switch (instance.phase) {
                    .closed => if (trigger) {
                        instance.phase = .deploying;
                    } else {
                        audible = false;
                        if (!definition.wake_nearby or !near.near) instance.active = false;
                    },
                    .deploying => {
                        instance.timer = definition.initial_wait;
                        instance.phase = if (profile.cycle == .per_signal) .charging else .waiting;
                    },
                    .waiting => switch (profile.cycle) {
                        .per_signal => if (trigger) {
                            instance.timer = definition.initial_wait;
                            instance.phase = .charging;
                        } else if (!near.same) {
                            instance.phase = .retracting;
                        },
                        .repeating, .retract_after_shot => {
                            if (profile.cycle == .retract_after_shot and
                                instance.requests.stop) instance.phase = .retracting else if (instance.countdown())
                            {
                                instance.timer = definition.charge_wait;
                                instance.phase = .charging;
                            } else if (profile.cycle == .repeating and !near.same) {
                                audible = false;
                                if (!definition.wake_nearby or !near.near) instance.active = false;
                            }
                        },
                    },
                    .charging => if (instance.countdown()) {
                        instance.phase = .firing;
                    },
                    .firing => {
                        instance.fire = true;
                        instance.timer = profile.cooling_wait;
                        instance.phase = if (profile.cycle == .per_signal) .waiting else .cooling;
                    },
                    .cooling => if (profile.cycle == .repeating or instance.requests.rearm) {
                        instance.timer = definition.repeat_wait;
                        instance.phase = .waiting;
                    } else if (instance.countdown()) {
                        instance.phase = .retracting;
                    },
                    .retracting => instance.phase = .closed,
                }
                instance.playback = .{};
                clip = profile.clip(instance.phase);
                if (audible) instance.sound = clip.sound;
            }
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            hash.update(&.{
                @backingInt(instance.phase),
                @intFromBool(instance.active),
                @intFromBool(instance.fire),
            });
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, instance.timer)));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, instance.playback.next_step)));
            for ([_]Requests{ instance.requests, instance.pending }) |r| hash.update(&.{
                @intFromBool(r.wake),
                @intFromBool(r.trigger),
                @intFromBool(r.rearm),
                @intFromBool(r.stop),
            });
        }
    }
};
