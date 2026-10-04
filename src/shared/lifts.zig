//! Two-stop platforms. Authored departure/travel/arrival clips determine when support
//! is removed and restored. Passenger ownership belongs to the scene; this component
//! reports boarding, displacement and release events instead of moving actor internals.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const terrain = @import("terrain.zig");
const props = @import("world_props.zig");
pub const Stop = enum { top, bottom };
pub const Phase = enum { parked, departing, travelling, arriving, disabled };
pub const Trip = struct {
    departure: motion.Clip,
    movement: motion.Clip,
    arrival: ?motion.Clip,
    speed: i16,
    arrival_sound: ?motion.SoundId = null,
};
pub const StopPolicy = struct {
    idle: motion.Clip,
    has_floor: bool = true,
    floor_on_blocked_request: bool = false,
    sleep_when_empty: bool = true,
    release_passengers: bool = true,
    accepts_player: bool = true,
    refuses_unboarded_items: bool = true,
    /// A parked countdown is installed on arrival, then decremented on idle boundaries.
    return_delay: ?i16 = null,
    pause_return_outside_room: bool = false,
};
pub const Profile = struct {
    stops: [2]StopPolicy,
    /// Indexed by the destination stop, not the departure point.
    trips: [2]Trip,
    disabled: ?motion.Clip = null,
    enabled_stop: Stop = .top,
};
pub const Event = enum { depart_up, depart_down, arrive_up, arrive_down };
pub const Output = struct { event: Event, circuit: props.CircuitId };
pub const Definition = struct {
    profile: usize,
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    width: u8,
    floor_row_offset: i16,
    history_weight: usize,
    history_reuse: terrain.Reuse,
    travel_steps: [2]i16,
    initial_stop: Stop,
    initially_disabled: bool = false,
    initially_active: bool,
    wake_nearby: bool,
    wake_on_contact: bool,
    accepts_signals: bool,
    palette_bank: u4,
    behind_player: bool,
    outputs: []const Output = &.{},
};
pub const Action = enum { go_up, go_down, restart_return_delay, enable, wake };
pub const Binding = struct { circuit: props.CircuitId, target: usize, action: Action, next_step: bool };
pub const Occupancy = struct { contacts: bool = false, unboarded_items: bool = false };
const Requests = struct {
    up: bool = false,
    down: bool = false,
    rider_up: bool = false,
    rider_down: bool = false,
    reset: bool = false,
    enable: bool = false,
    wake: bool = false,
    fn add(self: *Requests, action: Action) void {
        self.wake = true;
        switch (action) {
            .go_up => self.up = true,
            .go_down => self.down = true,
            .restart_return_delay => self.reset = true,
            .enable => self.enable = true,
            .wake => {},
        }
    }
};
pub const Instance = struct {
    pose: motion.Pose,
    room: geometry.RoomId,
    phase: Phase,
    stop: Stop,
    destination: Stop,
    playback: motion.Playback = .{},
    remaining: i16 = 0,
    active: bool,
    requests: Requests = .{},
    pending: Requests = .{},
    /// Events are valid until beginStep; consumers apply them in their own update order.
    displacement: i16 = 0,
    board_player: bool = false,
    invite_items: bool = false,
    release_passengers: bool = false,
    sound: ?motion.SoundId = null,
    event: ?Event = null,
    pub fn clip(self: Instance, profile: Profile) motion.Clip {
        const trip = profile.trips[@backingInt(self.destination)];
        return switch (self.phase) {
            .parked => profile.stops[@backingInt(self.stop)].idle,
            .departing => trip.departure,
            .travelling => trip.movement,
            .arriving => trip.arrival.?,
            .disabled => profile.disabled.?,
        };
    }
    pub fn footprint(self: Instance, definition: Definition) @import("contacts.zig").Footprint {
        return .{ .room = self.room, .position = self.pose.position, .width = definition.width };
    }
    fn floor(self: Instance, definition: Definition) terrain.Span {
        var column = @divFloor(@as(i32, self.pose.position.x) + 8, 16);
        if (self.pose.facing == .right) column -= definition.width - 1;
        const row = (@divTrunc(@as(i32, self.pose.position.y), 36) & ~@as(i32, 1)) + definition.floor_row_offset;
        return .{ .origin = .{ .room = self.room, .column = @intCast(column), .row = @intCast(row) }, .length = definition.width, .history_weight = definition.history_weight, .reuse = definition.history_reuse };
    }
    fn support(self: Instance, definition: Definition, world: *terrain.State) !void {
        _ = try world.replace(self.floor(definition), .solid);
    }
    fn move(self: *Instance, speed: i16) void {
        self.pose.position.y +%= speed;
        self.displacement +%= speed;
    }
    fn arrive(self: *Instance, definition: Definition, profile: Profile, world: *terrain.State) !void {
        const trip = profile.trips[@backingInt(self.destination)];
        self.stop = self.destination;
        if (profile.stops[@backingInt(self.stop)].has_floor) try self.support(definition, world);
        self.remaining = profile.stops[@backingInt(self.stop)].return_delay orelse 0;
        self.phase = if (trip.arrival != null) .arriving else .parked;
        self.sound = trip.arrival_sound;
        self.event = if (self.stop == .top) .arrive_up else .arrive_down;
    }
    fn finish(self: *Instance, definition: Definition, profile: Profile, world: *terrain.State, occupancy: Occupancy, player_room: geometry.RoomId) !void {
        switch (self.phase) {
            .disabled => {
                if (self.requests.enable) {
                    self.stop = profile.enabled_stop;
                    self.phase = .parked;
                } else {
                    try self.support(definition, world);
                    self.release_passengers = occupancy.contacts;
                    self.active = false;
                }
            },
            .parked => {
                const policy = profile.stops[@backingInt(self.stop)];
                if (policy.pause_return_outside_room and self.room != player_room) return;
                const target: Stop = if (self.stop == .top) .bottom else .top;
                var requested = if (target == .top) self.requests.up else self.requests.down;
                const rider = policy.accepts_player and (if (target == .top) self.requests.rider_up else self.requests.rider_down);
                requested = requested or rider;
                if (policy.return_delay != null and !(policy.pause_return_outside_room and self.room != player_room)) {
                    // Original automatic returns test countdown before a same-step reset.
                    self.remaining -%= 1;
                    requested = requested or self.remaining == 0;
                    if (!requested and self.requests.reset) self.remaining = policy.return_delay.?;
                }
                if (requested and !(policy.refuses_unboarded_items and occupancy.unboarded_items)) {
                    self.destination = target;
                    self.phase = .departing;
                    self.remaining = definition.travel_steps[@backingInt(target)];
                    self.board_player = rider;
                    self.event = if (target == .top) .depart_up else .depart_down;
                } else {
                    if (requested) self.invite_items = occupancy.unboarded_items;
                    self.release_passengers = !requested and policy.release_passengers and occupancy.contacts;
                    if (policy.has_floor and (!requested or policy.floor_on_blocked_request)) try self.support(definition, world);
                    if (policy.sleep_when_empty and !occupancy.contacts and !requested) self.active = false;
                }
            },
            .departing => {
                // Restore the saved terrain at the departure point, not a blanket empty row.
                _ = try world.restore(self.floor(definition).origin);
                self.remaining = definition.travel_steps[@backingInt(self.destination)];
                self.move(profile.trips[@backingInt(self.destination)].speed);
                self.phase = .travelling;
            },
            .travelling => {
                self.remaining -%= 1;
                if (self.remaining == 0) try self.arrive(definition, profile, world) else self.move(profile.trips[@backingInt(self.destination)].speed);
            },
            .arriving => self.phase = .parked,
        }
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []props.CircuitId,
    pulse_count: usize = 0,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, profiles: []const Profile) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        var output_count: usize = 0;
        for (instances, definitions) |*instance, definition| {
            instance.* = .{ .pose = .{ .position = definition.position, .facing = definition.facing, .visual = undefined }, .room = definition.room, .phase = if (definition.initially_disabled) .disabled else .parked, .stop = definition.initial_stop, .destination = definition.initial_stop, .active = definition.initially_active };
            const clip = instance.clip(profiles[definition.profile]);
            if (clip.steps.len == 0) return error.MissingLiftAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingLiftVisual,
            };
            instance.pose.visual = .{ .id = visual.id, .mirrored = visual.mirrored != (definition.facing == .left) };
            output_count += definition.outputs.len;
        }
        return .{ .allocator = allocator, .instances = instances, .pulses = try allocator.alloc(props.CircuitId, output_count) };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn beginStep(self: *World) void {
        self.pulse_count = 0;
        for (self.instances) |*instance| {
            instance.requests = instance.pending;
            instance.pending = .{};
            instance.displacement = 0;
            instance.board_player = false;
            instance.invite_items = false;
            instance.release_passengers = false;
            instance.sound = null;
            instance.event = null;
        }
    }
    pub fn requestRide(self: *World, index: usize, destination: Stop) void {
        self.instances[index].requests.wake = true;
        if (destination == .top) self.instances[index].requests.rider_up = true else self.instances[index].requests.rider_down = true;
    }
    pub fn route(self: *World, bindings: []const Binding, pulses: []const props.CircuitId) void {
        for (pulses) |pulse| for (bindings) |binding| {
            if (binding.circuit != pulse) continue;
            const requests = if (binding.next_step) &self.instances[binding.target].pending else &self.instances[binding.target].requests;
            requests.add(binding.action);
        };
    }
    pub fn advance(self: *World, definitions: []const Definition, profiles: []const Profile, world: *terrain.State, occupancy: []const Occupancy, player_room: geometry.RoomId) !void {
        for (self.instances, definitions, occupancy) |*instance, definition, contact| {
            const near = try @import("activation.zig").around(world.map(), player_room, instance.room, instance.pose.position.y);
            if (definition.wake_nearby and near.wake or definition.wake_on_contact and contact.contacts or instance.requests.wake and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            const profile = profiles[definition.profile];
            var clip = instance.clip(profile);
            const requested = instance.requests.up or instance.requests.down or instance.requests.rider_up or instance.requests.rider_down or instance.requests.reset or instance.requests.enable;
            if (requested and (instance.phase == .parked or instance.phase == .disabled)) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                try instance.finish(definition, profile, world, contact, player_room);
                if (!instance.active and definition.wake_nearby and near.near) instance.active = true;
                _ = try world.map().handoff(&instance.room, &instance.pose.position);
                instance.playback = .{};
                clip = instance.clip(profile);
                if (instance.active and instance.sound == null) instance.sound = clip.sound;
                if (instance.event) |event| for (definition.outputs) |output| {
                    if (output.event != event) continue;
                    self.pulses[self.pulse_count] = output.circuit;
                    self.pulse_count += 1;
                };
            }
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| {
            for ([_]u64{ @backingInt(instance.room), @as(u16, @bitCast(instance.pose.position.x)), @as(u16, @bitCast(instance.pose.position.y)), @backingInt(instance.phase), @backingInt(instance.stop), @backingInt(instance.destination), instance.playback.next_step, @as(u16, @bitCast(instance.remaining)), @intFromBool(instance.active) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            for ([_]Requests{ instance.requests, instance.pending }) |requests| hash.update(&.{ @intFromBool(requests.up), @intFromBool(requests.down), @intFromBool(requests.rider_up), @intFromBool(requests.rider_down), @intFromBool(requests.reset), @intFromBool(requests.enable), @intFromBool(requests.wake) });
        }
    }
};
