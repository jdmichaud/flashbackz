//! Interactive development scene using shared content, locomotion and rendering. Its
//! application clock and event queue are independent of presentation and native hosts.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/jungle.zig");
const conrad = @import("../actors/conrad.zig");
const environment_mod = @import("../actors/conrad_environment.zig");
const motion = @import("../motion.zig");
const clock_mod = @import("../step_clock.zig");
const sprite_renderer = @import("../render/sprite.zig");
const palette = @import("../content/palette.zig");
const controls = @import("../actors/controls.zig");
const equipment_mod = @import("../equipment.zig");
const inventory_menu = @import("inventory_menu.zig");
const props_mod = @import("../world_props.zig");
const text_renderer = @import("../render/text.zig");
const options_mod = @import("game_options.zig");
const terrain_mod = @import("../terrain.zig");

pub const HeldInput = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    left_action: bool = false,
    right_action: bool = false,
    weapon: bool = false,
    inventory: bool = false,
    options: bool = false,
    use_item: bool = false,
    use_held: bool = false,
    use_blocked: bool = false,
    previous_direction: struct { horizontal: ?motion.Facing = null, vertical: ?controls.Vertical = null, conflict: bool = false } = .{},
    pub fn key(self: *HeldInput, key_code: platform.Key, down: bool) void {
        switch (key_code) {
            .left => self.left = down,
            .right => self.right = down,
            .up => self.up = down,
            .down => self.down = down,
            .left_shift => self.left_action = down,
            .right_shift => self.right_action = down,
            .space => self.weapon = down,
            .tab => self.inventory = down,
            .escape => self.options = down,
            .enter => {
                self.use_held = down;
                if (!down) self.use_blocked = false;
                self.use_item = down and !self.use_blocked;
            },
            else => {},
        }
    }
    pub fn recorded(self: *HeldInput, sample: @import("../input_recording.zig").Sample) void {
        self.left = sample.left;
        self.right = sample.right;
        self.up = sample.up;
        self.down = sample.down;
        self.left_action = sample.action;
        self.right_action = false;
        self.weapon = sample.weapon;
        self.inventory = sample.inventory;
        self.key(.enter, sample.use_item);
    }
    pub fn consumeUse(self: *HeldInput) void {
        self.use_item = false;
        self.use_blocked = self.use_held;
    }
    pub fn intent(self: *HeldInput) !conrad.Intent {
        const horizontal: ?motion.Facing = if (self.left and !self.right) .left else if (self.right and !self.left) .right else null;
        const vertical: ?controls.Vertical = if (self.up and !self.down) .up else if (self.down and !self.up) .down else null;
        // Mixed axes retain the last accepted direction, while the action modifier remains
        // current. This is the original input arbitration, expressed without a DOS bitmask.
        if (!(self.left or self.right) or !(self.up or self.down)) self.previous_direction = .{ .horizontal = horizontal, .vertical = vertical, .conflict = (self.left and self.right) or (self.up and self.down) };
        return .{ .direction = self.previous_direction.horizontal, .vertical = self.previous_direction.vertical, .action = self.left_action or self.right_action, .use_item = self.use_item, .weapon = self.weapon, .directions_conflict = self.previous_direction.conflict };
    }
};

fn consumeInput(pending: *std.ArrayList(platform.Event), held: *HeldInput, deadline: u64) !void {
    while (pending.items.len != 0 and pending.items[0].time_ns <= deadline) {
        const event = pending.orderedRemove(0);
        switch (event.payload) {
            .focus_lost => held.* = .{},
            .key_down => |key| {
                switch (key.key) {
                    .left_ctrl, .right_ctrl, .p, .f1, .f2, .f3 => return error.UnimplementedJungleControl,
                    else => {},
                }
                held.*.key(key.key, true);
            },
            .key_up => |key| held.*.key(key.key, false),
            else => unreachable,
        }
    }
}

