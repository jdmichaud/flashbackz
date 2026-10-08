//! Authored aperture tracks with explicit clearance landmarks and reversal points.
//! Circuits request movement; terrain and animation share the same boundary update.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const terrain = @import("terrain.zig");
const contacts = @import("contacts.zig");
const activation = @import("activation.zig");
const combat = @import("combat.zig");
pub const CircuitId = world_props.CircuitId;
const world_props = @import("world_props.zig");
pub const Phase = enum { closed, opening, open, closing };
pub const Pass = enum { before_fire, after_fire };
pub const Reverse = struct { segment: usize, clearance: ?terrain.Material = null };
pub const Segment = struct {
    clip: motion.Clip,
    clearance_after: ?terrain.Material = null,
    reverse: ?Reverse = null,
};
pub const Profile = struct {
    closed: motion.Clip,
    open: motion.Clip,
    opening: []const Segment,
    closing: []const Segment,
    automatic_open: bool,
    shoot_to_open: bool,
    snap_closed: [4]bool,
    keep_open_request: bool,
    hold_player: bool,
    hold_enemies: bool,
    sleep_closed: bool,
    sleep_open: bool,
    start_closing_clearance: ?terrain.Material,
};
pub const Definition = struct {
    profile: usize,
    footprint: contacts.Footprint,
    facing: motion.Facing,
    span: terrain.Span,
    initial_phase: Phase,
    initial_segment: usize = 0,
    pass: Pass,
    hold_steps: ?i16,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    palette_bank: u4,
    behind_player: bool,
    enemy_contact: bool,
};
pub const Action = enum { open, close, snap_closed, wake };
pub const Binding = struct { circuit: CircuitId, target: usize, action: Action, next_step: bool };
const Requests = struct {
    wake: bool = false,
    open: bool = false,
    close: bool = false,
    snap: bool = false,
    fn add(self: *Requests, action: Action) void {
        self.wake = true;
        switch (action) {
            .open => self.open = true,
            .close => self.close = true,
            .snap_closed => self.snap = true,
            .wake => {},
        }
    }
};
pub const Instance = struct {
    pose: motion.Pose,
    phase: Phase,
    segment: usize = 0,
    playback: motion.Playback = .{},
    active: bool,
    timer: i16 = 0,
    requests: Requests = .{},
    pending: Requests = .{},
    sound: ?motion.SoundId = null,
    fn clip(self: Instance, profile: Profile) motion.Clip {
        return switch (self.phase) {
            .closed => profile.closed,
            .open => profile.open,
            .opening => profile.opening[self.segment].clip,
            .closing => profile.closing[self.segment].clip,
        };
    }
    pub fn vulnerability(self: Instance, profile: Profile) combat.Vulnerability {
        return if (profile.shoot_to_open and self.phase == .closed) .{
            .rear_high = true,
            .rear_low = true,
            .front_high = true,
            .front_low = true,
        } else .{};
    }
    fn accepts(self: Instance, profile: Profile) bool {
        if (self.requests.snap and profile.snap_closed[@backingInt(self.phase)]) return true;
        return switch (self.phase) {
            .closed => self.requests.open and
                !profile.automatic_open or
                self.requests.close and
                    profile.automatic_open,
            .open => self.requests.open and
                profile.keep_open_request or
                self.requests.close and
                    profile.closing.len != 0,
            .opening => self.requests.close and profile.opening[self.segment].reverse != null,
            .closing => self.requests.open and profile.closing[self.segment].reverse != null,
        };
    }
    fn set(self: *Instance, phase: Phase, segment: usize) void {
        self.phase = phase;
        self.segment = segment;
    }
    fn write(definition: Definition, world: *terrain.State, material: ?terrain.Material) !void {
        if (material) |value| _ = try world.replace(definition.span, value);
    }
    fn close(self: *Instance, definition: Definition, world: *terrain.State) !void {
        try write(definition, world, .solid);
        self.set(.closed, 0);
    }
    fn occupied(
        definition: Definition,
        profile: Profile,
        map: geometry.Map,
        participants: []const contacts.Participant,
    ) !bool {
        const layout: contacts.Layout = .{};
        for (participants) |participant| {
            if (!participant.active) continue;
            if ((participant.kind == .player and
                profile.hold_player or
                participant.kind == .enemy and
                    profile.hold_enemies) and
                try layout.overlaps(map, definition.footprint, participant.footprint)) return true;
        }
        return false;
    }
    fn finish(
        self: *Instance,
        definition: Definition,
        profile: Profile,
        world: *terrain.State,
        participants: []const contacts.Participant,
    ) !bool {
        const snap = self.requests.snap and profile.snap_closed[@backingInt(self.phase)];
        switch (self.phase) {
            .closed => {
                if (profile.automatic_open and self.requests.close or snap) try self.close(definition, world) else if (self.requests.open and !profile.automatic_open) self.set(.opening, 0) else {
                    try write(definition, world, .solid);
                    if (profile.automatic_open) self.set(.opening, 0) else return !profile.sleep_closed;
                }
            },
            .opening => {
                const segment = profile.opening[self.segment];
                if (self.requests.close and segment.reverse != null) {
                    const reverse = segment.reverse.?;
                    try write(definition, world, reverse.clearance);
                    self.set(.closing, reverse.segment);
                } else if (snap) try self.close(definition, world) else {
                    try write(definition, world, segment.clearance_after);
                    if (self.segment + 1 < profile.opening.len) self.segment += 1 else {
                        self.set(.open, 0);
                        if (definition.hold_steps) |steps| self.timer = steps;
                    }
                }
            },
            .open => {
                if (profile.automatic_open and self.requests.close) {
                    try write(definition, world, profile.start_closing_clearance);
                    self.set(.closing, 0);
                } else if (snap) try self.close(definition, world) else if (profile.keep_open_request and self.requests.open) {
                    if (definition.hold_steps) |steps| self.timer = steps;
                } else if (definition.hold_steps != null and try occupied(
                    definition,
                    profile,
                    world.map(),
                    participants,
                )) self.timer = definition.hold_steps.? else {
                    var closing = self.requests.close and profile.closing.len != 0;
                    if (!closing and definition.hold_steps != null) {
                        self.timer -%= 1;
                        closing = self.timer == 0;
                    }
                    if (closing) {
                        try write(definition, world, profile.start_closing_clearance);
                        self.set(.closing, 0);
                    } else {
                        try write(definition, world, .empty);
                        return !profile.sleep_open;
                    }
                }
            },
            .closing => {
                const segment = profile.closing[self.segment];
                if (snap) try self.close(definition, world) else if (self.requests.open and segment.reverse != null) {
                    const reverse = segment.reverse.?;
                    try write(definition, world, reverse.clearance);
                    self.set(.opening, reverse.segment);
                } else {
                    try write(definition, world, segment.clearance_after);
                    if (self.segment + 1 < profile.closing.len) self.segment += 1 else self.set(.closed, 0);
                }
            },
        }
        return true;
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    late_done: bool = false,
    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const Definition,
        profiles: []const Profile,
    ) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const profile = profiles[definition.profile];
            const clip = switch (definition.initial_phase) {
                .closed => profile.closed,
                .open => profile.open,
                .opening => profile.opening[definition.initial_segment].clip,
                .closing => profile.closing[definition.initial_segment].clip,
            };
            const visual = switch (clip.steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingDoorVisual,
            };
            instance.* = .{
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .phase = definition.initial_phase,
                .segment = definition.initial_segment,
                .active = definition.initially_active,
            };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn beginStep(self: *World) void {
        self.late_done = false;
        for (self.instances) |*instance| {
            instance.requests = instance.pending;
            instance.pending = .{};
            instance.sound = null;
        }
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const CircuitId) void {
        for (bindings) |binding| for (pulses) |pulse| if (binding.circuit == pulse) {
            const instance = &self.instances[binding.target];
            if (binding.next_step) instance.pending.add(binding.action) else instance.requests.add(binding.action);
        };
    }
    pub fn hit(self: *World, definitions: []const Definition, index: usize) void {
        if (definitions[index].pass == .after_fire and
            !self.late_done) self.instances[index].requests.add(.open) else self.instances[index].pending.add(.open);
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        profiles: []const Profile,
        world: *terrain.State,
        player_room: geometry.RoomId,
        participants: []const contacts.Participant,
        pass: Pass,
    ) !void {
        if (pass == .after_fire) self.late_done = true;
        for (self.instances, definitions) |*instance, definition| {
            if (definition.pass != pass) continue;
            const near = try activation.around(
                world.map(),
                player_room,
                definition.footprint.room,
                instance.pose.position.y,
            );
            if (definition.wake_nearby and near.wake) instance.active = true;
            if (instance.requests.wake and
                (instance.active or
                    definition.accepts_signals)) instance.active = true else instance.requests = .{};
            if (!instance.active) continue;
            const profile = profiles[definition.profile];
            var clip = instance.clip(profile);
            if (instance.accepts(profile)) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                const audible = try instance.finish(definition, profile, world, participants);
                if (!audible and (!definition.wake_nearby or !near.near)) instance.active = false;
                instance.playback = .{};
                clip = instance.clip(profile);
                if (audible) instance.sound = clip.sound;
            }
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            hash.update(&.{ @backingInt(instance.phase), @intFromBool(instance.active) });
            for ([_]u64{
                instance.segment,
                instance.playback.next_step,
                @as(u16, @bitCast(instance.timer)),
            }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            for ([_]Requests{ instance.requests, instance.pending }) |r| hash.update(&.{
                @intFromBool(r.wake),
                @intFromBool(r.open),
                @intFromBool(r.close),
                @intFromBool(r.snap),
            });
        }
    }
};
