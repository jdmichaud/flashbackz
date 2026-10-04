//! Animated world detectors. Acquisition and continued detection may use different
//! senses; outputs are ordinary circuit pulses consumed by independent mechanisms.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const perception = @import("actors/perception.zig");
const activation = @import("activation.zig");
pub const CircuitId = @import("world_props.zig").CircuitId;
pub const Phase = enum { disabled, enabling, monitoring, detecting, disabling };
pub const Sense = union(enum) {
    player_front: i16,
    player_behind: i16,
    contacts: struct { kind: contacts.Kind, cells: u8, behind: bool },
};
pub const Profile = struct {
    clips: [5]motion.Clip,
    acquire: []const Sense,
    sustain: []const Sense,
    disable_after_pulse: bool,
    fn clip(self: Profile, phase: Phase) motion.Clip {
        return self.clips[@backingInt(phase)];
    }
};
pub const Definition = struct {
    profile: usize,
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    initial_phase: Phase,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    palette_bank: u4,
    behind_player: bool,
    outputs: []const CircuitId,
};
pub const Action = enum { enable, disable, wake };
pub const Binding = struct { circuit: CircuitId, target: usize, action: Action, next_step: bool };
const Requests = struct {
    wake: bool = false,
    enable: bool = false,
    disable: bool = false,
    fn add(self: *Requests, action: Action) void {
        self.wake = true;
        switch (action) {
            .enable => self.enable = true,
            .disable => self.disable = true,
            .wake => {},
        }
    }
};
pub const Instance = struct { pose: motion.Pose, phase: Phase, playback: motion.Playback = .{}, active: bool, requests: Requests = .{}, pending: Requests = .{}, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    scratch: []contacts.Footprint,
    pulses: []CircuitId,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, profiles: []const Profile, contact_capacity: usize) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        var outputs: usize = 0;
        for (instances, definitions) |*instance, definition| {
            const first = switch (profiles[definition.profile].clip(definition.initial_phase).steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingDetectorVisual,
            };
            instance.* = .{ .pose = .{ .position = definition.position, .facing = definition.facing, .visual = .{ .id = first.id, .mirrored = first.mirrored != (definition.facing == .left) } }, .phase = definition.initial_phase, .active = definition.initially_active };
            outputs += definition.outputs.len;
        }
        const scratch = try allocator.alloc(contacts.Footprint, contact_capacity);
        errdefer allocator.free(scratch);
        return .{ .allocator = allocator, .instances = instances, .scratch = scratch, .pulses = try allocator.alloc(CircuitId, outputs) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.scratch);
        self.allocator.free(self.pulses);
    }
    pub fn beginStep(self: *World) void {
        self.pulse_count = 0;
        for (self.instances) |*instance| {
            instance.requests = instance.pending;
            instance.pending = .{};
            instance.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const CircuitId) void {
        for (bindings) |binding| for (pulses) |pulse| if (pulse == binding.circuit) {
            const instance = &self.instances[binding.target];
            if (binding.next_step) instance.pending.add(binding.action) else instance.requests.add(binding.action);
        };
    }
    fn detects(self: *World, senses: []const Sense, observer: perception.Observer, map: geometry.Map, player: contacts.Footprint, participants: []const contacts.Participant) !bool {
        const awareness = try perception.observe(map, observer, player, &.{});
        const current = try map.room(player.room);
        const horizontal = observer.room == player.room or (current.edges.left == .room and current.edges.left.room == observer.room) or (current.edges.right == .room and current.edges.right.room == observer.room);
        for (senses) |sense| switch (sense) {
            .player_front => |range| if (awareness.player(false, range)) return true,
            .player_behind => |range| if (awareness.player(true, range)) return true,
            .contacts => |ray| {
                if (!horizontal) continue;
                var count: usize = 0;
                for (participants) |participant| if (participant.active and participant.kind == ray.kind) {
                    self.scratch[count] = participant.footprint;
                    count += 1;
                };
                const distance = try perception.scanObjects(map, player.room, observer, self.scratch[0..count], ray.behind);
                if (distance != null and distance.? <= ray.cells) return true;
            },
        };
        return false;
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, bindings: []const Binding, map: geometry.Map, player: contacts.Footprint, participants: []const contacts.Participant) !void {
        if (participants.len > self.scratch.len) return error.TooManyDetectorContacts;
        for (self.instances, definitions) |*instance, definition| {
            const neighborhood = try activation.around(map, player.room, definition.room, instance.pose.position.y);
            if (definition.wake_nearby and neighborhood.wake) instance.active = true;
            if (instance.requests.wake and (instance.active or definition.accepts_signals)) instance.active = true else instance.requests = .{};
            if (!instance.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clip(instance.phase);
            const interrupted = (instance.phase == .disabled and instance.requests.enable) or (instance.phase == .monitoring and instance.requests.disable);
            if (interrupted) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                var audible = true;
                var pulse = false;
                switch (instance.phase) {
                    .disabled => if (instance.requests.enable) {
                        instance.phase = .enabling;
                    } else {
                        audible = false;
                        if (!definition.wake_nearby or !neighborhood.near) instance.active = false;
                    },
                    .enabling => instance.phase = .monitoring,
                    .disabling => instance.phase = .disabled,
                    .monitoring => {
                        if (instance.requests.disable) instance.phase = .disabling else if (neighborhood.same and try self.detects(profile.acquire, .{ .room = definition.room, .pose = instance.pose }, map, player, participants)) {
                            instance.phase = .detecting;
                            pulse = true;
                        } else {
                            audible = false;
                            if (!definition.wake_nearby or !neighborhood.near) instance.active = false;
                        }
                    },
                    .detecting => if (profile.disable_after_pulse) {
                        instance.phase = .disabling;
                    } else if (try self.detects(profile.sustain, .{ .room = definition.room, .pose = instance.pose }, map, player, participants)) {
                        pulse = true;
                    } else {
                        instance.phase = .monitoring;
                    },
                }
                instance.playback = .{};
                clip = profile.clip(instance.phase);
                if (audible) instance.sound = clip.sound;
                if (pulse) {
                    @memcpy(self.pulses[self.pulse_count..][0..definition.outputs.len], definition.outputs);
                    self.pulse_count += definition.outputs.len;
                    self.route(bindings, definition.outputs);
                }
            }
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            hash.update(&.{ @backingInt(instance.phase), @intFromBool(instance.active) });
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, instance.playback.next_step)));
            for ([_]Requests{ instance.requests, instance.pending }) |r| hash.update(&.{ @intFromBool(r.wake), @intFromBool(r.enable), @intFromBool(r.disable) });
        }
    }
};