pub const Scene = struct {
    allocator: std.mem.Allocator,
    content: content.Pack,
    controller: conrad.Controller = .{},
    weapon_toggle: conrad.armed.Toggle = .{},
    pistol: @import("../pistol_shot.zig").State = .{},
    enemy_fire: @import("../weapon_fire.zig").World,
    protection_steps: u8 = 0,
    effects: @import("../audio/effects.zig").Output = .{},
    sound_events: [16]@import("../audio/effects.zig").Event = undefined,
    sound_event_count: usize = 0,
    ambience: @import("../ambience.zig").State = .{},
    last_ambient: ?@import("../ambience.zig").Event = null,
    casings: @import("../pistol_casing.zig").State = .{},
    random: @import("../random.zig").Stream = .{},
    environment: environment_mod.Environment,
    terrain: terrain_mod.State,
    props: props_mod.World,
    operated_controls: @import("../operated_controls.zig").World,
    locks: @import("../key_locks.zig").World,
    hazards: @import("../electrical_hazards.zig").World,
    detectors: @import("../detectors.zig").World,
    ceiling_guns: @import("../ceiling_guns.zig").World,
    doors: @import("../doors.zig").World,
    lifts: @import("../lifts.zig").World,
    passengers: @import("../lift_passengers.zig").State,
    ceiling_fire: @import("../weapon_fire.zig").World,
    sensed_contacts: []@import("../contacts.zig").Participant,
    gunmen: @import("../actors/gunman.zig").World,
    robots: @import("../actors/ground_robot.zig").World,
    distractions: []@import("../contacts.zig").Footprint,
    combat_targets: []@import("../combat.zig").Target,
    surfaces: @import("../surface_reactions.zig").World,
    pending_movie: ?props_mod.Movie = null,
    movie_intent: ?controls.Intent = null,
    pose: motion.Pose,
    health: i16,
    death_wait: ?u16 = null,
    defeated: bool = false,
    aborted: bool = false,
    settings: options_mod.Settings = .{},
    zoom: @import("zoom_camera.zig").Camera = .{},
    zoom_room: ?@import("../geometry.zig").RoomId = null,
    options: ?struct { menu: options_mod.Menu, clock: clock_mod.Clock } = null,
    equipment: equipment_mod.Loadout,
    received_items: []equipment_mod.Received,
    received_count: usize = 0,
    input: HeldInput = .{},
    pending: std.ArrayList(platform.Event) = .empty,
    clock: ?clock_mod.Clock = null,
    simulation_steps: u64 = 0,
    replay: ?@import("../input_recording.zig").Playback = null,
    score: u32 = 0,
    inventory_cooldown: u8 = 0,
    menu_entries: []inventory_menu.Entry,
    dialog: ?struct { menu: inventory_menu.Menu, keys: inventory_menu.Keys = .{}, clock: clock_mod.Clock } = null,

    pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Scene {
        return loadWithDifficulty(allocator, source, .normal);
    }

    pub fn loadWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, difficulty: @import("../settings.zig").Difficulty) !Scene {
        return loadLevel(allocator, source, .jungle, difficulty);
    }

    pub fn loadLevel(allocator: std.mem.Allocator, source: platform.AssetSource, level: @import("../content/level.zig").Id, difficulty: @import("../settings.zig").Difficulty) !Scene {
        var pack = try content.loadLevelWithDifficulty(allocator, source, level, difficulty);
        errdefer pack.deinit();
        var equipment = try equipment_mod.Loadout.init(allocator, pack.initial_items);
        errdefer equipment.deinit();
        var terrain = try terrain_mod.State.init(allocator, pack.terrain.map(), pack.terrain.materials, .{ .history_limit = pack.terrain.history_allowance });
        errdefer terrain.deinit();
        var props = try props_mod.World.init(allocator, pack.world_props.definitions);
        errdefer props.deinit();
        var operated = try @import("../operated_controls.zig").World.init(allocator, pack.controls.definitions);
        errdefer operated.deinit();
        var locks = try @import("../key_locks.zig").World.init(allocator, pack.locks.definitions);
        errdefer locks.deinit();
        var hazards = try @import("../electrical_hazards.zig").World.init(allocator, pack.hazards.definitions);
        errdefer hazards.deinit();
        var gunmen = try @import("../actors/gunman.zig").World.init(allocator, pack.gunmen.definitions, pack.gunmen.profiles);
        errdefer gunmen.deinit();
        var robots = try @import("../actors/ground_robot.zig").World.init(allocator, pack.robots.definitions, pack.robots.profiles);
        errdefer robots.deinit();
        var enemy_fire = try @import("../weapon_fire.zig").World.init(allocator, pack.gunmen.weapons.len);
        errdefer enemy_fire.deinit();
        const contact_capacity = pack.gunmen.definitions.len + pack.robots.definitions.len + pack.world_props.definitions.len + pack.doors.definitions.len + 1;
        const sensed_contacts = try allocator.alloc(@import("../contacts.zig").Participant, contact_capacity);
        errdefer allocator.free(sensed_contacts);
        var detectors = try @import("../detectors.zig").World.init(allocator, pack.detectors.definitions, pack.detectors.profiles, contact_capacity);
        errdefer detectors.deinit();
        var ceiling_guns = try @import("../ceiling_guns.zig").World.init(allocator, pack.ceiling_guns.definitions, pack.ceiling_guns.profiles);
        errdefer ceiling_guns.deinit();
        var doors = try @import("../doors.zig").World.init(allocator, pack.doors.definitions, pack.doors.profiles);
        errdefer doors.deinit();
        var lifts = try @import("../lifts.zig").World.init(allocator, pack.lifts.definitions, pack.lifts.profiles);
        errdefer lifts.deinit();
        var passengers = try @import("../lift_passengers.zig").State.init(allocator, pack.lifts.definitions.len, pack.world_props.definitions.len);
        errdefer passengers.deinit();
        var ceiling_fire = try @import("../weapon_fire.zig").World.init(allocator, pack.ceiling_guns.weapons.len);
        errdefer ceiling_fire.deinit();
        const combat_targets = try allocator.alloc(@import("../combat.zig").Target, pack.gunmen.definitions.len + pack.robots.definitions.len + pack.doors.definitions.len + 1);
        errdefer allocator.free(combat_targets);
        const distractions = try allocator.alloc(@import("../contacts.zig").Footprint, pack.world_props.definitions.len);
        errdefer allocator.free(distractions);
        var surfaces = try @import("../surface_reactions.zig").World.init(allocator, pack.surfaces, pack.surfaceClips());
        errdefer surfaces.deinit();
        const received_items = try allocator.alloc(equipment_mod.Received, pack.initial_items.len);
        errdefer allocator.free(received_items);
        const menu_entries = try allocator.alloc(inventory_menu.Entry, pack.initial_items.len);
        return .{
            .allocator = allocator,
            .content = pack,
            .controller = .{ .activity = pack.initial_activity },
            .environment = .{ .map = terrain.map(), .room = pack.initial_room, .materials = terrain.view() },
            .terrain = terrain,
            .props = props,
            .operated_controls = operated,
            .locks = locks,
            .hazards = hazards,
            .detectors = detectors,
            .ceiling_guns = ceiling_guns,
            .doors = doors,
            .lifts = lifts,
            .passengers = passengers,
            .ceiling_fire = ceiling_fire,
            .sensed_contacts = sensed_contacts,
            .gunmen = gunmen,
            .robots = robots,
            .distractions = distractions,
            .combat_targets = combat_targets,
            .enemy_fire = enemy_fire,
            .surfaces = surfaces,
            .pose = pack.initial_pose,
            .health = pack.initial_health,
            .equipment = equipment,
            .received_items = received_items,
            .menu_entries = menu_entries,
        };
    }

    fn emitSound(self: *Scene, sound: motion.SoundId, room: @import("../geometry.zig").RoomId) !void {
        var attenuation: u2 = 0;
        if (room != self.environment.room) {
            const current = try self.environment.map.room(self.environment.room);
            var adjacent = false;
            for ([_]@import("../geometry.zig").Edge{ current.edges.left, current.edges.right, current.edges.up, current.edges.down }) |edge| {
                if (edge == .room and edge.room == room) adjacent = true;
            }
            if (!adjacent) return;
            attenuation = 1;
        }
        if (self.sound_event_count == self.sound_events.len) return error.TooManySoundEvents;
        const event: @import("../audio/effects.zig").Event = .{ .sound = sound, .attenuation = attenuation };
        self.sound_events[self.sound_event_count] = event;
        self.sound_event_count += 1;
        if (self.settings.sound_fx) self.effects.submit(self.content.sounds, event);
    }
    pub fn pumpAudio(self: *Scene, p: *platform.Platform) !void {
        self.effects.volume = self.settings.volume;
        if (self.options != null or !self.settings.sound_fx) {
            self.effects.stop(p);
            return;
        }
        try self.effects.pump(self.content.sounds, p);
    }
    pub fn stopAudio(self: *Scene, p: *platform.Platform) void {
        self.effects.stop(p);
    }

    pub fn deinit(self: *Scene) void {
        self.equipment.deinit();
        self.terrain.deinit();
        self.props.deinit();
        self.operated_controls.deinit();
        self.locks.deinit();
        self.hazards.deinit();
        self.detectors.deinit();
        self.ceiling_guns.deinit();
        self.doors.deinit();
        self.lifts.deinit();
        self.passengers.deinit();
        self.ceiling_fire.deinit();
        self.allocator.free(self.sensed_contacts);
        self.gunmen.deinit();
        self.robots.deinit();
        self.enemy_fire.deinit();
        self.allocator.free(self.distractions);
        self.allocator.free(self.combat_targets);
        self.surfaces.deinit();
        self.allocator.free(self.received_items);
        self.allocator.free(self.menu_entries);
        self.pending.deinit(self.allocator);
        if (self.replay) |replay| self.allocator.free(replay.samples);
        self.content.deinit();
        self.* = undefined;
    }

    pub fn enqueue(self: *Scene, event: platform.Event) !void {
        if (self.replay != null) {
            if (event.payload == .key_down and (event.payload.key_down.key == .escape or event.payload.key_down.key == .tab)) self.aborted = true;
            return;
        }
        switch (event.payload) {
            .key_down, .key_up, .focus_lost => {
                if (self.pending.items.len == 256) return error.InputQueueFull;
                try self.pending.append(self.allocator, event);
            },
            else => {},
        }
    }

    pub fn update(self: *Scene, now_ns: u64) !void {
        if (self.defeated or self.aborted) return;
        if (self.clock == null) self.clock = try clock_mod.Clock.init(clock_mod.jungle, now_ns);
        // Preserve remaining debt for the next host call instead of dropping simulation.
        var work: usize = 0;
        while (self.needsCatchup(now_ns) and work < 8) : (work += 1) {
            if (self.options) |*options| {
                const deadline = options.clock.deadline();
                while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
                    const event = self.pending.orderedRemove(0);
                    if (event.payload == .key_down) options.menu.key(event.payload.key_down.key);
                }
                if (options.menu.outcome) |outcome| {
                    self.settings = options.menu.settings;
                    self.zoom.setActive(self.settings.zoom == .on, self.pose);
                    self.options = null;
                    self.input = .{};
                    self.aborted = outcome == .abort_game;
                    try self.clock.?.resumeAfterPause(deadline);
                    return;
                }
                options.clock.consume();
                continue;
            }
            if (self.dialog) |*dialog| {
                const deadline = dialog.clock.deadline();
                while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
                    const event = self.pending.orderedRemove(0);
                    switch (event.payload) {
                        .key_down => |key| try dialog.keys.key(key.key, true),
                        .key_up => |key| try dialog.keys.key(key.key, false),
                        .focus_lost => dialog.keys = .{},
                        else => unreachable,
                    }
                }
                if (self.replay) |*replay| {
                    const sample = replay.next() orelse {
                        self.aborted = true;
                        return;
                    };
                    dialog.keys.directions = .{ .left = sample.left, .right = sample.right, .up = sample.up, .down = sample.down };
                    dialog.keys.left_shift = sample.action;
                    dialog.keys.space = sample.weapon;
                    dialog.keys.enter = sample.use_item;
                    dialog.keys.tab = sample.inventory;
                }
                switch (dialog.menu.poll(dialog.keys.sample())) {
                    .stay => dialog.clock.consume(),
                    .choose => |index| {
                        const handle = self.equipment.inventory.items()[index];
                        if (!self.equipment.inventory.select(handle)) return error.MissingSelectedItem;
                        self.dialog = null;
                        self.input = .{};
                        self.inventory_cooldown = 10;
                        try self.clock.?.resumeAfterPause(deadline);
                    },
                }
                continue;
            }
            const deadline = self.clock.?.deadline();
            if (self.death_wait) |remaining| {
                if (remaining == 1) {
                    self.defeated = true;
                    return;
                }
                self.death_wait = remaining - 1;
            }
            const intent = if (self.movie_intent) |latched| blk: {
                self.movie_intent = null;
                break :blk latched;
            } else blk: {
                if (self.replay) |*replay| {
                    self.input.recorded(replay.next() orelse {
                        self.aborted = true;
                        return;
                    });
                } else try consumeInput(&self.pending, &self.input, deadline);
                break :blk try self.input.intent();
            };
            self.sound_event_count = 0;
            self.hazards.beginStep();
            self.detectors.beginStep();
            self.ceiling_guns.beginStep();
            self.doors.beginStep();
            self.lifts.beginStep();
            self.ceiling_fire.beginStep();
            self.gunmen.prepare();
            self.robots.prepare();
            self.enemy_fire.beginStep();
            if (self.protection_steps != 0) self.protection_steps -= 1;
            try self.props.prepare(self.terrain.map(), &self.equipment, .{ .room = self.environment.room, .position = self.pose.position, .width = self.content.player_contact_width });
            try self.operated_controls.prepare(self.content.controls.definitions, self.terrain.map(), self.props.player_contact);
            try self.locks.prepare(self.content.locks.definitions, self.terrain.map(), self.props.player_contact);
            try self.passengers.prepare(self.terrain.map(), self.props.player_contact, &self.lifts, self.content.lifts.definitions, &self.props, &self.equipment);
            for (self.gunmen.actors) |actor| if (!actor.lost) try self.passengers.includeActor(self.terrain.map(), actor.contact, &self.lifts, self.content.lifts.definitions);
            for (self.robots.actors) |actor| if (!actor.removed) try self.passengers.includeActor(self.terrain.map(), actor.contact, &self.lifts, self.content.lifts.definitions);
            self.controller.ride_available = self.passengers.candidate != null;
            self.controller.ride_acknowledged = self.passengers.acknowledged != null;
            self.controller.ride_arrived = self.passengers.arrival;
            self.controller.control_available = self.operated_controls.candidate != null or self.locks.candidate != null;
            self.controller.pickup_available = self.props.pickup_candidate != null;
            const selected = try self.equipment.selected();
            self.controller.use_available = if (selected) |item| item.definition.use_action != null else false;
            self.controller.throw_available = if (selected) |item| if (item.definition.use_action) |action| action == .throw_item else false else false;
            self.controller.weapon_desired = self.weapon_toggle.desired;
            self.controller.health_before_step = self.health;
            const result = try self.controller.advanceIn(self.content.controllerClips(), intent, &self.pose, &self.environment);
            if (result != .advanced) return error.UnimplementedMovementTransition;
            if (self.controller.ride_requested) |destination| self.lifts.requestRide(self.passengers.candidate orelse return error.MissingLiftContact, destination);
            self.passengers.playerUpdated(self.controller.ride_boarded, self.controller.ride_left);
            self.health -%= self.controller.damage_requested;
            if (self.controller.grant_protection) self.protection_steps = 60;
            self.weapon_toggle.advance(intent.weapon, self.equipment.carries(.gun));
            if (self.controller.sound_requested) |sound| try self.emitSound(sound, self.environment.room);
            if (self.controller.fatal_landing) self.health = -1;
            if (self.death_wait == null) self.death_wait = self.controller.death_wait_requested;
            self.received_count = try self.equipment.advance(self.health, self.received_items);
            if (self.controller.use_requested) {
                self.input.consumeUse();
                const action = (selected orelse return error.MissingSelectedItem).definition.use_action orelse return error.MissingItemAction;
                switch (action) {
                    .story => |cue| self.pending_movie = cue,
                    .unlock => _ = try self.locks.useKey(self.content.locks.definitions, self.content.locks.bindings, &self.equipment, self.equipment.inventory.selected().?),
                    .throw_item => try self.props.throwItem(&self.equipment, self.equipment.inventory.selected().?, self.pose, self.environment.room),
                }
            }
            try self.props.advance(self.terrain.map(), &self.equipment, try self.controller.pressesFloorSwitches(self.content.controllerClips()), self.controller.pickup_requested);
            try self.operated_controls.advance(self.content.controls.definitions, self.terrain.map(), self.environment.room, self.controller.operate_requested);
            try self.locks.advance(self.content.locks.definitions, self.terrain.map(), self.environment.room);
            self.lifts.route(self.content.lifts.bindings, self.props.pressed_circuits[0..self.props.pressed_count]);
            self.lifts.route(self.content.lifts.bindings, self.operated_controls.pulses[0..self.operated_controls.pulse_count]);
            self.lifts.route(self.content.lifts.bindings, self.locks.pulses[0..self.locks.pulse_count]);
            var sensed_count: usize = 1;
            self.sensed_contacts[0] = .{ .footprint = self.props.player_contact, .kind = .player, .active = true };
            for (self.gunmen.actors) |actor| {
                self.sensed_contacts[sensed_count] = .{ .footprint = actor.contact, .kind = .enemy, .active = actor.active and !actor.lost };
                sensed_count += 1;
            }
            for (self.robots.actors) |actor| {
                self.sensed_contacts[sensed_count] = .{ .footprint = actor.contact, .kind = .enemy, .active = actor.active and !actor.removed };
                sensed_count += 1;
            }
            for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
                if (definition.behavior != .collectible) continue;
                self.sensed_contacts[sensed_count] = .{ .footprint = object.contact, .kind = .item, .active = object.active and object.contact_present and try self.props.visible(index, &self.equipment) };
                sensed_count += 1;
            }
            for (self.doors.instances, self.content.doors.definitions) |instance, definition| {
                self.sensed_contacts[sensed_count] = .{ .footprint = definition.footprint, .kind = if (definition.enemy_contact) .enemy else .mechanism, .active = instance.active };
                sensed_count += 1;
            }
            self.detectors.route(self.content.detectors.bindings, self.props.pressed_circuits[0..self.props.pressed_count]);
            self.detectors.route(self.content.detectors.bindings, self.operated_controls.pulses[0..self.operated_controls.pulse_count]);
            self.detectors.route(self.content.detectors.bindings, self.locks.pulses[0..self.locks.pulse_count]);
            try self.detectors.advance(self.content.detectors.definitions, self.content.detectors.profiles, self.content.detectors.bindings, self.terrain.map(), .{ .room = self.environment.room, .position = self.pose.position }, self.sensed_contacts[0..sensed_count]);
            self.lifts.route(self.content.lifts.bindings, self.detectors.pulses[0..self.detectors.pulse_count]);
            try self.passengers.updateItemOccupancy(self.terrain.map(), &self.lifts, self.content.lifts.definitions, &self.props, &self.equipment);
            try self.lifts.advance(self.content.lifts.definitions, self.content.lifts.profiles, &self.terrain, self.passengers.occupancy, self.environment.room);
            try self.passengers.deliver(&self.lifts, self.content.lifts.definitions, self.content.lift_passengers, self.terrain.map(), &self.props, &self.equipment, &self.pose);
            self.doors.route(self.content.doors.bindings, self.props.pressed_circuits[0..self.props.pressed_count]);
            self.doors.route(self.content.doors.bindings, self.operated_controls.pulses[0..self.operated_controls.pulse_count]);
            self.doors.route(self.content.doors.bindings, self.locks.pulses[0..self.locks.pulse_count]);
            self.doors.route(self.content.doors.bindings, self.lifts.pulses[0..self.lifts.pulse_count]);
            self.doors.route(self.content.doors.bindings, self.detectors.pulses[0..self.detectors.pulse_count]);
            try self.doors.advance(self.content.doors.definitions, self.content.doors.profiles, &self.terrain, self.environment.room, self.sensed_contacts[0..sensed_count], .before_fire);
            self.ceiling_guns.route(self.content.ceiling_guns.bindings, self.props.pressed_circuits[0..self.props.pressed_count]);
            self.ceiling_guns.route(self.content.ceiling_guns.bindings, self.operated_controls.pulses[0..self.operated_controls.pulse_count]);
            self.ceiling_guns.route(self.content.ceiling_guns.bindings, self.locks.pulses[0..self.locks.pulse_count]);
            self.ceiling_guns.route(self.content.ceiling_guns.bindings, self.lifts.pulses[0..self.lifts.pulse_count]);
            self.ceiling_guns.route(self.content.ceiling_guns.bindings, self.detectors.pulses[0..self.detectors.pulse_count]);
            try self.ceiling_guns.advance(self.content.ceiling_guns.definitions, self.content.ceiling_guns.profiles, self.terrain.map(), self.environment.room);
            for (self.ceiling_guns.instances, self.content.ceiling_guns.definitions) |instance, definition| if (instance.fire) self.ceiling_fire.fire(definition.weapon, .{ .pose = instance.pose, .room = definition.room, .height = .standing }, definition.shot_next_step);
            self.hazards.route(self.content.hazards.bindings, self.detectors.pulses[0..self.detectors.pulse_count]);
            self.hazards.route(self.content.hazards.bindings, self.props.pressed_circuits[0..self.props.pressed_count]);
            self.hazards.route(self.content.hazards.bindings, self.operated_controls.pulses[0..self.operated_controls.pulse_count]);
            self.hazards.route(self.content.hazards.bindings, self.locks.pulses[0..self.locks.pulse_count]);
            self.hazards.route(self.content.hazards.bindings, self.lifts.pulses[0..self.lifts.pulse_count]);
            try self.hazards.advance(self.content.hazards.definitions, self.terrain.map(), self.environment.room, self.props.player_contact);
            var distraction_count: usize = 0;
            for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
                if (!object.active or !object.contact_present or definition.behavior != .collectible) continue;
                if (!try self.props.visible(index, &self.equipment)) continue;
                self.distractions[distraction_count] = object.contact;
                distraction_count += 1;
            }
            self.combat_targets[0] = .{ .id = @fromBackingInt(0), .category = .player, .footprint = self.props.player_contact, .facing = self.pose.facing, .vulnerable = try self.controller.vulnerability(self.content.controllerClips()) };
            for (self.gunmen.actors, self.content.gunmen.definitions, self.combat_targets[1 .. 1 + self.gunmen.actors.len], 0..) |actor, definition, *target, index| {
                target.* = .{ .id = @fromBackingInt(@as(u16, @intCast(index + 1))), .footprint = actor.contact, .facing = actor.pose.facing, .vulnerable = actor.vulnerability(self.content.gunmen.profiles[definition.profile]), .active = actor.active and !actor.lost };
            }
            const first_robot = 1 + self.gunmen.actors.len;
            for (self.robots.actors, self.combat_targets[first_robot .. first_robot + self.robots.actors.len], 0..) |actor, *target, index| {
                target.* = .{ .id = @fromBackingInt(@as(u16, @intCast(first_robot + index))), .footprint = actor.contact, .facing = actor.pose.facing, .vulnerable = actor.vulnerability(), .active = actor.active and !actor.removed };
            }
            const first_door = first_robot + self.robots.actors.len;
            for (self.doors.instances, self.content.doors.definitions, self.combat_targets[first_door..], 0..) |instance, definition, *target, index| {
                target.* = .{ .id = @fromBackingInt(@as(u16, @intCast(first_door + index))), .footprint = definition.footprint, .facing = instance.pose.facing, .vulnerable = instance.vulnerability(self.content.doors.profiles[definition.profile]), .active = instance.active, .category = if (definition.enemy_contact) .enemy else .mechanism };
            }
            try self.gunmen.advance(self.content.gunmen.definitions, self.content.gunmen.profiles, self.terrain.map(), .{ .room = self.environment.room, .position = self.pose.position }, self.distractions[0..distraction_count], self.combat_targets, &self.random);
            for (self.gunmen.actors) |actor| if (actor.sound) |sound| try self.emitSound(sound, actor.room);
            self.score +%= self.gunmen.score_requested;
            try self.pistol.advanceWithTargets(self.content.pistolDefinition(), self.controller.shot_requested, self.pose, self.environment.room, self.terrain.view(), self.combat_targets);
            if (self.pistol.hit_requested) |hit| self.deliverHit(hit);
            for (self.gunmen.actors, self.content.gunmen.definitions) |actor, definition| if (actor.shot) |height| self.enemy_fire.fire(definition.weapon, .{ .pose = actor.pose, .room = actor.room, .height = height }, definition.shot_next_step);
            try self.enemy_fire.advance(self.content.gunmen.weapons, self.terrain.view(), self.combat_targets);
            for (self.enemy_fire.channels) |channel| {
                if (channel.state.hit_requested) |hit| self.deliverHit(hit);
                if (channel.state.sound_requested) |sound| try self.emitSound(sound, channel.state.effect.?.room);
            }
            try self.ceiling_fire.advance(self.content.ceiling_guns.weapons, self.terrain.view(), self.combat_targets);
            for (self.ceiling_fire.channels) |channel| {
                if (channel.state.hit_requested) |hit| self.deliverHit(hit);
                if (channel.state.sound_requested) |sound| try self.emitSound(sound, channel.state.effect.?.room);
            }
            self.casings.advance(self.content.casing_definition, self.controller.shot_requested, self.pose, self.environment.room, &self.random);
            try self.doors.advance(self.content.doors.definitions, self.content.doors.profiles, &self.terrain, self.environment.room, self.sensed_contacts[0..sensed_count], .after_fire);
            try self.surfaces.advance(self.content.surfaces, self.content.surfaceClips(), self.terrain.map(), self.props.player_contact, try self.controller.disturbsSurface(self.content.controllerClips()), &self.random);
            self.last_ambient = if (self.content.forest_enabled) self.ambience.advance(.{ .quiet_steps = self.content.forest_quiet_steps, .calls = self.content.forest_calls }, self.environment.room, &self.random) else null;
            try self.robots.advance(self.content.robots.definitions, self.content.robots.profiles, self.terrain.view(), .{ .room = self.environment.room, .position = self.pose.position }, self.combat_targets, first_robot);
            for (self.robots.outgoing[0..self.robots.outgoing_count]) |hit| self.deliverHit(hit);
            for (self.robots.actors) |actor| if (actor.sound) |sound| try self.emitSound(sound, actor.room);
            for (self.lifts.instances) |instance| if (instance.sound) |sound| try self.emitSound(sound, instance.room);
            for (self.doors.instances, self.content.doors.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.footprint.room);
            for (self.detectors.instances, self.content.detectors.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.room);
            for (self.ceiling_guns.instances, self.content.ceiling_guns.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.room);
            for (self.hazards.instances, self.content.hazards.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.footprint.room);
            for (self.locks.instances, self.content.locks.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.footprint.room);
            for (self.operated_controls.instances, self.content.controls.definitions) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.footprint.room);
            for (self.props.objects) |object| if (object.sound_requested) |sound| try self.emitSound(sound, object.room);
            if (self.pistol.sound_requested) |sound| try self.emitSound(sound, self.pistol.effect.?.room);
            for (self.surfaces.instances, self.content.surfaces) |instance, definition| if (instance.sound) |sound| try self.emitSound(sound, definition.footprint.room);
            if (self.last_ambient) |event| try self.emitSound(event.sound, event.room);
            if (self.props.acquired) |handle| {
                const item = try self.equipment.item(handle);
                self.received_items[self.received_count] = .{ .item = handle, .kind = item.definition.kind };
                self.received_count += 1;
            }
            if (self.props.movie) |movie| self.pending_movie = movie;
            if (self.hazards.defeat_requested) self.pending_movie = .disintegration;
            self.simulation_steps += 1;
            if (self.zoom_room != null and self.zoom_room.? != self.environment.room and self.settings.zoom == .on) self.settings.zoom = .off;
            self.zoom_room = self.environment.room;
            self.zoom.setActive(self.settings.zoom == .on, self.pose);
            self.zoom.advance(self.pose);
            self.clock.?.consume();
            if (self.input.options) {
                self.options = .{ .menu = .{ .settings = self.settings }, .clock = try clock_mod.Clock.init(clock_mod.inventory, deadline) };
                self.input = .{};
                return;
            }
            if (self.inventory_cooldown != 0) {
                self.inventory_cooldown -= 1;
            } else if (self.input.inventory and self.health > 0 and self.equipment.inventory.items().len != 0) {
                const items = self.equipment.inventory.items();
                for (items, self.menu_entries[0..items.len]) |handle, *entry| {
                    const item = try self.equipment.item(handle);
                    entry.* = .{ .icon = try self.content.frame(item.definition.icon), .label = item.definition.label, .quantity = if (item.definition.show_quantity) @as(u16, @bitCast(item.quantity)) else null };
                }
                self.dialog = .{ .menu = try inventory_menu.Menu.init(items.len), .clock = try clock_mod.Clock.init(clock_mod.inventory, deadline) };
                self.input = .{};
            }
            if (self.pending_movie != null) return;
        }
    }

    pub fn latchMovieInput(self: *Scene) !bool {
        if (self.replay) |*replay| {
            self.input.recorded(replay.next() orelse {
                self.aborted = true;
                return false;
            });
        } else try consumeInput(&self.pending, &self.input, self.clock.?.deadline());
        var intent = try self.input.intent();
        intent.use_item = false;
        self.input.consumeUse();
        self.movie_intent = intent;
        return true;
    }
    pub fn resumeMovie(self: *Scene, paused_for: u64) !void {
        self.clock.?.origin_ns = try std.math.add(u64, self.clock.?.origin_ns, paused_for);
    }

    pub fn nextDeadline(self: *const Scene) ?u64 {
        if (self.options) |options| return options.clock.deadline();
        if (self.dialog) |dialog| return dialog.clock.deadline();
        return if (self.clock) |clock| clock.deadline() else null;
    }

    pub fn needsCatchup(self: *const Scene, now_ns: u64) bool {
        if (self.defeated or self.aborted) return false;
        return if (self.nextDeadline()) |time| now_ns >= time else false;
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        const room = try self.content.roomArt(self.environment.room);
        if (indices.len != room.image.pixels.len) return error.InvalidFrameLength;
        @memcpy(indices, room.image.pixels);
        try self.drawProps(.behind_player, room, indices);
        try self.drawControls(.behind_player, room, indices);
        try self.drawHazards(.behind_player, room, indices);
        try self.drawGunmen(room, indices, true);
        try self.drawRobots(room, indices, true);
        try self.drawDoors(room, indices, true);
        try self.drawLifts(room, indices, true);
        try self.drawStationary(self.detectors.instances, self.content.detectors.definitions, room, indices, true);
        try self.drawStationary(self.ceiling_guns.instances, self.content.ceiling_guns.definitions, room, indices, true);
        try self.drawShot(room, indices, true);
        try self.drawCasing(room, indices, true);
        try self.drawSurfaces(room, indices, true);
        const frame = try self.content.frame(self.pose.visual.id);
        if (self.protection_steps & 1 == 0) try sprite_renderer.draw(indices, room.image.width, room.image.height, frame, @as(i32, self.pose.position.x) + 8, @as(i32, self.pose.position.y) + 2, .{ .palette_bank = 4, .facing = if (self.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        try self.drawProps(.in_front_of_player, room, indices);
        try self.drawControls(.in_front_of_player, room, indices);
        try self.drawHazards(.in_front_of_player, room, indices);
        try self.drawGunmen(room, indices, false);
        try self.drawRobots(room, indices, false);
        try self.drawDoors(room, indices, false);
        try self.drawLifts(room, indices, false);
        try self.drawStationary(self.detectors.instances, self.content.detectors.definitions, room, indices, false);
        try self.drawStationary(self.ceiling_guns.instances, self.content.ceiling_guns.definitions, room, indices, false);
        try self.drawShot(room, indices, false);
        try self.drawCasing(room, indices, false);
        try self.drawSurfaces(room, indices, false);
        if (try self.equipment.selected()) |selected| {
            const icon = try self.content.frame(selected.definition.icon);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, icon, 232, 8, .{ .palette_bank = 10, .foreground = .overwrite });
        }
        if (self.props.pickup_candidate) |handle| {
            const item = try self.equipment.item(handle);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(self.content.world_props.hint_icon), 80, 8, .{ .palette_bank = 10, .foreground = .overwrite });
            const label = item.definition.label;
            try text_renderer.draw(indices, 256, 224, &self.content.inventory_art.font, label, @divTrunc(176 - @as(i32, @intCast(label.len)) * 8, 2), 26, .{ .foreground = 0xe6, .shadow = 0xe2, .palette_bank = 14 });
        }
        if (self.operated_controls.candidate) |index| {
            const control = self.content.controls.definitions[index];
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(control.hint), 80, 8, .{ .palette_bank = 10, .foreground = .overwrite });
            try text_renderer.draw(indices, 256, 224, &self.content.inventory_art.font, control.label, @divTrunc(176 - @as(i32, @intCast(control.label.len)) * 8, 2), 26, .{ .foreground = 0xe6, .shadow = 0xe2, .palette_bank = 14 });
        }
        if (self.locks.candidate) |index| {
            const lock = self.content.locks.definitions[index];
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(lock.hint), 80, 8, .{ .palette_bank = 10, .foreground = .overwrite });
            try text_renderer.draw(indices, 256, 224, &self.content.inventory_art.font, lock.label, @divTrunc(176 - @as(i32, @intCast(lock.label.len)) * 8, 2), 26, .{ .foreground = 0xe6, .shadow = 0xe2, .palette_bank = 14 });
        }
        try self.zoom.draw(indices, rgba);
        if (self.dialog) |dialog| try dialog.menu.draw(self.content.inventory_art.artwork(), self.menu_entries[0..dialog.menu.count], self.score, indices, room.image.width, room.image.height);
        if (self.options) |options| try options.menu.draw(indices, &self.content.inventory_art.font);
        try palette.writeRgba(indices, &room.colors, rgba);
    }

    fn deliverHit(self: *Scene, hit: @import("../combat.zig").Hit) void {
        if (@backingInt(hit.target) == 0) {
            if (self.protection_steps == 0 and self.environment.room == hit.sender_room) self.controller.pending_hits.set(hit.impact);
        } else if (@backingInt(hit.target) <= self.gunmen.actors.len) {
            const actor = &self.gunmen.actors[@backingInt(hit.target) - 1];
            if (actor.room == hit.sender_room) actor.pending_hits.set(hit.impact);
        } else if (@backingInt(hit.target) < 1 + self.gunmen.actors.len + self.robots.actors.len) {
            const actor = &self.robots.actors[@backingInt(hit.target) - 1 - self.gunmen.actors.len];
            if (actor.room == hit.sender_room) actor.pending_hits.set(hit.impact);
        } else {
            const index = @backingInt(hit.target) - 1 - self.gunmen.actors.len - self.robots.actors.len;
            if (self.content.doors.definitions[index].footprint.room == hit.sender_room) self.doors.hit(self.content.doors.definitions, index);
        }
    }

    fn drawShot(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        const definition = self.content.pistolDefinition();
        for (self.enemy_fire.channels, self.content.gunmen.weapons) |channel, weapon| if (weapon.behind_player == behind_player) {
            if (channel.state.effect) |effect| if (effect.room == self.environment.room) try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(effect.pose.visual.id), @as(i32, effect.pose.position.x) + 8, @as(i32, effect.pose.position.y) + 2, .{ .palette_bank = weapon.palette_bank, .facing = if (effect.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        };
        for (self.ceiling_fire.channels, self.content.ceiling_guns.weapons) |channel, weapon| if (weapon.behind_player == behind_player) {
            if (channel.state.effect) |effect| if (effect.room == self.environment.room) try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(effect.pose.visual.id), @as(i32, effect.pose.position.x) + 8, @as(i32, effect.pose.position.y) + 2, .{ .palette_bank = weapon.palette_bank, .facing = if (effect.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        };
        if (definition.behind_player != behind_player) return;
        if (self.pistol.effect) |effect| if (effect.room == self.environment.room) {
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(effect.pose.visual.id), @as(i32, effect.pose.position.x) + 8, @as(i32, effect.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (effect.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        };
    }

    fn drawCasing(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        const definition = self.content.casing_definition;
        if (definition.behind_player != behind_player) return;
        if (self.casings.flight) |flight| if (flight.room == self.environment.room) {
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(flight.pose.visual.id), @as(i32, flight.pose.position.x) + 8, @as(i32, flight.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (flight.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        };
    }

    fn drawSurfaces(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (self.surfaces.instances, self.content.surfaces) |instance, definition| {
            if (definition.footprint.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawProps(self: *const Scene, layer: props_mod.Layer, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8) !void {
        // Keep content order within each layer, with Conrad drawn between layers.
        for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
            if (definition.layer != layer or object.room != self.environment.room or !try self.props.visible(index, &self.equipment)) continue;
            const art = try self.content.frame(object.pose.visual.id);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, art, @as(i32, object.pose.position.x) + 8, @as(i32, object.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (object.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawControls(self: *const Scene, layer: props_mod.Layer, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8) !void {
        try self.drawControlSet(self.operated_controls.instances, self.content.controls.definitions, layer, room, indices);
        try self.drawControlSet(self.locks.instances, self.content.locks.definitions, layer, room, indices);
    }

    fn drawControlSet(self: *const Scene, instances: anytype, definitions: anytype, layer: props_mod.Layer, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8) !void {
        for (instances, definitions) |instance, definition| {
            if (definition.layer != layer or definition.footprint.room != self.environment.room) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawHazards(self: *const Scene, layer: props_mod.Layer, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8) !void {
        for (self.hazards.instances, self.content.hazards.definitions) |instance, definition| {
            if (definition.layer != layer or definition.footprint.room != self.environment.room) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawGunmen(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (self.gunmen.actors, self.content.gunmen.definitions) |actor, definition| {
            if (actor.lost or actor.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(actor.pose.visual.id), @as(i32, actor.pose.position.x) + 8, @as(i32, actor.pose.position.y) + 2, .{ .palette_bank = 5, .facing = if (actor.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawRobots(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (self.robots.actors, self.content.robots.definitions) |actor, definition| {
            if (actor.removed or actor.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(actor.pose.visual.id), @as(i32, actor.pose.position.x) + 8, @as(i32, actor.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (actor.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawLifts(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (self.lifts.instances, self.content.lifts.definitions) |instance, definition| {
            if (instance.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawDoors(self: *const Scene, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (self.doors.instances, self.content.doors.definitions) |instance, definition| {
            if (definition.footprint.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    fn drawStationary(self: *const Scene, instances: anytype, definitions: anytype, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8, behind_player: bool) !void {
        for (instances, definitions) |instance, definition| {
            if (definition.room != self.environment.room or definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(instance.pose.visual.id), @as(i32, instance.pose.position.x) + 8, @as(i32, instance.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (instance.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, self.health)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.death_wait orelse 0)));
        hash.update(&.{ @intFromBool(self.defeated), @intFromBool(self.aborted), self.settings.volume, @intFromBool(self.settings.sound_fx), @intFromBool(self.settings.music), @intFromBool(self.settings.joystick), @backingInt(self.settings.zoom), @intFromBool(self.options != null) });
        if (self.options) |options| hash.update(&.{ @backingInt(options.menu.selection), options.menu.settings.volume, @intFromBool(options.menu.settings.sound_fx), @intFromBool(options.menu.settings.music), @intFromBool(options.menu.settings.joystick), @backingInt(options.menu.settings.zoom) });
        self.equipment.hashInto(&hash);
        self.terrain.hashInto(&hash);
        self.pistol.hashInto(&hash);
        self.enemy_fire.hashInto(&hash);
        const hits = self.controller.pending_hits;
        hash.update(&.{ self.protection_steps, @intFromBool(self.controller.protection_pending), @intFromBool(hits.rear_high), @intFromBool(hits.rear_low), @intFromBool(hits.front_high), @intFromBool(hits.front_low) });
        self.casings.hashInto(&hash);
        self.surfaces.hashInto(&hash);
        for ([_]u32{ if (self.ambience.call) |call| @intCast(call + 1) else 0, self.ambience.elapsed, if (self.ambience.room) |room| @backingInt(room) else 0 }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.random.state)));
        self.props.hashInto(&hash);
        self.operated_controls.hashInto(&hash);
        self.locks.hashInto(&hash);
        self.hazards.hashInto(&hash);
        self.detectors.hashInto(&hash);
        self.ceiling_guns.hashInto(&hash);
        self.doors.hashInto(&hash);
        self.lifts.hashInto(&hash);
        self.passengers.hashInto(&hash);
        self.ceiling_fire.hashInto(&hash);
        self.gunmen.hashInto(&hash);
        self.robots.hashInto(&hash);
        hash.update(&.{if (self.pending_movie) |movie| 1 + @as(u8, @backingInt(movie)) else 0});
        if (self.replay) |replay| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, replay.cursor)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.score)));
        hash.update(&.{ self.inventory_cooldown, @intFromBool(self.input.inventory), @intFromBool(self.input.use_item), @intFromBool(self.input.use_held), @intFromBool(self.input.use_blocked), @intFromBool(self.dialog != null) });
        if (self.dialog) |dialog| {
            for ([_]u64{ dialog.menu.cursor, dialog.menu.last_displayed, dialog.clock.next_tick, dialog.clock.origin_ns - self.clock.?.origin_ns }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            hash.update(&.{ @intFromBool(dialog.menu.score_next), @intFromBool(dialog.menu.view == .score) });
            if (dialog.menu.view == .items) hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, dialog.menu.view.items)));
            const keys = dialog.keys;
            for ([_]bool{ keys.directions.right, keys.directions.left, keys.directions.up, keys.directions.down, keys.previous.right, keys.previous.left, keys.previous.up, keys.previous.down, keys.left_shift, keys.right_shift, keys.space, keys.enter, keys.tab }) |value| hash.update(&.{@intFromBool(value)});
        }
        hash.update(&.{ @intFromBool(self.input.weapon), @intFromBool(self.weapon_toggle.desired), @backingInt(self.weapon_toggle.phase), @intFromBool(self.controller.weapon_desired) });
        for ([_]u32{ @intFromBool(self.zoom.active), @as(u16, @bitCast(self.zoom.origin.x)), @as(u16, @bitCast(self.zoom.origin.y)) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        const activity: u32 = @backingInt(std.meta.activeTag(self.controller.activity));
        const phase: u32 = switch (self.controller.activity) {
            .armed => |p| @backingInt(p.phase),
            .riding => |p| @backingInt(p.phase),
            .turning => |p| @backingInt(p),
            .walking, .running => |p| switch (p) {
                .starting => 0,
                .stride => |i| @intCast(i + 1),
            },
            .stopping_run => |p| @backingInt(p),
            .changing_pace => |p| @backingInt(p),
            .reversing_run => |p| @backingInt(p),
            .running_jump => |p| @backingInt(p.phase),
            .descending => |p| @backingInt(p.phase),
            .jumping => |jump| (@as(u32, @backingInt(jump.kind)) << 8) | @backingInt(jump.phase),
            .crouching => |p| @backingInt(p),
            .rolling => |roll| @backingInt(roll.phase),
            .wounded => |state| @backingInt(state.phase),
            .falling => |fall| @as(u32, @backingInt(fall.phase)) | (@as(u32, @intFromBool(fall.already_dead)) << 8),
            .ledge => |state| @backingInt(state.phase),
            .operating => |state| @backingInt(state),
            .dead => |phase| @backingInt(phase),
            .recoiling => |state| (@as(u32, @backingInt(std.meta.activeTag(state.phase))) << 8) | switch (state.phase) {
                .settling, .resting => |landing| @as(u32, @backingInt(landing)),
                else => @as(u32, 0),
            },
            else => 0,
        };
        for ([_]u32{ @backingInt(self.environment.room), @as(u16, @bitCast(self.pose.position.x)), @as(u16, @bitCast(self.pose.position.y)), @backingInt(self.pose.facing), @backingInt(self.pose.visual.id), @intFromBool(self.pose.visual.mirrored), activity, phase, @intCast(self.controller.playback.next_step) }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        for ([_]u64{ self.simulation_steps, if (self.clock) |clock| clock.next_tick else 0 }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        const held = [_]u8{ @intFromBool(self.input.left), @intFromBool(self.input.right), @intFromBool(self.input.up), @intFromBool(self.input.down), @intFromBool(self.input.left_action), @intFromBool(self.input.right_action), if (self.input.previous_direction.horizontal) |direction| 1 + @as(u8, @backingInt(direction)) else 0, if (self.input.previous_direction.vertical) |direction| 1 + @as(u8, @backingInt(direction)) else 0, @intFromBool(self.input.previous_direction.conflict) };
        hash.update(&held);
        for (self.pending.items) |event| {
            const relative_time = event.time_ns -| (if (self.clock) |clock| clock.origin_ns else 0);
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, relative_time)));
            const kind: u32 = @backingInt(std.meta.activeTag(event.payload));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, kind)));
            const key: u16 = switch (event.payload) {
                .key_down, .key_up => |press| @backingInt(press.key),
                else => 0,
            };
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, key)));
        }
        return hash.final();
    }
};

test "held controls retain separate shift keys and release directions" {
    var held: HeldInput = .{};
    held.key(.left, true);
    held.key(.left_shift, true);
    held.key(.right_shift, true);
    held.key(.left_shift, false);
    try std.testing.expectEqual(@as(?motion.Facing, .left), (try held.intent()).direction);
    try std.testing.expect((try held.intent()).action);
    held.key(.left, false);
    try std.testing.expect((try held.intent()).direction == null);
    held.key(.right_shift, false);
    try std.testing.expect(!(try held.intent()).action);
}

test "mixed directional axes retain the last sampled direction but use current action state" {
    var held: HeldInput = .{};
    held.key(.left, true);
    try std.testing.expectEqual(@as(?motion.Facing, .left), (try held.intent()).direction);
    held.key(.up, true);
    held.key(.left_shift, true);
    const mixed = try held.intent();
    try std.testing.expectEqual(@as(?motion.Facing, .left), mixed.direction);
    try std.testing.expect(mixed.vertical == null);
    try std.testing.expect(mixed.action);
    held.key(.left, false);
    const vertical = try held.intent();
    try std.testing.expect(vertical.direction == null);
    try std.testing.expectEqual(@as(?controls.Vertical, .up), vertical.vertical);
}

test "late host polling applies queued controls at simulation deadlines and focus loss releases them" {
    var events: std.ArrayList(platform.Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.appendSlice(std.testing.allocator, &.{
        .{ .time_ns = 10, .payload = .{ .key_down = .{ .key = .left } } },
        .{ .time_ns = 20, .payload = .{ .key_down = .{ .key = .left_shift } } },
        .{ .time_ns = 30, .payload = .focus_lost },
    });
    var held: HeldInput = .{};
    try consumeInput(&events, &held, 15);
    try std.testing.expect(held.left);
    try std.testing.expect(!held.left_action);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try consumeInput(&events, &held, 25);
    try std.testing.expect(held.left_action);
    try consumeInput(&events, &held, 30);
    try std.testing.expectEqualDeep(HeldInput{}, held);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "using an item consumes Return until a release and new press" {
    var input: HeldInput = .{};
    input.key(.enter, true);
    try std.testing.expect((try input.intent()).use_item);
    input.consumeUse();
    try std.testing.expect(!(try input.intent()).use_item);
    input.key(.enter, true); // A held key's repeat must not replay the recording.
    try std.testing.expect(!(try input.intent()).use_item);
    input.key(.enter, false);
    input.key(.enter, true);
    try std.testing.expect((try input.intent()).use_item);
}

test "overlapping directions retain ambiguous history until one axis is released" {
    var input: HeldInput = .{};
    input.key(.left, true);
    input.key(.right, true);
    var intent = try input.intent();
    try std.testing.expect(intent.directions_conflict);
    try std.testing.expect(intent.direction == null and !intent.neutralDirections());
    input.key(.up, true);
    input.key(.left, false);
    intent = try input.intent();
    try std.testing.expect(intent.directions_conflict and intent.vertical == null);
    input.key(.right, false);
    intent = try input.intent();
    try std.testing.expect(!intent.directions_conflict);
    try std.testing.expectEqual(controls.Vertical.up, intent.vertical.?);
}
