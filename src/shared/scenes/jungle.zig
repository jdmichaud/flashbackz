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
const actors_item_aid = @import("../actors/item_aid.zig");
const actors_trader = @import("../actors/trader.zig");
const ambience_mod = @import("../ambience.zig");
const ambient_people_mod = @import("../ambient_people.zig");
const arrival_triggers_mod = @import("../arrival_triggers.zig");
const attentive_contacts_mod = @import("../attentive_contacts.zig");
const audio_effects = @import("../audio/effects.zig");
const ceiling_guns_mod = @import("../ceiling_guns.zig");
const combat = @import("../combat.zig");
const contacts = @import("../contacts.zig");
const content_level = @import("../content/level.zig");
const content_visibility = @import("../content/visibility.zig");
const credential_terminals_mod = @import("../credential_terminals.zig");
const detectors_mod = @import("../detectors.zig");
const doors_mod = @import("../doors.zig");
const electrical_hazards = @import("../electrical_hazards.zig");
const enemy_barriers_mod = @import("../enemy_barriers.zig");
const energy_stations_mod = @import("../energy_stations.zig");
const environmental_alarms_mod = @import("../environmental_alarms.zig");
const escort_followers_mod = @import("../escort_followers.zig");
const event_barriers = @import("../event_barriers.zig");
const force_fields_mod = @import("../force_fields.zig");
const geometry = @import("../geometry.zig");
const ground_robot = @import("../actors/ground_robot.zig");
const gunman = @import("../actors/gunman.zig");
const input_recording = @import("../input_recording.zig");
const inventory_grants_mod = @import("../inventory_grants.zig");
const key_locks = @import("../key_locks.zig");
const level_exits = @import("../level_exits.zig");
const lift_passengers = @import("../lift_passengers.zig");
const lifts_mod = @import("../lifts.zig");
const mission_terminals_mod = @import("../mission_terminals.zig");
const mobile_guard = @import("../actors/mobile_guard.zig");
const operated_controls_mod = @import("../operated_controls.zig");
const pistol_casing = @import("../pistol_casing.zig");
const pistol_shot = @import("../pistol_shot.zig");
const platform_sections_mod = @import("../platform_sections.zig");
const quest_contacts_mod = @import("../quest_contacts.zig");
const random_mod = @import("../random.zig");
const rescue_contacts_mod = @import("../rescue_contacts.zig");
const rescued_guide = @import("../actors/rescued_guide.zig");
const room_artwork = @import("../content/room_artwork.zig");
const scripted_transport_mod = @import("../scripted_transport.zig");
const service_counters_mod = @import("../service_counters.zig");
const settings_mod = @import("../settings.zig");
const story_stations_mod = @import("../story_stations.zig");
const surface_reactions = @import("../surface_reactions.zig");
const timed_items_mod = @import("../timed_items.zig");
const triggered_effects_mod = @import("../triggered_effects.zig");
const visibility_mod = @import("../visibility.zig");
const weapon_fire = @import("../weapon_fire.zig");
const world_messages = @import("../world_messages.zig");
const zoom_camera = @import("zoom_camera.zig");

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
    previous_direction: struct {
        horizontal: ?motion.Facing = null,
        vertical: ?controls.Vertical = null,
        conflict: bool = false,
    } = .{},
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
    pub fn recorded(self: *HeldInput, sample: input_recording.Sample) void {
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
        if (self.inventory) return .{};
        const horizontal: ?motion.Facing = if (self.left and
            !self.right) .left else if (self.right and
            !self.left) .right else null;
        const vertical: ?controls.Vertical = if (self.up and
            !self.down) .up else if (self.down and
            !self.up) .down else null;
        // Mixed axes retain the last accepted direction, while the action modifier remains
        // current. This is the original input arbitration, expressed without a DOS bitmask.
        if (!(self.left or self.right) or !(self.up or self.down)) self.previous_direction = .{
            .horizontal = horizontal,
            .vertical = vertical,
            .conflict = (self.left and self.right) or (self.up and self.down),
        };
        return .{
            .direction = self.previous_direction.horizontal,
            .vertical = self.previous_direction.vertical,
            .action = self.left_action or self.right_action,
            .use_item = self.use_item,
            .weapon = self.weapon,
            .directions_conflict = self.previous_direction.conflict,
        };
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

const Interaction = enum { none, item_aid, trader, guide, station, quest, host, escort, rescue };

pub const Scene = struct {
    allocator: std.mem.Allocator,
    content: content.Pack,
    controller: conrad.Controller = .{},
    weapon_toggle: conrad.armed.Toggle = .{},
    pistol: pistol_shot.State = .{},
    enemy_fire: weapon_fire.World,
    protection_steps: u8 = 0,
    effects: audio_effects.Output = .{},
    sound_events: [16]audio_effects.Event = undefined,
    sound_event_count: usize = 0,
    ambience: ambience_mod.State = .{},
    last_ambient: ?ambience_mod.Event = null,
    casings: pistol_casing.State = .{},
    random: random_mod.Stream = .{},
    environment: environment_mod.Environment,
    terrain: terrain_mod.State,
    props: props_mod.World,
    operated_controls: operated_controls_mod.World,
    locks: key_locks.World,
    credential_terminals: credential_terminals_mod.World,
    environmental_alarms: environmental_alarms_mod.World,
    timed_items: timed_items_mod.World,
    scripted_transport: scripted_transport_mod.World,
    arrival_triggers: arrival_triggers_mod.World,
    escort_followers: escort_followers_mod.World,
    enemy_barriers: enemy_barriers_mod.World,
    barrier_owners: []enemy_barriers_mod.Owner,
    rescue_contacts: rescue_contacts_mod.World,
    weighted_characters: []contacts.Footprint,
    ambient_people: ambient_people_mod.World,
    attentive_contacts: attentive_contacts_mod.World,
    quest_contacts: quest_contacts_mod.World,
    mission_terminals: mission_terminals_mod.World,
    service_counters: service_counters_mod.World,
    platform_sections: platform_sections_mod.World,
    item_aid: actors_item_aid.World,
    interaction: Interaction = .none,
    guides: rescued_guide.World,
    story_stations: story_stations_mod.World,
    traders: actors_trader.World,
    guards: mobile_guard.World,
    visibility: visibility_mod.World,
    guard_fire: weapon_fire.World,
    barriers: event_barriers.World,
    inventory_grants: inventory_grants_mod.World,
    exits: level_exits.World,
    triggered_effects: triggered_effects_mod.World,
    message_icon: motion.VisualId,
    level_code_steps: u16 = 150,
    message: ?world_messages.State = null,
    energy_stations: energy_stations_mod.World,
    hazards: electrical_hazards.World,
    detectors: detectors_mod.World,
    ceiling_guns: ceiling_guns_mod.World,
    doors: doors_mod.World,
    lifts: lifts_mod.World,
    passengers: lift_passengers.State,
    ceiling_fire: weapon_fire.World,
    sensed_contacts: []contacts.Participant,
    gunmen: gunman.World,
    robots: ground_robot.World,
    distractions: []contacts.Footprint,
    force_fields: []force_fields_mod.Emitter,
    combat_targets: []combat.Target,
    surfaces: surface_reactions.World,
    pending_movie: ?props_mod.Movie = null,
    movie_intent: ?controls.Intent = null,
    pose: motion.Pose,
    health: i16,
    death_wait: ?u16 = null,
    defeated: bool = false,
    aborted: bool = false,
    settings: options_mod.Settings = .{},
    zoom: zoom_camera.Camera = .{},
    zoom_room: ?geometry.RoomId = null,
    options: ?struct { menu: options_mod.Menu, clock: clock_mod.Clock } = null,
    equipment: equipment_mod.Loadout,
    received_items: []equipment_mod.Received,
    received_count: usize = 0,
    input: HeldInput = .{},
    pending: std.ArrayList(platform.Event) = .empty,
    clock: ?clock_mod.Clock = null,
    simulation_steps: u64 = 0,
    replay: ?input_recording.Playback = null,
    score: u32 = 0,
    inventory_cooldown: u8 = 0,
    menu_entries: []inventory_menu.Entry,
    dialog: ?struct {
        menu: inventory_menu.Menu,
        keys: inventory_menu.Keys = .{},
        clock: clock_mod.Clock,
    } = null,

    pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Scene {
        return loadWithDifficulty(allocator, source, .normal);
    }

    pub fn loadWithDifficulty(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        difficulty: settings_mod.Difficulty,
    ) !Scene {
        return loadLevel(allocator, source, .jungle, difficulty);
    }

    pub fn loadLevel(
        allocator: std.mem.Allocator,
        source: platform.AssetSource,
        level: content_level.Id,
        difficulty: settings_mod.Difficulty,
    ) !Scene {
        var pack = try content.loadLevelWithDifficulty(allocator, source, level, difficulty);
        errdefer pack.deinit();
        var equipment = try equipment_mod.Loadout.init(allocator, pack.initial_items);
        errdefer equipment.deinit();
        var terrain = try terrain_mod.State.init(
            allocator,
            pack.terrain.map(),
            pack.terrain.materials,
            .{ .history_limit = pack.terrain.history_allowance },
        );
        errdefer terrain.deinit();
        var props = try props_mod.World.init(allocator, pack.world_props.definitions);
        errdefer props.deinit();
        var operated = try operated_controls_mod.World.init(
            allocator,
            pack.controls.definitions,
        );
        errdefer operated.deinit();
        var locks = try key_locks.World.init(
            allocator,
            pack.locks.definitions,
            pack.locks.receivers,
        );
        errdefer locks.deinit();
        var credential_terminals = try credential_terminals_mod.World.init(
            allocator,
            pack.credential_terminals.definitions,
        );
        errdefer credential_terminals.deinit();
        var environmental_alarms = try environmental_alarms_mod.World.init(
            allocator,
            pack.environmental_alarms.definitions,
        );
        errdefer environmental_alarms.deinit();
        var timed_items = try timed_items_mod.World.init(
            allocator,
            pack.timed_items.definitions.len,
        );
        errdefer timed_items.deinit();
        var scripted_transport = try scripted_transport_mod.World.init(
            allocator,
            pack.scripted_transport.definitions.len,
            pack.scripted_transport.effects.len,
        );
        errdefer scripted_transport.deinit();
        var arrival_triggers = try arrival_triggers_mod.World.init(
            allocator,
            pack.arrival_triggers.definitions,
        );
        errdefer arrival_triggers.deinit();
        var escort_followers = try escort_followers_mod.World.init(
            allocator,
            pack.escort_followers.definitions,
        );
        errdefer escort_followers.deinit();
        var enemy_barriers = try enemy_barriers_mod.World.init(
            allocator,
            pack.enemy_barriers.definitions,
        );
        errdefer enemy_barriers.deinit();
        const barrier_owners = try allocator.alloc(
            enemy_barriers_mod.Owner,
            pack.gunmen.definitions.len,
        );
        errdefer allocator.free(barrier_owners);
        var rescue_contacts = try rescue_contacts_mod.World.init(
            allocator,
            pack.rescue_contacts.definitions,
        );
        errdefer rescue_contacts.deinit();
        const weighted_characters = try allocator.alloc(
            contacts.Footprint,
            pack.rescue_contacts.definitions.len + pack.escort_followers.definitions.len,
        );
        errdefer allocator.free(weighted_characters);
        var ambient_people = try ambient_people_mod.World.init(
            allocator,
            pack.ambient_people.definitions,
            pack.ambient_people.profiles,
        );
        errdefer ambient_people.deinit();
        var attentive_contacts = try attentive_contacts_mod.World.init(
            allocator,
            pack.attentive_contacts.definitions,
        );
        errdefer attentive_contacts.deinit();
        var quest_contacts = try quest_contacts_mod.World.init(
            allocator,
            pack.quest_contacts.definitions,
        );
        errdefer quest_contacts.deinit();
        var mission_terminals = try mission_terminals_mod.World.init(
            allocator,
            pack.mission_terminals.definitions,
        );
        errdefer mission_terminals.deinit();
        var service_counters = try service_counters_mod.World.init(
            allocator,
            pack.service_counters.definitions,
        );
        errdefer service_counters.deinit();
        var platform_sections = try platform_sections_mod.World.init(
            allocator,
            pack.platform_sections.definitions,
        );
        errdefer platform_sections.deinit();
        var item_aid = try actors_item_aid.World.init(
            allocator,
            pack.item_aid.definitions,
            pack.item_aid.profiles,
        );
        errdefer item_aid.deinit();
        var guides = try rescued_guide.World.init(
            allocator,
            pack.guides.definitions,
            pack.guides.profiles,
        );
        errdefer guides.deinit();
        var story_stations = try story_stations_mod.World.init(
            allocator,
            pack.story_stations.definitions,
        );
        errdefer story_stations.deinit();
        var traders = try actors_trader.World.init(
            allocator,
            pack.traders.definitions,
            pack.traders.profiles,
        );
        errdefer traders.deinit();
        var guards = try mobile_guard.World.init(
            allocator,
            pack.guards.definitions,
            pack.guards.profiles,
        );
        errdefer guards.deinit();
        var visibility = try visibility_mod.World.init(
            allocator,
            pack.visibility.definitions,
            256,
        );
        errdefer visibility.deinit();
        var guard_fire = try weapon_fire.World.init(
            allocator,
            pack.guards.weapons.len,
        );
        errdefer guard_fire.deinit();
        var barriers = try event_barriers.World.init(
            allocator,
            pack.barriers.definitions.len,
        );
        errdefer barriers.deinit();
        var inventory_grants = try inventory_grants_mod.World.init(
            allocator,
            pack.inventory_grants.definitions.len,
        );
        errdefer inventory_grants.deinit();
        var exits = try level_exits.World.init(allocator, pack.exits);
        errdefer exits.deinit();
        var triggered_effects = try triggered_effects_mod.World.init(
            allocator,
            pack.triggered_effects.definitions,
        );
        errdefer triggered_effects.deinit();
        var energy_stations = try energy_stations_mod.World.init(
            allocator,
            pack.energy_stations.definitions,
        );
        errdefer energy_stations.deinit();
        var hazards = try electrical_hazards.World.init(
            allocator,
            pack.hazards.definitions,
        );
        errdefer hazards.deinit();
        var gunmen = try gunman.World.init(
            allocator,
            pack.gunmen.definitions,
            pack.gunmen.profiles,
        );
        errdefer gunmen.deinit();
        var robots = try ground_robot.World.init(
            allocator,
            pack.robots.definitions,
            pack.robots.profiles,
        );
        errdefer robots.deinit();
        var enemy_fire = try weapon_fire.World.init(
            allocator,
            pack.gunmen.weapons.len,
        );
        errdefer enemy_fire.deinit();
        const contact_capacity = pack.gunmen.definitions.len + pack.robots.definitions.len + pack.guards.definitions.len + pack.world_props.definitions.len + pack.doors.definitions.len + pack.escort_followers.definitions.len + pack.quest_contacts.definitions.len + pack.attentive_contacts.definitions.len + pack.item_aid.definitions.len + pack.guides.definitions.len + pack.traders.definitions.len + pack.rescue_contacts.definitions.len + pack.enemy_barriers.definitions.len + 1;
        const sensed_contacts = try allocator.alloc(
            contacts.Participant,
            contact_capacity,
        );
        errdefer allocator.free(sensed_contacts);
        var detectors = try detectors_mod.World.init(
            allocator,
            pack.detectors.definitions,
            pack.detectors.profiles,
            contact_capacity,
        );
        errdefer detectors.deinit();
        var ceiling_guns = try ceiling_guns_mod.World.init(
            allocator,
            pack.ceiling_guns.definitions,
            pack.ceiling_guns.profiles,
        );
        errdefer ceiling_guns.deinit();
        var doors = try doors_mod.World.init(
            allocator,
            pack.doors.definitions,
            pack.doors.profiles,
        );
        errdefer doors.deinit();
        var lifts = try lifts_mod.World.init(
            allocator,
            pack.lifts.definitions,
            pack.lifts.profiles,
        );
        errdefer lifts.deinit();
        var passengers = try lift_passengers.State.init(
            allocator,
            pack.lifts.definitions.len,
            pack.world_props.definitions.len,
        );
        errdefer passengers.deinit();
        var ceiling_fire = try weapon_fire.World.init(
            allocator,
            pack.ceiling_guns.weapons.len,
        );
        errdefer ceiling_fire.deinit();
        const force_fields = try allocator.alloc(
            force_fields_mod.Emitter,
            pack.force_fields.definitions.len,
        );
        errdefer allocator.free(force_fields);
        @memset(force_fields, .{});
        const combat_targets = try allocator.alloc(
            combat.Target,
            pack.gunmen.definitions.len + pack.robots.definitions.len + pack.guards.definitions.len + pack.doors.definitions.len + pack.force_fields.definitions.len + pack.enemy_barriers.definitions.len + 1,
        );
        errdefer allocator.free(combat_targets);
        const distractions = try allocator.alloc(
            contacts.Footprint,
            pack.world_props.definitions.len,
        );
        errdefer allocator.free(distractions);
        var surfaces = try surface_reactions.World.init(
            allocator,
            pack.surfaces,
            pack.surfaceClips(),
        );
        errdefer surfaces.deinit();
        const received_items = try allocator.alloc(equipment_mod.Received, pack.initial_items.len);
        errdefer allocator.free(received_items);
        const menu_entries = try allocator.alloc(inventory_menu.Entry, pack.initial_items.len);
        return .{
            .allocator = allocator,
            .content = pack,
            .controller = .{ .activity = pack.initial_activity },
            .environment = .{
                .map = terrain.map(),
                .room = pack.initial_room,
                .materials = terrain.view(),
            },
            .terrain = terrain,
            .props = props,
            .operated_controls = operated,
            .locks = locks,
            .service_counters = service_counters,
            .mission_terminals = mission_terminals,
            .quest_contacts = quest_contacts,
            .attentive_contacts = attentive_contacts,
            .ambient_people = ambient_people,
            .rescue_contacts = rescue_contacts,
            .enemy_barriers = enemy_barriers,
            .barrier_owners = barrier_owners,
            .weighted_characters = weighted_characters,
            .escort_followers = escort_followers,
            .arrival_triggers = arrival_triggers,
            .scripted_transport = scripted_transport,
            .timed_items = timed_items,
            .environmental_alarms = environmental_alarms,
            .credential_terminals = credential_terminals,
            .platform_sections = platform_sections,
            .item_aid = item_aid,
            .guides = guides,
            .story_stations = story_stations,
            .traders = traders,
            .guards = guards,
            .visibility = visibility,
            .guard_fire = guard_fire,
            .barriers = barriers,
            .inventory_grants = inventory_grants,
            .exits = exits,
            .triggered_effects = triggered_effects,
            .message_icon = pack.world_props.hint_icon,
            .energy_stations = energy_stations,
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
            .force_fields = force_fields,
            .enemy_fire = enemy_fire,
            .surfaces = surfaces,
            .pose = pack.initial_pose,
            .health = pack.initial_health,
            .equipment = equipment,
            .received_items = received_items,
            .menu_entries = menu_entries,
        };
    }

    fn emitSound(
        self: *Scene,
        sound: motion.SoundId,
        room: geometry.RoomId,
    ) !void {
        var attenuation: u2 = 0;
        if (room != self.environment.room) {
            const current = try self.environment.map.room(self.environment.room);
            var adjacent = false;
            for ([_]geometry.Edge{
                current.edges.left,
                current.edges.right,
                current.edges.up,
                current.edges.down,
            }) |edge| {
                if (edge == .room and edge.room == room) adjacent = true;
            }
            if (!adjacent) return;
            attenuation = 1;
        }
        try self.emitEffect(.{ .sound = sound, .attenuation = attenuation });
    }
    fn emitEffect(self: *Scene, event: audio_effects.Event) !void {
        if (self.sound_event_count == self.sound_events.len) return error.TooManySoundEvents;
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
        self.service_counters.deinit();
        self.mission_terminals.deinit();
        self.quest_contacts.deinit();
        self.attentive_contacts.deinit();
        self.ambient_people.deinit();
        self.rescue_contacts.deinit();
        self.enemy_barriers.deinit();
        self.allocator.free(self.barrier_owners);
        self.allocator.free(self.weighted_characters);
        self.escort_followers.deinit();
        self.arrival_triggers.deinit();
        self.scripted_transport.deinit();
        self.timed_items.deinit();
        self.environmental_alarms.deinit();
        self.credential_terminals.deinit();
        self.platform_sections.deinit();
        self.item_aid.deinit();
        self.guides.deinit();
        self.story_stations.deinit();
        self.traders.deinit();
        self.guards.deinit();
        self.visibility.deinit();
        self.guard_fire.deinit();
        self.barriers.deinit();
        self.inventory_grants.deinit();
        self.exits.deinit();
        self.triggered_effects.deinit();
        self.energy_stations.deinit();
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
        self.allocator.free(self.force_fields);
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
            if (event.payload == .key_down and
                (event.payload.key_down.key == .escape or
                    event.payload.key_down.key == .tab)) self.aborted = true;
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
            if (self.message) |*message| {
                const deadline = message.clock.deadline();
                while (self.pending.items.len != 0 and
                    self.pending.items[0].time_ns <= deadline) message.event(self.pending.orderedRemove(0));
                if (message.poll(try self.content.messages.get(message.request.message))) {
                    self.message = null;
                    self.input = .{};
                    try self.clock.?.resumeAfterPause(deadline);
                    return;
                }
                if (self.replay) |*replay| {
                    const sample = replay.next() orelse {
                        self.aborted = true;
                        return;
                    };
                    message.keys = @as(u3, @intFromBool(sample.action)) | (@as(
                        u3,
                        @intFromBool(sample.use_item),
                    ) << 1) | (@as(u3, @intFromBool(sample.weapon)) << 2);
                }
                message.latchInput();
                continue;
            }
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
                    dialog.keys.directions = .{
                        .left = sample.left,
                        .right = sample.right,
                        .up = sample.up,
                        .down = sample.down,
                    };
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
            const room_before_step = self.environment.room;
            self.sound_event_count = 0;
            self.scripted_transport.beginStep();
            self.timed_items.beginStep();
            self.environmental_alarms.beginStep();
            self.enemy_barriers.beginStep();
            self.props.beginStep();
            self.triggered_effects.beginStep();
            try self.inventory_grants.beginStep(
                self.content.inventory_grants.definitions,
                &self.equipment,
            );
            self.hazards.beginStep();
            self.detectors.beginStep();
            self.ceiling_guns.beginStep();
            self.doors.beginStep();
            self.platform_sections.beginStep();
            self.lifts.beginStep();
            self.ceiling_fire.beginStep();
            self.gunmen.prepare();
            try self.guards.prepare(
                self.content.guards.definitions,
                self.terrain.map(),
                self.environment.room,
            );
            self.guard_fire.beginStep();
            self.barriers.beginStep();
            self.robots.prepare();
            self.enemy_fire.beginStep();
            if (self.protection_steps != 0) self.protection_steps -= 1;
            try self.escort_followers.prepare(
                self.content.escort_followers.definitions,
                self.terrain.map(),
                .{
                    .room = self.environment.room,
                    .position = self.pose.position,
                    .width = self.content.player_contact_width,
                },
            );
            try self.rescue_contacts.prepare(
                self.content.rescue_contacts.definitions,
                self.terrain.map(),
                .{
                    .room = self.environment.room,
                    .position = self.pose.position,
                    .width = self.content.player_contact_width,
                },
            );
            var weight_count = self.escort_followers.weighted_count;
            @memcpy(
                self.weighted_characters[0..weight_count],
                self.escort_followers.weighted_contacts[0..weight_count],
            );
            for (
                self.rescue_contacts.actors,
                self.content.rescue_contacts.definitions,
            ) |actor, definition| if (actor.body(definition) != null and
                actor.clip(definition).presses_floor_switches)
            {
                self.weighted_characters[weight_count] = actor.contact;
                weight_count += 1;
            };
            self.props.actor_contacts = self.weighted_characters[0..weight_count];
            try self.props.prepare(
                self.terrain.map(),
                &self.equipment,
                .{
                    .room = self.environment.room,
                    .position = self.pose.position,
                    .width = self.content.player_contact_width,
                },
            );
            try self.item_aid.prepare(
                self.content.item_aid.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.traders.prepare(
                self.content.traders.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.guides.prepare(
                self.content.guides.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.story_stations.prepare(
                self.content.story_stations.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.syncVisibility();
            try self.visibility.rebuild(self.terrain.map(), self.environment.room);
            self.interaction = try self.chooseInteraction();
            try self.attentive_contacts.prepare(
                self.content.attentive_contacts.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.quest_contacts.prepare(
                self.content.quest_contacts.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.credential_terminals.prepare(
                self.content.credential_terminals.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.mission_terminals.prepare(
                self.content.mission_terminals.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.service_counters.prepare(
                self.content.service_counters.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.operated_controls.prepare(
                self.content.controls.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            for (self.content.locks.quest_receivers) |binding| self.locks.setReceiverBody(
                binding.receiver,
                self.quest_contacts.instances[binding.contact].body(self.content.quest_contacts.definitions[binding.contact]),
            );
            try self.locks.prepare(
                self.content.locks.definitions,
                self.content.locks.receivers,
                self.terrain.map(),
                self.props.player_contact,
            );
            try self.passengers.prepare(
                self.terrain.map(),
                self.props.player_contact,
                &self.lifts,
                self.content.lifts.definitions,
                &self.props,
                &self.equipment,
                self.content.lift_passengers,
            );
            for (self.gunmen.actors) |actor| if (!actor.lost) try self.passengers.includeActor(
                self.terrain.map(),
                actor.contact,
                &self.lifts,
                self.content.lifts.definitions,
            );
            for (self.robots.actors) |actor| if (!actor.removed) try self.passengers.includeActor(
                self.terrain.map(),
                actor.contact,
                &self.lifts,
                self.content.lifts.definitions,
            );
            self.controller.ride_available = self.passengers.candidate != null;
            self.controller.ride_acknowledged = self.passengers.acknowledged != null;
            self.controller.ride_arrived = self.passengers.arrival;
            try self.energy_stations.prepare(
                self.content.energy_stations.definitions,
                self.terrain.map(),
                self.props.player_contact,
            );
            self.controller.control_available = self.credential_terminals.candidate != null or
                self.interaction != .none or
                self.attentive_contacts.candidate != null or
                self.quest_contacts.candidate != null or
                self.mission_terminals.candidate != null or
                self.service_counters.candidate != null or
                self.operated_controls.candidate != null or
                self.locks.candidate != null or
                self.energy_stations.candidate != null;
            self.controller.pickup_available = self.props.pickup_candidate != null and
                self.interaction == .none;
            const selected = try self.equipment.selected();
            // Presenting a possession is a player gesture; its receiver decides whether
            // it has an applicable use. Even a nonmatching card retains the hand motion.
            self.controller.use_available = selected != null;
            self.controller.use_reaches = if (selected) |item| item.definition.use_motion == .reach else false;
            self.controller.throw_available = if (selected) |item| if (item.definition.use_action) |action| action == .throw_item else false else false;
            self.controller.weapon_desired = self.weapon_toggle.desired;
            self.controller.health_before_step = self.health;
            const transport_request = self.scripted_transport.requesting();
            self.controller.transport_requested = transport_request != null;
            const result = try self.controller.advanceIn(
                self.content.controllerClips(),
                intent,
                &self.pose,
                &self.environment,
            );
            if (result != .advanced) return error.UnimplementedMovementTransition;
            if (self.controller.ride_requested) |destination| self.lifts.requestRide(
                self.passengers.candidate orelse return error.MissingLiftContact,
                destination,
            );
            self.passengers.playerUpdated(self.controller.ride_boarded, self.controller.ride_left);
            self.health -%= self.controller.damage_requested;
            if (self.controller.grant_protection) self.protection_steps = 60;
            self.weapon_toggle.advance(intent.weapon, self.equipment.carries(.gun));
            if (self.controller.sound_requested) |sound| try self.emitSound(
                sound,
                self.environment.room,
            );
            if (self.controller.fatal_landing) self.health = -1;
            if (self.death_wait == null) self.death_wait = self.controller.death_wait_requested;
            self.received_count = try self.equipment.advance(self.health, self.received_items);
            try self.inventory_grants.observeConsumptions(
                self.content.inventory_grants.definitions,
                &self.equipment,
            );
            if (self.equipment.used_movie) |movie| self.pending_movie = movie;
            if (self.equipment.recharged) |event| {
                if (event.health) |health| self.health = health;
                if (event.movie) |movie| self.pending_movie = movie;
            }
            if (self.controller.use_requested) {
                const item = selected orelse return error.MissingSelectedItem;
                if (!self.controller.use_reaches and
                    !(if (item.definition.use_action) |action| action == .pay or
                        action == .deploy_field else false)) self.input.consumeUse();
                const handle = self.equipment.inventory.selected() orelse return error.MissingSelectedItem;
                var handled = false;
                if (item.definition.use_action) |action| switch (action) {
                    .story => |cue| {
                        self.pending_movie = cue;
                        handled = true;
                    },
                    .deploy_field => handled = true,
                    .pay => {
                        handled = switch (self.interaction) {
                            .trader => self.traders.offerPayment(
                                self.content.traders.definitions,
                                self.content.traders.bindings,
                                handle,
                                item.quantity,
                            ),
                            .item_aid => try self.item_aid.offerPayment(
                                self.content.item_aid.definitions,
                                self.content.item_aid.bindings,
                                handle,
                                item.quantity,
                            ),
                            .guide => self.guides.offerPayment(
                                self.content.guides.definitions,
                                self.content.guides.payments,
                                handle,
                                item.quantity,
                            ),
                            .quest => self.quest_contacts.offerPayment(
                                self.content.quest_contacts.definitions,
                                self.content.quest_contacts.payments,
                                handle,
                                item.quantity,
                            ),
                            .none, .station, .host, .escort, .rescue => false,
                        };
                    },
                    .offer => |offer| {
                        handled = self.interaction == .item_aid and try self.item_aid.offer(
                            self.content.item_aid.definitions,
                            self.content.item_aid.bindings,
                            handle,
                            offer.credential,
                        );
                    },
                    .unlock => |use| {
                        handled = try self.locks.useKey(
                            self.content.locks.definitions,
                            self.content.locks.receivers,
                            self.content.locks.bindings,
                            &self.equipment,
                            handle,
                            self.terrain.map(),
                            self.environment.room,
                        );
                        if (handled) if (use.movie) |movie| {
                            self.pending_movie = movie;
                        };
                    },
                    .throw_item => {
                        try self.props.throwItem(
                            &self.equipment,
                            handle,
                            self.pose,
                            self.environment.room,
                        );
                        handled = true;
                    },
                };
                if (!handled and
                    self.energy_stations.candidate != null and
                    try self.equipment.beginRecharge(handle))
                {
                    const recharge = item.definition.recharge.?;
                    if (recharge.movie_when == .start) self.pending_movie = recharge.movie;
                }
            }
            try self.props.advance(
                self.terrain.map(),
                &self.equipment,
                try self.controller.pressesFloorSwitches(self.content.controllerClips()),
                self.controller.pickup_requested,
            );
            try self.operated_controls.advance(
                self.content.controls.definitions,
                self.terrain.map(),
                self.environment.room,
                self.controller.operate_requested and
                    self.interaction == .none and
                    self.locks.candidate == null,
            );
            try self.locks.advance(
                self.content.locks.definitions,
                self.terrain.map(),
                self.environment.room,
                self.controller.operate_requested and self.interaction == .none,
            );
            self.mission_terminals.route(
                self.content.mission_terminal_bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.environmental_alarms.advance(
                self.content.environmental_alarms.definitions,
                &self.random,
            );
            for (
                self.environmental_alarms.instances,
                self.content.environmental_alarms.definitions,
            ) |instance, definition| {
                if (instance.sound) |sound| try self.emitEffect(.{ .sound = sound });
                if (instance.animation_sound) |sound| if (definition.room) |room| try self.emitSound(
                    sound,
                    room,
                );
            }
            try self.mission_terminals.advance(
                self.content.mission_terminals.definitions,
                self.content.mission_terminal_bindings,
                self.terrain.map(),
                self.environment.room,
                self.controller.operate_requested and self.interaction == .none,
                &self.equipment,
            );
            self.doors.route(
                self.content.doors.bindings,
                self.mission_terminals.pulses[0..self.mission_terminals.pulse_count],
            );
            self.scripted_transport.route(
                self.content.transport_bindings,
                self.mission_terminals.pulses[0..self.mission_terminals.pulse_count],
            );
            self.guards.route(
                self.content.guard_bindings,
                self.mission_terminals.pulses[0..self.mission_terminals.pulse_count],
            );
            for (
                self.mission_terminals.instances,
                self.content.mission_terminals.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            try self.energy_stations.advance(
                self.content.energy_stations.definitions,
                self.terrain.map(),
                self.environment.room,
            );
            self.lifts.route(
                self.content.lifts.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.lifts.route(
                self.content.lifts.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.lifts.route(
                self.content.lifts.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            var sensed_count: usize = 1;
            for (
                self.escort_followers.actors,
                self.content.escort_followers.definitions,
            ) |actor, definition| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .interactable,
                    .active = actor.active,
                    .ordinary_contact = definition.clips[@backingInt(actor.phase)].ordinary_contact,
                };
                sensed_count += 1;
            }
            for (
                self.rescue_contacts.actors,
                self.content.rescue_contacts.definitions,
            ) |actor, definition| if (actor.body(definition) != null) {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .interactable,
                    .active = actor.active,
                    .ordinary_contact = actor.clip(definition).ordinary_contact,
                };
                sensed_count += 1;
            };
            for (
                self.enemy_barriers.emitters,
                self.content.enemy_barriers.definitions,
            ) |field, definition| if (field.body(definition)) |body| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = body,
                    .kind = .enemy,
                    .active = true,
                };
                sensed_count += 1;
            };
            self.sensed_contacts[0] = .{
                .footprint = self.props.player_contact,
                .kind = .player,
                .active = true,
                .ordinary_contact = try self.controller.ordinaryContact(self.content.controllerClips()),
            };
            for (self.gunmen.actors) |actor| {
                if (actor.dormant) continue;
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .enemy,
                    .active = actor.active and !actor.lost,
                };
                sensed_count += 1;
            }
            for (self.robots.actors) |actor| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .enemy,
                    .active = actor.active and !actor.removed,
                };
                sensed_count += 1;
            }
            for (self.guards.actors) |actor| if (actor.contact) |contact| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = contact,
                    .kind = .enemy,
                    .active = actor.active and actor.activity != .removed,
                };
                sensed_count += 1;
            };
            for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
                if (definition.behavior != .collectible) continue;
                const visible = try self.props.visible(index, &self.equipment);
                const clip = if (object.flight) |flight| flight.clip(definition.behavior.collectible.throw_motion orelse return error.MissingThrowMotion) else definition.behavior.collectible.idle;
                self.sensed_contacts[sensed_count] = .{
                    .footprint = object.contact,
                    .kind = .interactable,
                    .active = object.active and object.contact_present and visible,
                    .ordinary_contact = visible and clip.ordinary_contact,
                };
                sensed_count += 1;
            }
            for (
                self.quest_contacts.instances,
                self.content.quest_contacts.definitions,
            ) |instance, definition| if (instance.body(definition)) |body| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = body,
                    .kind = definition.contact_kind,
                    .active = instance.active,
                    .ordinary_contact = instance.clip(definition).ordinary_contact,
                };
                sensed_count += 1;
            };
            for (
                self.attentive_contacts.instances,
                self.content.attentive_contacts.definitions,
            ) |instance, definition| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = definition.footprint,
                    .kind = .interactable,
                    .active = instance.active,
                    .ordinary_contact = instance.clip(definition).ordinary_contact,
                };
                sensed_count += 1;
            }
            for (
                self.item_aid.actors,
                self.content.item_aid.definitions,
            ) |actor, definition| if (actor.phase != .gone) {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .interactable,
                    .active = actor.active,
                    .ordinary_contact = actor.clip(self.content.item_aid.profiles[definition.profile]).ordinary_contact,
                };
                sensed_count += 1;
            };
            for (self.guides.actors, self.content.guides.definitions) |actor, definition| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .interactable,
                    .active = actor.active,
                    .ordinary_contact = self.content.guides.profiles[definition.profile].clips[@backingInt(actor.phase)].ordinary_contact,
                };
                sensed_count += 1;
            }
            for (self.traders.actors, self.content.traders.definitions) |actor, definition| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = actor.contact,
                    .kind = .interactable,
                    .active = actor.active,
                    .ordinary_contact = self.content.traders.profiles[definition.profile].clips[@backingInt(actor.phase)].ordinary_contact,
                };
                sensed_count += 1;
            }
            for (self.doors.instances, self.content.doors.definitions) |instance, definition| {
                self.sensed_contacts[sensed_count] = .{
                    .footprint = definition.footprint,
                    .kind = if (definition.enemy_contact) .enemy else .mechanism,
                    .active = instance.active,
                };
                sensed_count += 1;
            }
            self.detectors.route(
                self.content.detectors.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.detectors.route(
                self.content.detectors.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.detectors.route(
                self.content.detectors.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            try self.detectors.advance(
                self.content.detectors.definitions,
                self.content.detectors.profiles,
                self.content.detectors.bindings,
                self.terrain.map(),
                .{ .room = self.environment.room, .position = self.pose.position },
                self.sensed_contacts[0..sensed_count],
            );
            self.lifts.route(
                self.content.lifts.bindings,
                self.detectors.pulses[0..self.detectors.pulse_count],
            );
            try self.passengers.updateItemOccupancy(
                self.terrain.map(),
                &self.lifts,
                self.content.lifts.definitions,
                &self.props,
                &self.equipment,
            );
            try self.escort_followers.includeOccupancy(
                self.terrain.map(),
                &self.lifts,
                self.content.lifts.definitions,
                self.passengers.occupancy,
            );
            try self.lifts.advance(
                self.content.lifts.definitions,
                self.content.lifts.profiles,
                &self.terrain,
                self.passengers.occupancy,
                self.environment.room,
            );
            try self.passengers.deliver(
                &self.lifts,
                self.content.lifts.definitions,
                self.content.lift_passengers,
                self.terrain.map(),
                &self.props,
                &self.equipment,
                &self.pose,
                self.environment.room,
            );
            try self.escort_followers.receiveLiftEvents(
                self.content.escort_followers.lift_bindings,
                &self.lifts,
                self.content.lifts.definitions,
                self.terrain.map(),
            );
            try self.guides.advance(
                self.content.guides.definitions,
                self.content.guides.profiles,
                self.terrain.map(),
                self.props.player_contact,
                self.controller.operate_requested and self.interaction == .guide,
            );
            self.doors.route(
                self.content.doors.bindings,
                self.guides.pulses[0..self.guides.pulse_count],
            );
            self.story_stations.route(
                self.content.story_station_bindings,
                self.guides.pulses[0..self.guides.pulse_count],
            );
            try self.inventory_grants.deliver(
                self.content.inventory_grants.definitions,
                self.content.inventory_grants.bindings,
                self.guides.pulses[0..self.guides.pulse_count],
                &self.equipment,
            );
            try self.item_aid.advance(
                self.content.item_aid.definitions,
                self.content.item_aid.profiles,
                self.terrain.map(),
                self.props.player_contact,
                self.controller.operate_requested and self.interaction == .item_aid,
            );
            try self.props.deliver(
                self.content.item_bindings,
                self.item_aid.pulses[0..self.item_aid.pulse_count],
                &self.equipment,
            );
            self.doors.route(
                self.content.doors.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.doors.route(
                self.content.doors.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.doors.route(
                self.content.doors.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.doors.route(
                self.content.doors.bindings,
                self.lifts.pulses[0..self.lifts.pulse_count],
            );
            self.doors.route(
                self.content.doors.bindings,
                self.detectors.pulses[0..self.detectors.pulse_count],
            );
            self.platform_sections.route(
                self.content.platform_sections.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.platform_sections.route(
                self.content.platform_sections.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.platform_sections.route(
                self.content.platform_sections.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.platform_sections.route(
                self.content.platform_sections.bindings,
                self.detectors.pulses[0..self.detectors.pulse_count],
            );
            self.platform_sections.route(
                self.content.platform_sections.bindings,
                self.lifts.pulses[0..self.lifts.pulse_count],
            );
            try self.platform_sections.advance(
                self.content.platform_sections.definitions,
                &self.terrain,
                self.environment.room,
            );
            try self.doors.advance(
                self.content.doors.definitions,
                self.content.doors.profiles,
                &self.terrain,
                self.environment.room,
                self.sensed_contacts[0..sensed_count],
                .before_fire,
            );
            self.ceiling_guns.route(
                self.content.ceiling_guns.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.ceiling_guns.route(
                self.content.ceiling_guns.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.ceiling_guns.route(
                self.content.ceiling_guns.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.ceiling_guns.route(
                self.content.ceiling_guns.bindings,
                self.lifts.pulses[0..self.lifts.pulse_count],
            );
            self.ceiling_guns.route(
                self.content.ceiling_guns.bindings,
                self.detectors.pulses[0..self.detectors.pulse_count],
            );
            try self.ceiling_guns.advance(
                self.content.ceiling_guns.definitions,
                self.content.ceiling_guns.profiles,
                self.terrain.map(),
                self.environment.room,
            );
            for (
                self.ceiling_guns.instances,
                self.content.ceiling_guns.definitions,
            ) |instance, definition| if (instance.fire) self.ceiling_fire.fire(
                definition.weapon,
                .{ .pose = instance.pose, .room = definition.room, .height = .standing },
                definition.shot_next_step,
            );
            self.hazards.route(
                self.content.hazards.bindings,
                self.detectors.pulses[0..self.detectors.pulse_count],
            );
            self.hazards.route(
                self.content.hazards.bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.hazards.route(
                self.content.hazards.bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.hazards.route(
                self.content.hazards.bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.hazards.route(
                self.content.hazards.bindings,
                self.lifts.pulses[0..self.lifts.pulse_count],
            );
            try self.hazards.advance(
                self.content.hazards.definitions,
                self.terrain.map(),
                self.environment.room,
                self.props.player_contact,
            );
            var distraction_count: usize = 0;
            for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
                if (!object.active or
                    !object.contact_present or
                    definition.behavior != .collectible) continue;
                if (!try self.props.visible(index, &self.equipment)) continue;
                self.distractions[distraction_count] = object.contact;
                distraction_count += 1;
            }
            self.combat_targets[0] = .{
                .id = @fromBackingInt(0),
                .category = .player,
                .footprint = self.props.player_contact,
                .facing = self.pose.facing,
                .vulnerable = try self.controller.vulnerability(self.content.controllerClips()),
            };
            for (
                self.gunmen.actors,
                self.content.gunmen.definitions,
                self.combat_targets[1 .. 1 + self.gunmen.actors.len],
                0..,
            ) |actor, definition, *target, index| {
                target.* = .{
                    .id = @fromBackingInt(@as(u16, @intCast(index + 1))),
                    .footprint = actor.contact,
                    .facing = actor.pose.facing,
                    .vulnerable = actor.vulnerability(self.content.gunmen.profiles[definition.profile]),
                    .active = actor.active and !actor.lost,
                };
            }
            const first_robot = 1 + self.gunmen.actors.len;
            for (
                self.robots.actors,
                self.combat_targets[first_robot .. first_robot + self.robots.actors.len],
                0..,
            ) |actor, *target, index| {
                target.* = .{
                    .id = @fromBackingInt(@as(u16, @intCast(first_robot + index))),
                    .footprint = actor.contact,
                    .facing = actor.pose.facing,
                    .vulnerable = actor.vulnerability(),
                    .active = actor.active and !actor.removed,
                };
            }
            const first_guard = first_robot + self.robots.actors.len;
            for (
                self.guards.actors,
                self.content.guards.definitions,
                self.combat_targets[first_guard .. first_guard + self.guards.actors.len],
                0..,
            ) |actor, definition, *target, index| {
                target.* = .{
                    .id = @fromBackingInt(@as(u16, @intCast(first_guard + index))),
                    .footprint = actor.contact orelse .{
                        .room = self.environment.room,
                        .position = actor.pose.position,
                        .width = 0,
                    },
                    .facing = actor.pose.facing,
                    .vulnerable = actor.vulnerability(self.content.guards.profiles[definition.profile]),
                    .active = actor.active and actor.room != null and actor.activity != .removed,
                };
            }
            const first_door = first_guard + self.guards.actors.len;
            for (
                self.doors.instances,
                self.content.doors.definitions,
                self.combat_targets[first_door .. first_door + self.doors.instances.len],
                0..,
            ) |instance, definition, *target, index| {
                target.* = .{
                    .id = @fromBackingInt(@as(u16, @intCast(first_door + index))),
                    .footprint = definition.footprint,
                    .facing = instance.pose.facing,
                    .vulnerable = instance.vulnerability(self.content.doors.profiles[definition.profile]),
                    .active = instance.active,
                    .category = if (definition.enemy_contact) .enemy else .mechanism,
                };
            }
            const first_field = first_door + self.doors.instances.len;
            for (
                self.force_fields,
                self.content.force_fields.definitions,
                self.combat_targets[first_field..][0..self.force_fields.len],
                0..,
            ) |field, definition, *target, index| target.* = field.target(
                definition,
                @fromBackingInt(@as(u16, @intCast(first_field + index))),
                self.environment.room,
            );
            const first_enemy_barrier = first_field + self.force_fields.len;
            for (
                self.enemy_barriers.emitters,
                self.content.enemy_barriers.definitions,
                self.combat_targets[first_enemy_barrier..],
                0..,
            ) |field, definition, *target, index| target.* = field.target(
                definition,
                @fromBackingInt(@as(u16, @intCast(first_enemy_barrier + index))),
                self.environment.room,
            );
            self.guards.route(
                self.content.guard_bindings,
                self.inventory_grants.pulses[0..self.inventory_grants.pulse_count],
            );
            self.guards.route(
                self.content.guard_bindings,
                self.operated_controls.pulses[0..self.operated_controls.pulse_count],
            );
            self.guards.route(
                self.content.guard_bindings,
                self.props.pressed_circuits[0..self.props.pressed_count],
            );
            self.guards.route(
                self.content.guard_bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.service_counters.route(
                self.content.service_counter_bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.quest_contacts.route(
                self.content.quest_contact_bindings,
                self.mission_terminals.pulses[0..self.mission_terminals.pulse_count],
            );
            self.quest_contacts.route(
                self.content.quest_contact_bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            try self.syncVisibility();
            try self.advanceCharacters(intent, distraction_count, first_guard);
            for (
                self.gunmen.actors,
                self.content.gunmen.definitions,
            ) |actor, definition| if (actor.shot) |height| self.enemy_fire.fire(
                definition.weapon,
                .{ .pose = actor.pose, .room = actor.room, .height = height },
                definition.shot_next_step,
            );
            try self.enemy_fire.advance(
                self.content.gunmen.weapons,
                self.terrain.view(),
                self.combat_targets,
            );
            for (self.enemy_fire.channels) |channel| {
                if (channel.state.hit_requested) |hit| self.deliverHit(hit);
                if (channel.state.sound_requested) |sound| try self.emitSound(
                    sound,
                    channel.state.effect.?.room,
                );
            }
            for (
                self.guards.actors,
                self.content.guards.definitions,
            ) |actor, definition| if (actor.shot) |posture| {
                self.guard_fire.fire(
                    definition.weapon,
                    .{
                        .pose = actor.pose,
                        .room = actor.room.?,
                        .height = if (posture == .standing) .standing else .crouched,
                        .airborne = posture == .airborne,
                    },
                    definition.shot_next_step,
                );
            };
            try self.guard_fire.advance(
                self.content.guards.weapons,
                self.terrain.view(),
                self.combat_targets,
            );
            for (self.guard_fire.channels) |channel| {
                if (channel.state.hit_requested) |hit| self.deliverHit(hit);
                if (channel.state.sound_requested) |sound| try self.emitSound(
                    sound,
                    channel.state.effect.?.room,
                );
            }
            self.barriers.route(
                self.content.barrier_bindings,
                self.guards.pulses[0..self.guards.pulse_count],
            );
            self.barriers.advance(self.content.barriers.definitions);
            self.guides.route(
                self.content.guide_bindings,
                self.barriers.pulses[0..self.barriers.pulse_count],
            );
            self.story_stations.advance(
                self.content.story_stations.definitions,
                self.controller.operate_requested and self.interaction == .station,
            );
            self.guides.route(
                self.content.guide_bindings,
                self.story_stations.pulses[0..self.story_stations.pulse_count],
            );
            try self.ceiling_fire.advance(
                self.content.ceiling_guns.weapons,
                self.terrain.view(),
                self.combat_targets,
            );
            for (self.ceiling_fire.channels) |channel| {
                if (channel.state.hit_requested) |hit| self.deliverHit(hit);
                if (channel.state.sound_requested) |sound| try self.emitSound(
                    sound,
                    channel.state.effect.?.room,
                );
            }
            self.casings.advance(
                self.content.casing_definition,
                self.controller.shot_requested,
                self.pose,
                self.environment.room,
                &self.random,
            );
            try self.doors.advance(
                self.content.doors.definitions,
                self.content.doors.profiles,
                &self.terrain,
                self.environment.room,
                self.sensed_contacts[0..sensed_count],
                .after_fire,
            );
            try self.surfaces.advance(
                self.content.surfaces,
                self.content.surfaceClips(),
                self.terrain.map(),
                self.props.player_contact,
                try self.controller.disturbsSurface(self.content.controllerClips()),
                &self.random,
            );
            try self.traders.advance(
                self.content.traders.definitions,
                self.content.traders.profiles,
                self.terrain.map(),
                self.props.player_contact,
                self.controller.operate_requested and self.interaction == .trader,
                &self.equipment,
                &self.random,
            );
            try self.inventory_grants.deliver(
                self.content.inventory_grants.definitions,
                self.content.inventory_grants.bindings,
                self.traders.pulses[0..self.traders.pulse_count],
                &self.equipment,
            );
            try self.exits.advance(
                self.content.exits,
                self.terrain.map(),
                self.props.player_contact,
                &self.equipment,
            );
            self.triggered_effects.route(
                self.content.triggered_effects.bindings,
                self.traders.pulses[0..self.traders.pulse_count],
            );
            try self.triggered_effects.advance(
                self.content.triggered_effects.definitions,
                self.terrain.map(),
                self.environment.room,
            );
            self.last_ambient = if (self.content.forest_enabled) self.ambience.advance(
                .{
                    .quiet_steps = self.content.forest_quiet_steps,
                    .calls = self.content.forest_calls,
                },
                self.environment.room,
                &self.random,
            ) else null;
            try self.robots.advance(
                self.content.robots.definitions,
                self.content.robots.profiles,
                self.terrain.view(),
                .{ .room = self.environment.room, .position = self.pose.position },
                self.combat_targets,
                first_robot,
            );
            if (try self.scripted_transport.advance(
                self.content.scripted_transport.definitions,
                if (self.controller.transport_acknowledged) transport_request else null,
                self.props.player_contact,
                self.terrain.map(),
            )) |destination| {
                self.pose.position = destination.position;
                self.pose.facing = destination.facing;
                self.environment.room = destination.room;
                self.controller.activity = .standing;
                self.controller.playback = .{};
            }
            self.scripted_transport.advanceEffects(
                self.content.scripted_transport.effects,
                self.pose,
                self.environment.room,
            );
            for (self.scripted_transport.effects) |instance| if (instance.sound) |sound| if (instance.effect_room) |room| try self.emitSound(
                sound,
                room,
            );
            self.timed_items.route(
                self.content.timed_item_bindings,
                self.scripted_transport.pulses[0..self.scripted_transport.pulse_count],
            );
            try self.timed_items.advance(self.content.timed_items.definitions, &self.equipment);
            try self.inventory_grants.deliver(
                self.content.inventory_grants.definitions,
                self.content.inventory_grants.bindings,
                self.timed_items.pulses[0..self.timed_items.pulse_count],
                &self.equipment,
            );
            self.mission_terminals.route(
                self.content.mission_terminal_bindings,
                self.timed_items.pulses[0..self.timed_items.pulse_count],
            );
            if (std.mem.indexOfScalar(
                geometry.RoomId,
                self.content.timed_items.audible_rooms,
                self.environment.room,
            ) != null) {
                for (self.timed_items.instances) |instance| if (instance.sound) |sound| try self.emitEffect(.{
                    .sound = sound,
                    .attenuation = 1,
                });
            }
            self.credential_terminals.route(
                self.content.credential_terminal_bindings,
                self.locks.pulses[0..self.locks.pulse_count],
            );
            self.credential_terminals.advance(
                self.content.credential_terminals.definitions,
                self.content.credential_terminal_bindings,
                self.controller.operate_requested and self.interaction == .none,
            );
            self.timed_items.route(
                self.content.timed_item_bindings,
                self.credential_terminals.pulses[0..self.credential_terminals.pulse_count],
            );
            self.scripted_transport.route(
                self.content.transport_bindings,
                self.credential_terminals.pulses[0..self.credential_terminals.pulse_count],
            );
            self.environmental_alarms.route(
                self.content.alarm_bindings,
                self.inventory_grants.pulses[0..self.inventory_grants.pulse_count],
            );
            self.environmental_alarms.route(
                self.content.alarm_bindings,
                self.timed_items.pulses[0..self.timed_items.pulse_count],
            );
            try self.escort_followers.advance(
                self.content.escort_followers.definitions,
                self.terrain.map(),
                .{
                    .room = self.environment.room,
                    .position = self.pose.position,
                    .width = self.content.player_contact_width,
                },
                self.controller.operate_requested and self.interaction == .escort,
            );
            try self.arrival_triggers.advance(
                self.content.arrival_triggers.definitions,
                self.terrain.map(),
                self.environment.room,
                self.sensed_contacts[0..sensed_count],
                self.message_icon,
            );
            self.mission_terminals.route(
                self.content.mission_terminal_bindings,
                self.arrival_triggers.pulses[0..self.arrival_triggers.pulse_count],
            );
            self.scripted_transport.route(
                self.content.transport_bindings,
                self.arrival_triggers.pulses[0..self.arrival_triggers.pulse_count],
            );
            for (self.escort_followers.actors) |actor| if (actor.sound) |sound| try self.emitSound(
                sound,
                actor.room,
            );
            for (self.robots.outgoing[0..self.robots.outgoing_count]) |hit| self.deliverHit(hit);
            for (self.robots.actors) |actor| if (actor.sound) |sound| try self.emitSound(
                sound,
                actor.room,
            );
            const deploy_field = if (selected) |item| if (item.definition.use_action) |action| action == .deploy_field and
                intent.use_item and
                !intent.action and
                !intent.weapon else false else false;
            for (self.force_fields, self.content.force_fields.definitions) |*field, definition| {
                try field.advance(
                    definition,
                    deploy_field,
                    self.pose,
                    self.environment.room,
                    self.terrain.view(),
                    self.combat_targets,
                );
                if (field.sound) |sound| if (field.room) |room| try self.emitSound(sound, room);
            }
            for (self.barrier_owners, self.gunmen.actors) |*owner, actor| owner.* = .{
                .pose = actor.pose,
                .room = actor.room,
            };
            try self.enemy_barriers.advance(
                self.content.enemy_barriers.definitions,
                self.barrier_owners,
                self.terrain.map(),
            );
            for (self.enemy_barriers.emitters) |field| if (field.sound) |sound| if (field.room) |room| try self.emitSound(
                sound,
                room,
            );
            try self.ambient_people.advance(
                self.content.ambient_people.definitions,
                self.content.ambient_people.profiles,
                self.terrain.map(),
                self.environment.room,
                &self.random,
            );
            for (self.ambient_people.actors) |actor| if (actor.sound) |sound| try self.emitSound(
                sound,
                actor.room,
            );
            for (self.triggered_effects.instances) |instance| if (instance.sound) |sound| try self.emitSound(
                sound,
                instance.room,
            );
            for (
                self.traders.actors,
                self.content.traders.definitions,
            ) |actor, definition| if (actor.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.story_stations.instances,
                self.content.story_stations.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (self.guides.actors) |actor| if (actor.sound) |sound| try self.emitSound(
                sound,
                actor.room,
            );
            for (self.item_aid.actors) |actor| if (actor.sound) |sound| try self.emitSound(
                sound,
                actor.room,
            );
            for (self.lifts.instances) |instance| if (instance.sound) |sound| try self.emitSound(
                sound,
                instance.room,
            );
            for (
                self.doors.instances,
                self.content.doors.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.detectors.instances,
                self.content.detectors.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.room,
            );
            for (
                self.ceiling_guns.instances,
                self.content.ceiling_guns.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.room,
            );
            for (
                self.hazards.instances,
                self.content.hazards.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.energy_stations.instances,
                self.content.energy_stations.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.platform_sections.instances,
                self.content.platform_sections.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.locks.instances,
                self.content.locks.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (
                self.operated_controls.instances,
                self.content.controls.definitions,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            for (self.props.objects) |object| if (object.sound_requested) |sound| try self.emitSound(
                sound,
                object.room,
            );
            if (self.pistol.sound_requested) |sound| try self.emitSound(
                sound,
                self.pistol.effect.?.room,
            );
            for (
                self.surfaces.instances,
                self.content.surfaces,
            ) |instance, definition| if (instance.sound) |sound| try self.emitSound(
                sound,
                definition.footprint.room,
            );
            if (self.last_ambient) |event| try self.emitSound(event.sound, event.room);
            if (self.props.acquired) |handle| {
                const item = try self.equipment.item(handle);
                self.received_items[self.received_count] = .{
                    .item = handle,
                    .kind = item.definition.kind,
                };
                self.received_count += 1;
            }
            for (self.lifts.instances) |instance| if (instance.movie) |movie| {
                self.pending_movie = movie;
            };
            if (self.mission_terminals.movie) |movie| self.pending_movie = movie;
            if (self.props.movie) |movie| self.pending_movie = movie;
            if (self.traders.movie) |movie| self.pending_movie = movie;
            if (self.inventory_grants.movie) |movie| self.pending_movie = movie;
            if (self.story_stations.movie) |movie| self.pending_movie = movie;
            if (self.timed_items.failure) |movie| self.pending_movie = movie;
            if (self.hazards.defeat_requested) self.pending_movie = .disintegration;
            if (self.replay != null or
                try self.interactionHint() != null) self.level_code_steps = 0 else if (self.level_code_steps != 0)
            {
                self.level_code_steps -= 1;
            }
            self.simulation_steps += 1;
            if (self.zoom_room != null and
                self.zoom_room.? != self.environment.room and
                self.settings.zoom == .on) self.settings.zoom = .off;
            self.zoom_room = self.environment.room;
            self.zoom.setActive(self.settings.zoom == .on, self.pose);
            if (self.environment.room != room_before_step) self.environmental_alarms.shake_rows = 0;
            self.zoom.advance(self.pose);
            self.clock.?.consume();
            var request = self.locks.notice;
            if (self.rescue_contacts.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.credential_terminals.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.arrival_triggers.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.escort_followers.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.attentive_contacts.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.quest_contacts.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (self.service_counters.notice) |notice| if (request == null or
                notice.priority >= request.?.priority)
            {
                request = notice;
            };
            if (request == null) if (self.equipment.notice) |id| {
                request = .{ .message = id, .icon = self.message_icon, .priority = 0 };
            };
            if (self.item_aid.notice) |id| {
                if (request == null or
                    self.item_aid.notice_priority >= request.?.priority) request = .{
                    .message = id,
                    .icon = self.message_icon,
                    .priority = self.item_aid.notice_priority,
                };
            }
            if (self.traders.notice) |id| {
                if (request == null or
                    self.traders.notice_priority >= request.?.priority) request = .{
                    .message = id,
                    .icon = self.message_icon,
                    .priority = self.traders.notice_priority,
                };
            }
            if (self.guides.notice) |id| {
                if (request == null or
                    self.guides.notice_priority >= request.?.priority) request = .{
                    .message = id,
                    .icon = self.message_icon,
                    .priority = self.guides.notice_priority,
                };
            }
            if (request) |notice| {
                _ = try self.content.messages.get(notice.message);
                if (try self.interactionHint()) |hint| self.message_icon = hint.icon;
                var presentation = notice;
                presentation.icon = self.message_icon;
                self.message = try world_messages.State.init(
                    presentation,
                    deadline,
                );
                if (self.replay) |*replay| {
                    const sample = replay.next() orelse {
                        self.aborted = true;
                        return;
                    };
                    self.message.?.keys = @as(u3, @intFromBool(sample.action)) | (@as(
                        u3,
                        @intFromBool(sample.use_item),
                    ) << 1) | (@as(u3, @intFromBool(sample.weapon)) << 2);
                    self.message.?.latchInput();
                }
                self.input = .{};
                return;
            }
            if (self.input.options) {
                self.options = .{
                    .menu = .{ .settings = self.settings },
                    .clock = try clock_mod.Clock.init(clock_mod.inventory, deadline),
                };
                self.input = .{};
                return;
            }
            if (self.inventory_cooldown != 0) {
                self.inventory_cooldown -= 1;
            } else if (self.input.inventory and
                self.health > 0 and
                self.equipment.inventory.items().len != 0)
            {
                const items = self.equipment.inventory.items();
                for (items, self.menu_entries[0..items.len]) |handle, *entry| {
                    const item = try self.equipment.item(handle);
                    entry.* = .{
                        .icon = try self.content.frame(item.definition.icon),
                        .label = item.definition.label,
                        .quantity = if (item.definition.show_quantity) @as(
                            u16,
                            @bitCast(item.quantity),
                        ) else null,
                    };
                }
                self.dialog = .{
                    .menu = try inventory_menu.Menu.init(items.len),
                    .clock = try clock_mod.Clock.init(clock_mod.inventory, deadline),
                };
                self.input = .{};
            }
            if (self.pending_movie != null or self.exits.requested != null) return;
        }
    }

    fn deliverCharacterPulses(self: *Scene, pulses: []const props_mod.CircuitId) !void {
        self.quest_contacts.route(self.content.quest_contact_bindings, pulses);
        self.rescue_contacts.route(self.content.rescue_contact_bindings, pulses);
        self.gunmen.route(self.content.gunman_bindings, pulses);
        self.enemy_barriers.route(self.content.enemy_barriers.bindings, pulses);
        self.guards.route(self.content.guard_bindings, pulses);
        self.mission_terminals.route(self.content.mission_terminal_bindings, pulses);
        self.doors.route(self.content.doors.bindings, pulses);
        self.guides.route(self.content.guide_bindings, pulses);
        try self.inventory_grants.deliver(
            self.content.inventory_grants.definitions,
            self.content.inventory_grants.bindings,
            pulses,
            &self.equipment,
        );
    }
    fn advanceCharacters(
        self: *Scene,
        intent: conrad.Intent,
        distraction_count: usize,
        first_guard: usize,
    ) !void {
        const player: contacts.Footprint = .{
            .room = self.environment.room,
            .position = self.pose.position,
            .width = self.content.player_contact_width,
        };
        for (self.content.character_schedule) |task| switch (task) {
            .gunman => |index| {
                const first = self.gunmen.pulse_count;
                try self.gunmen.advanceOne(
                    index,
                    self.content.gunmen.definitions,
                    self.content.gunmen.profiles,
                    self.terrain.map(),
                    player,
                    self.distractions[0..distraction_count],
                    self.combat_targets,
                    &self.visibility,
                    self.content.visibility.gunman_entities,
                    &self.random,
                );
                try self.deliverCharacterPulses(self.gunmen.pulses[first..self.gunmen.pulse_count]);
                const actor = self.gunmen.actors[index];
                if (actor.sound) |sound| try self.emitSound(sound, actor.room);
            },
            .guard => |index| {
                const first = self.guards.pulse_count;
                try self.guards.advanceOne(
                    index,
                    self.content.guards.definitions,
                    self.content.guards.profiles,
                    self.terrain.map(),
                    self.props.player_contact,
                    intent.vertical == .down,
                    self.combat_targets,
                    first_guard,
                    &self.visibility,
                    self.content.visibility.guard_entities,
                    &self.random,
                );
                try self.deliverCharacterPulses(self.guards.pulses[first..self.guards.pulse_count]);
                const actor = self.guards.actors[index];
                if (actor.sound) |sound| if (actor.room) |room| try self.emitSound(sound, room);
            },
            .rescue_contact => |index| {
                const first = self.rescue_contacts.pulse_count;
                try self.rescue_contacts.advanceOne(
                    index,
                    self.content.rescue_contacts.definitions,
                    self.terrain.map(),
                    player,
                    self.controller.operate_requested and self.interaction == .rescue,
                );
                try self.deliverCharacterPulses(self.rescue_contacts.pulses[first..self.rescue_contacts.pulse_count]);
                const actor = self.rescue_contacts.actors[index];
                if (actor.sound) |sound| try self.emitSound(sound, actor.room);
            },
            .quest_contact => |index| {
                const first = self.quest_contacts.pulse_count;
                try self.quest_contacts.advanceOne(
                    index,
                    self.content.quest_contacts.definitions,
                    self.content.quest_contact_bindings,
                    self.terrain.map(),
                    self.environment.room,
                    self.controller.operate_requested and
                        (self.interaction == .quest or self.interaction == .none),
                    &self.equipment,
                    &self.random,
                );
                try self.deliverCharacterPulses(self.quest_contacts.pulses[first..self.quest_contacts.pulse_count]);
                if (self.quest_contacts.instances[index].sound) |sound| try self.emitSound(
                    sound,
                    self.content.quest_contacts.definitions[index].footprint.room,
                );
            },
            .host => |index| {
                const first = self.attentive_contacts.pulse_count;
                try self.attentive_contacts.advanceOne(
                    index,
                    self.content.attentive_contacts.definitions,
                    self.terrain.map(),
                    player,
                    self.props.player_contact,
                    self.controller.operate_requested and self.interaction == .host,
                    &self.random,
                );
                try self.deliverCharacterPulses(self.attentive_contacts.pulses[first..self.attentive_contacts.pulse_count]);
                if (self.attentive_contacts.instances[index].sound) |sound| try self.emitSound(
                    sound,
                    self.content.attentive_contacts.definitions[index].footprint.room,
                );
            },
            // Characters after the shot in authored order react to its hit in this update.
            .player_shot => {
                try self.pistol.advanceWithTargets(
                    self.content.pistolDefinition(),
                    self.controller.shot_requested,
                    self.pose,
                    self.environment.room,
                    self.terrain.view(),
                    self.combat_targets,
                );
                if (self.pistol.hit_requested) |hit| self.deliverHit(hit);
            },
            .service_counter => |index| {
                const first = self.service_counters.pulse_count;
                try self.service_counters.advanceOne(
                    index,
                    self.content.service_counters.definitions,
                    self.terrain.map(),
                    self.environment.room,
                    self.controller.operate_requested and self.interaction == .none,
                    &self.random,
                );
                try self.deliverCharacterPulses(self.service_counters.pulses[first..self.service_counters.pulse_count]);
                if (self.service_counters.instances[index].sound) |sound| try self.emitSound(
                    sound,
                    self.content.service_counters.definitions[index].footprint.room,
                );
            },
        };
        self.score +%= self.gunmen.score_requested;
        self.score +%= self.guards.score_requested;
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
        // Reach-to-use items keep their held command; direct-use items consume one press.
        if (!self.controller.use_reaches) self.input.consumeUse();
        self.movie_intent = intent;
        return true;
    }
    pub fn resumeMovie(self: *Scene, paused_for: u64) !void {
        self.clock.?.origin_ns = try std.math.add(u64, self.clock.?.origin_ns, paused_for);
    }

    pub fn nextDeadline(self: *const Scene) ?u64 {
        if (self.message) |message| return message.clock.deadline();
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
        try self.drawItemAid(room, indices, true);
        try self.drawRobots(room, indices, true);
        try self.drawDoors(room, indices, true);
        try self.drawPlatformSections(room, indices, true);
        try self.drawLifts(room, indices, true);
        try self.drawStationary(
            self.detectors.instances,
            self.content.detectors.definitions,
            room,
            indices,
            true,
        );
        try self.drawStationary(
            self.ceiling_guns.instances,
            self.content.ceiling_guns.definitions,
            room,
            indices,
            true,
        );
        try self.drawShot(room, indices, true);
        try self.drawCasing(room, indices, true);
        try self.drawSurfaces(room, indices, true);
        const frame = try self.content.frame(self.pose.visual.id);
        if (self.protection_steps & 1 == 0) try sprite_renderer.draw(
            indices,
            room.image.width,
            room.image.height,
            frame,
            @as(i32, self.pose.position.x) + 8,
            @as(i32, self.pose.position.y) + 2,
            .{
                .palette_bank = 4,
                .facing = if (self.pose.visual.mirrored) .mirrored else .original,
                .occlusion = room.foreground,
            },
        );
        try self.drawProps(.in_front_of_player, room, indices);
        try self.drawControls(.in_front_of_player, room, indices);
        try self.drawHazards(.in_front_of_player, room, indices);
        try self.drawGunmen(room, indices, false);
        try self.drawItemAid(room, indices, false);
        try self.drawRobots(room, indices, false);
        try self.drawDoors(room, indices, false);
        try self.drawPlatformSections(room, indices, false);
        try self.drawLifts(room, indices, false);
        try self.drawStationary(
            self.detectors.instances,
            self.content.detectors.definitions,
            room,
            indices,
            false,
        );
        try self.drawStationary(
            self.ceiling_guns.instances,
            self.content.ceiling_guns.definitions,
            room,
            indices,
            false,
        );
        try self.drawShot(room, indices, false);
        try self.drawCasing(room, indices, false);
        try self.drawSurfaces(room, indices, false);
        if (try self.equipment.selected()) |selected| {
            const icon = try self.content.frame(selected.definition.icon);
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                icon,
                232,
                8,
                .{ .palette_bank = 10, .foreground = .overwrite },
            );
        }
        if (try self.interactionHint()) |hint| {
            try sprite_renderer.draw(
                indices,
                256,
                224,
                try self.content.frame(hint.icon),
                80,
                8,
                .{ .palette_bank = 10, .foreground = .overwrite },
            );
            try text_renderer.draw(
                indices,
                256,
                224,
                &self.content.inventory_art.font,
                hint.label,
                @divTrunc(176 - @as(i32, @intCast(hint.label.len)) * 8, 2),
                26,
                .{ .foreground = 0xe6, .shadow = 0xe2, .palette_bank = 14 },
            );
        }
        if (self.level_code_steps != 0) {
            const code = std.mem.sliceTo(&self.content.level_code, 0);
            try text_renderer.draw(
                indices,
                256,
                224,
                &self.content.inventory_art.font,
                code,
                128 - @as(i32, @intCast(code.len)) * 4,
                16,
                .{ .foreground = 0xe7, .shadow = 0xe2, .palette_bank = 14 },
            );
        }
        if (self.message) |message| {
            try message.draw(
                try self.content.messages.get(message.request.message),
                &self.content.inventory_art.font,
                room.image.pixels,
                indices,
            );
            try sprite_renderer.draw(
                indices,
                256,
                224,
                try self.content.frame(message.request.icon),
                80,
                8,
                .{ .palette_bank = 10, .foreground = .overwrite },
            );
        } else try self.zoom.draw(indices, rgba);
        const shake = @as(usize, self.environmental_alarms.shake_rows) * room.image.width;
        if (shake != 0) {
            std.mem.copyBackwards(u8, indices[shake..], indices[0 .. indices.len - shake]);
            @memset(indices[0..shake], 0);
        }
        if (self.dialog) |dialog| try dialog.menu.draw(
            self.content.inventory_art.artwork(),
            self.menu_entries[0..dialog.menu.count],
            self.score,
            indices,
            room.image.width,
            room.image.height,
        );
        if (self.options) |options| try options.menu.draw(
            indices,
            &self.content.inventory_art.font,
        );
        var colors = room.colors;
        for (self.guards.actors) |actor| if (actor.room == self.environment.room and
            actor.activity != .removed)
        {
            @memcpy(colors[0x50..0x60], &self.content.guard_colors);
            break;
        };
        try palette.writeRgba(indices, &colors, rgba);
    }

    fn chooseInteraction(self: *Scene) !Interaction {
        const entity = try self.visibility.touching(
            self.terrain.map(),
            self.content.visibility.player_entity,
            .interactive,
        ) orelse return .none;
        const owner = self.content.visibility.bindings[@backingInt(entity)].owner;
        if (owner == .prop) {
            const definition = self.props.definitions[owner.prop];
            if (definition.behavior == .collectible) {
                self.props.pickup_candidate = definition.behavior.collectible.item;
                self.props.pickup_priority = definition.interaction_priority;
            }
            return .none;
        }
        self.props.pickup_candidate = null;
        return switch (owner) {
            .rescue_contact => |index| result: {
                self.rescue_contacts.candidate = index;
                break :result .rescue;
            },
            .ambient_person, .enemy_barrier => .none,
            .escort => |index| result: {
                self.escort_followers.candidate = index;
                break :result .escort;
            },
            .attentive_contact => |index| result: {
                self.attentive_contacts.candidate = index;
                break :result .host;
            },
            .quest_contact => |index| result: {
                self.quest_contacts.candidate = index;
                break :result .quest;
            },
            .item_aid => |index| result: {
                self.item_aid.candidate = index;
                break :result .item_aid;
            },
            .trader => |index| result: {
                self.traders.candidate = index;
                break :result .trader;
            },
            .guide => |index| result: {
                self.guides.candidate = index;
                break :result .guide;
            },
            .station => |index| result: {
                self.story_stations.candidate = index;
                break :result .station;
            },
            else => .none,
        };
    }

    const Hint = struct { icon: motion.VisualId, label: []const u8 };
    fn interactionHint(self: *const Scene) !?Hint {
        if (self.interaction == .station) {
            const definition = self.content.story_stations.definitions[self.story_stations.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.interaction == .guide) {
            const definition = self.content.guides.definitions[self.guides.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.interaction == .trader) {
            const definition = self.content.traders.definitions[self.traders.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.interaction == .item_aid) {
            const definition = self.content.item_aid.definitions[self.item_aid.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.props.pickup_candidate) |handle| return .{
            .icon = self.content.world_props.hint_icon,
            .label = (try self.equipment.item(handle)).definition.label,
        };
        if (self.interaction == .rescue) {
            const definition = self.content.rescue_contacts.definitions[self.rescue_contacts.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.interaction == .escort) {
            const definition = self.content.escort_followers.definitions[self.escort_followers.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.interaction == .host) {
            const definition = self.content.attentive_contacts.definitions[self.attentive_contacts.candidate.?];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.quest_contacts.candidate) |index| {
            const definition = self.content.quest_contacts.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.credential_terminals.candidate) |index| {
            const definition = self.content.credential_terminals.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.mission_terminals.candidate) |index| {
            const definition = self.content.mission_terminals.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.service_counters.candidate) |index| {
            const definition = self.content.service_counters.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.locks.candidate) |index| {
            const definition = self.content.locks.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.operated_controls.candidate) |index| {
            const definition = self.content.controls.definitions[index];
            return .{ .icon = definition.hint, .label = definition.label };
        }
        if (self.energy_stations.candidate) |index| {
            const definition = self.content.energy_stations.definitions[index];
            if (definition.hint) |hint| return .{ .icon = hint, .label = definition.label };
        }
        return null;
    }
    fn drawItemAid(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (
            self.scripted_transport.effects,
            self.content.scripted_transport.effects,
        ) |instance, definition| {
            if (instance.effect_room != self.environment.room or
                definition.behind_player != behind_player) continue;
            const pose = instance.effect_pose;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(pose.visual.id),
                @as(i32, pose.position.x) + 8,
                @as(i32, pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.enemy_barriers.emitters,
            self.content.enemy_barriers.definitions,
        ) |field, definition| {
            if (field.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(field.pose.visual.id),
                @as(i32, field.pose.position.x) + 8,
                @as(i32, field.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (field.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (self.force_fields, self.content.force_fields.definitions) |field, definition| {
            if (field.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(field.pose.visual.id),
                @as(i32, field.pose.position.x) + 8,
                @as(i32, field.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (field.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.escort_followers.actors,
            self.content.escort_followers.definitions,
        ) |actor, definition| {
            if (actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.rescue_contacts.actors,
            self.content.rescue_contacts.definitions,
        ) |actor, definition| {
            if (actor.body(definition) == null or
                actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.ambient_people.actors,
            self.content.ambient_people.definitions,
        ) |actor, definition| {
            if (actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.attentive_contacts.instances,
            self.content.attentive_contacts.definitions,
        ) |instance, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.quest_contacts.instances,
            self.content.quest_contacts.definitions,
        ) |instance, definition| {
            if (instance.stage == .hidden or
                instance.stage == .removed or
                definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.mission_terminals.instances,
            self.content.mission_terminals.definitions,
        ) |instance, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.service_counters.instances,
            self.content.service_counters.definitions,
        ) |instance, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.triggered_effects.instances,
            self.content.triggered_effects.definitions,
        ) |instance, definition| {
            if (instance.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (self.traders.actors, self.content.traders.definitions) |actor, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (
            self.story_stations.instances,
            self.content.story_stations.definitions,
        ) |instance, definition| {
            if ((instance.phase != .ready and instance.phase != .using) or
                definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (self.guides.actors, self.content.guides.definitions) |actor, definition| {
            if (actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (self.item_aid.actors, self.content.item_aid.definitions) |actor, definition| {
            if (actor.phase == .gone or
                actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn syncVisibility(self: *Scene) !void {
        for (self.content.visibility.bindings) |binding| {
            const observation = try self.placementObservation(binding.owner) orelse continue;
            self.visibility.observe(binding.entity, observation);
        }
    }

    /// Current body and activity of one placement's modern owner; null when no component owns it.
    pub fn placementObservation(
        self: *Scene,
        owner: content_visibility.Owner,
    ) !?visibility_mod.Observation {
        return switch (owner) {
            .enemy_barrier => |index| .{
                .body = self.enemy_barriers.emitters[index].body(self.content.enemy_barriers.definitions[index]),
                .active = self.enemy_barriers.emitters[index].active,
            },
            .rescue_contact => |index| .{
                .body = self.rescue_contacts.actors[index].body(self.content.rescue_contacts.definitions[index]),
                .active = self.rescue_contacts.actors[index].active,
            },
            .ambient_person => |index| .{
                .body = .{
                    .room = self.ambient_people.actors[index].room,
                    .position = self.ambient_people.actors[index].pose.position,
                    .width = self.content.ambient_people.definitions[index].width,
                },
                .active = self.ambient_people.actors[index].active,
            },
            .escort => |index| .{
                .body = self.escort_followers.actors[index].contact,
                .active = self.escort_followers.actors[index].active,
            },
            .attentive_contact => |index| .{
                .body = self.content.attentive_contacts.definitions[index].footprint,
                .active = self.attentive_contacts.instances[index].active,
            },
            .quest_contact => |index| .{
                .body = self.quest_contacts.instances[index].body(self.content.quest_contacts.definitions[index]),
                .active = self.quest_contacts.instances[index].active,
            },
            .mission_terminal => |index| .{
                .body = self.content.mission_terminals.definitions[index].footprint,
                .active = self.mission_terminals.instances[index].active,
            },
            .service_counter => |index| .{
                .body = self.content.service_counters.definitions[index].footprint,
                .active = self.service_counters.instances[index].active,
            },
            .force_field => |index| .{
                .body = self.force_fields[index].body(self.content.force_fields.definitions[index]),
                .active = true,
            },
            .player => .{ .body = self.props.player_contact, .active = true },
            .gunman => |index| blk: {
                const actor = self.gunmen.actors[index];
                break :blk .{
                    .body = if (actor.dormant or actor.lost) null else actor.contact,
                    .active = actor.active and !actor.lost and !actor.dormant,
                };
            },
            .guard => |index| blk: {
                const actor = self.guards.actors[index];
                break :blk .{
                    .body = if (actor.room) |room| .{
                        .room = room,
                        .position = actor.pose.position,
                        .width = self.content.guards.definitions[index].contact_width,
                    } else null,
                    .active = actor.active and actor.activity != .removed,
                };
            },
            .prop => |index| blk: {
                const object = self.props.objects[index];
                break :blk .{
                    .body = if (try self.props.visible(
                        index,
                        &self.equipment,
                    )) object.contact else null,
                    .active = object.active,
                };
            },
            .door => |index| .{
                .body = self.content.doors.definitions[index].footprint,
                .active = self.doors.instances[index].active,
            },
            .item_aid => |index| blk: {
                const actor = self.item_aid.actors[index];
                break :blk .{
                    .body = if (actor.phase != .gone) actor.contact else null,
                    .active = actor.active and actor.phase != .gone,
                };
            },
            .trader => |index| .{
                .body = self.traders.actors[index].contact,
                .active = self.traders.actors[index].active,
            },
            .guide => |index| .{
                .body = self.guides.actors[index].contact,
                .active = self.guides.actors[index].active,
            },
            .station => |index| .{
                .body = if (self.story_stations.instances[index].phase == .ready or
                    self.story_stations.instances[index].phase == .using) self.content.story_stations.definitions[index].footprint else null,
                .active = self.story_stations.instances[index].active,
            },
            .unbound => null,
        };
    }

    fn deliverHit(self: *Scene, hit: combat.Hit) void {
        if (@backingInt(hit.target) == 0) {
            if (self.protection_steps == 0 and
                self.environment.room == hit.sender_room) self.controller.pending_hits.set(hit.impact);
        } else if (@backingInt(hit.target) <= self.gunmen.actors.len) {
            const actor = &self.gunmen.actors[@backingInt(hit.target) - 1];
            if (actor.room == hit.sender_room) actor.pending_hits.set(hit.impact);
        } else if (@backingInt(hit.target) < 1 + self.gunmen.actors.len + self.robots.actors.len) {
            const actor = &self.robots.actors[@backingInt(hit.target) - 1 - self.gunmen.actors.len];
            if (actor.room == hit.sender_room) actor.pending_hits.set(hit.impact);
        } else if (@backingInt(hit.target) < 1 + self.gunmen.actors.len + self.robots.actors.len + self.guards.actors.len) {
            const actor = &self.guards.actors[@backingInt(hit.target) - 1 - self.gunmen.actors.len - self.robots.actors.len];
            if (actor.room == hit.sender_room) actor.pending_hits.set(hit.impact);
        } else {
            const index = @backingInt(hit.target) - 1 - self.gunmen.actors.len - self.robots.actors.len - self.guards.actors.len;
            if (index >= self.doors.instances.len) {
                const field_index = index - self.doors.instances.len;
                if (field_index >= self.force_fields.len) {
                    const field = &self.enemy_barriers.emitters[field_index - self.force_fields.len];
                    if (field.room == hit.sender_room) field.hits.set(hit.impact);
                    return;
                }
                const field = &self.force_fields[field_index];
                if (field.room == hit.sender_room) field.hit = true;
                return;
            }
            if (self.content.doors.definitions[index].footprint.room == hit.sender_room) self.doors.hit(
                self.content.doors.definitions,
                index,
            );
        }
    }

    fn drawShot(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        const definition = self.content.pistolDefinition();
        for (
            self.enemy_fire.channels,
            self.content.gunmen.weapons,
        ) |channel, weapon| if (weapon.behind_player == behind_player) {
            if (channel.state.effect) |effect| if (effect.room == self.environment.room) try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(effect.pose.visual.id),
                @as(i32, effect.pose.position.x) + 8,
                @as(i32, effect.pose.position.y) + 2,
                .{
                    .palette_bank = weapon.palette_bank,
                    .facing = if (effect.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        };
        for (
            self.guard_fire.channels,
            self.content.guards.weapons,
        ) |channel, weapon| if (weapon.behind_player == behind_player) {
            if (channel.state.effect) |effect| if (effect.room == self.environment.room) try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(effect.pose.visual.id),
                @as(i32, effect.pose.position.x) + 8,
                @as(i32, effect.pose.position.y) + 2,
                .{
                    .palette_bank = weapon.palette_bank,
                    .facing = if (effect.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        };
        for (
            self.ceiling_fire.channels,
            self.content.ceiling_guns.weapons,
        ) |channel, weapon| if (weapon.behind_player == behind_player) {
            if (channel.state.effect) |effect| if (effect.room == self.environment.room) try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(effect.pose.visual.id),
                @as(i32, effect.pose.position.x) + 8,
                @as(i32, effect.pose.position.y) + 2,
                .{
                    .palette_bank = weapon.palette_bank,
                    .facing = if (effect.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        };
        if (definition.behind_player != behind_player) return;
        if (self.pistol.effect) |effect| if (effect.room == self.environment.room) {
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(effect.pose.visual.id),
                @as(i32, effect.pose.position.x) + 8,
                @as(i32, effect.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (effect.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        };
    }

    fn drawCasing(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        const definition = self.content.casing_definition;
        if (definition.behind_player != behind_player) return;
        if (self.casings.flight) |flight| if (flight.room == self.environment.room) {
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(flight.pose.visual.id),
                @as(i32, flight.pose.position.x) + 8,
                @as(i32, flight.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (flight.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        };
    }

    fn drawSurfaces(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (self.surfaces.instances, self.content.surfaces) |instance, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawProps(
        self: *const Scene,
        layer: props_mod.Layer,
        room: *const room_artwork.Artwork,
        indices: []u8,
    ) !void {
        // Keep content order within each layer, with Conrad drawn between layers.
        for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
            if (definition.layer != layer or
                object.room != self.environment.room or
                !try self.props.visible(
                    index,
                    &self.equipment,
                )) continue;
            const art = try self.content.frame(object.pose.visual.id);
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                art,
                @as(i32, object.pose.position.x) + 8,
                @as(i32, object.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (object.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawControls(
        self: *const Scene,
        layer: props_mod.Layer,
        room: *const room_artwork.Artwork,
        indices: []u8,
    ) !void {
        try self.drawControlSet(
            self.operated_controls.instances,
            self.content.controls.definitions,
            layer,
            room,
            indices,
        );
        try self.drawControlSet(
            self.locks.instances,
            self.content.locks.definitions,
            layer,
            room,
            indices,
        );
        try self.drawControlSet(
            self.energy_stations.instances,
            self.content.energy_stations.definitions,
            layer,
            room,
            indices,
        );
    }

    fn drawControlSet(
        self: *const Scene,
        instances: anytype,
        definitions: anytype,
        layer: props_mod.Layer,
        room: *const room_artwork.Artwork,
        indices: []u8,
    ) !void {
        for (instances, definitions) |instance, definition| {
            if (definition.layer != layer or
                definition.footprint.room != self.environment.room) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawHazards(
        self: *const Scene,
        layer: props_mod.Layer,
        room: *const room_artwork.Artwork,
        indices: []u8,
    ) !void {
        for (self.hazards.instances, self.content.hazards.definitions) |instance, definition| {
            if (definition.layer != layer or
                definition.footprint.room != self.environment.room) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawGunmen(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (self.gunmen.actors, self.content.gunmen.definitions) |actor, definition| {
            if (actor.lost or
                actor.dormant or
                actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = 5,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawRobots(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (self.guards.actors, self.content.guards.definitions) |actor, definition| {
            if (actor.room != self.environment.room or
                actor.activity == .removed or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
        for (self.robots.actors, self.content.robots.definitions) |actor, definition| {
            if (actor.removed or
                actor.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(actor.pose.visual.id),
                @as(i32, actor.pose.position.x) + 8,
                @as(i32, actor.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (actor.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawPlatformSections(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (
            self.platform_sections.instances,
            self.content.platform_sections.definitions,
        ) |instance, definition| {
            if (!instance.present or
                definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawLifts(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (self.lifts.instances, self.content.lifts.definitions) |instance, definition| {
            if (instance.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawDoors(
        self: *const Scene,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (self.doors.instances, self.content.doors.definitions) |instance, definition| {
            if (definition.footprint.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    fn drawStationary(
        self: *const Scene,
        instances: anytype,
        definitions: anytype,
        room: *const room_artwork.Artwork,
        indices: []u8,
        behind_player: bool,
    ) !void {
        for (instances, definitions) |instance, definition| {
            if (definition.room != self.environment.room or
                definition.behind_player != behind_player) continue;
            try sprite_renderer.draw(
                indices,
                room.image.width,
                room.image.height,
                try self.content.frame(instance.pose.visual.id),
                @as(i32, instance.pose.position.x) + 8,
                @as(i32, instance.pose.position.y) + 2,
                .{
                    .palette_bank = definition.palette_bank,
                    .facing = if (instance.pose.visual.mirrored) .mirrored else .original,
                    .occlusion = room.foreground,
                },
            );
        }
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, self.health)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.death_wait orelse 0)));
        hash.update(&.{
            @intFromBool(self.defeated),
            @intFromBool(self.aborted),
            self.settings.volume,
            @intFromBool(self.settings.sound_fx),
            @intFromBool(self.settings.music),
            @intFromBool(self.settings.joystick),
            @backingInt(self.settings.zoom),
            @intFromBool(self.options != null),
        });
        if (self.options) |options| hash.update(&.{
            @backingInt(options.menu.selection),
            options.menu.settings.volume,
            @intFromBool(options.menu.settings.sound_fx),
            @intFromBool(options.menu.settings.music),
            @intFromBool(options.menu.settings.joystick),
            @backingInt(options.menu.settings.zoom),
        });
        self.equipment.hashInto(&hash);
        for (self.force_fields) |field| field.hashInto(&hash);
        self.terrain.hashInto(&hash);
        self.pistol.hashInto(&hash);
        self.enemy_fire.hashInto(&hash);
        const hits = self.controller.pending_hits;
        hash.update(&.{
            self.protection_steps,
            @intFromBool(self.controller.protection_pending),
            @intFromBool(hits.rear_high),
            @intFromBool(hits.rear_low),
            @intFromBool(hits.front_high),
            @intFromBool(hits.front_low),
        });
        self.casings.hashInto(&hash);
        self.surfaces.hashInto(&hash);
        for ([_]u32{
            if (self.ambience.call) |call| @intCast(call + 1) else 0,
            self.ambience.elapsed,
            if (self.ambience.room) |room| @backingInt(room) else 0,
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.random.state)));
        self.props.hashInto(&hash);
        self.operated_controls.hashInto(&hash);
        self.locks.hashInto(&hash);
        self.service_counters.hashInto(&hash);
        self.mission_terminals.hashInto(&hash);
        self.quest_contacts.hashInto(&hash);
        self.attentive_contacts.hashInto(&hash);
        self.ambient_people.hashInto(&hash);
        self.rescue_contacts.hashInto(&hash);
        self.enemy_barriers.hashInto(&hash);
        self.escort_followers.hashInto(&hash);
        self.arrival_triggers.hashInto(&hash);
        self.scripted_transport.hashInto(&hash);
        self.timed_items.hashInto(&hash);
        self.environmental_alarms.hashInto(&hash);
        self.credential_terminals.hashInto(&hash);
        self.platform_sections.hashInto(&hash);
        self.item_aid.hashInto(&hash);
        self.guides.hashInto(&hash);
        self.story_stations.hashInto(&hash);
        self.traders.hashInto(&hash);
        self.guards.hashInto(&hash);
        self.visibility.hashInto(&hash);
        self.guard_fire.hashInto(&hash);
        self.barriers.hashInto(&hash);
        self.inventory_grants.hashInto(&hash);
        self.exits.hashInto(&hash);
        self.triggered_effects.hashInto(&hash);

        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.level_code_steps)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, @backingInt(self.message_icon))));
        hash.update(&.{@intCast(@backingInt(self.interaction))});
        hash.update(&.{@intFromBool(self.message != null)});
        if (self.message) |message| message.hashInto(&hash);
        self.energy_stations.hashInto(&hash);
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
        if (self.replay) |replay| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(
            u64,
            replay.cursor,
        )));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.score)));
        hash.update(&.{
            self.inventory_cooldown,
            @intFromBool(self.input.inventory),
            @intFromBool(self.input.use_item),
            @intFromBool(self.input.use_held),
            @intFromBool(self.input.use_blocked),
            @intFromBool(self.dialog != null),
        });
        if (self.dialog) |dialog| {
            for ([_]u64{
                dialog.menu.cursor,
                dialog.menu.last_displayed,
                dialog.clock.next_tick,
                dialog.clock.origin_ns - self.clock.?.origin_ns,
            }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            hash.update(&.{
                @intFromBool(dialog.menu.score_next),
                @intFromBool(dialog.menu.view == .score),
            });
            if (dialog.menu.view == .items) hash.update(&std.mem.toBytes(std.mem.nativeToLittle(
                u64,
                dialog.menu.view.items,
            )));
            const keys = dialog.keys;
            for ([_]bool{
                keys.directions.right,
                keys.directions.left,
                keys.directions.up,
                keys.directions.down,
                keys.previous.right,
                keys.previous.left,
                keys.previous.up,
                keys.previous.down,
                keys.left_shift,
                keys.right_shift,
                keys.space,
                keys.enter,
                keys.tab,
            }) |value| hash.update(&.{@intFromBool(value)});
        }
        hash.update(&.{
            @intFromBool(self.input.weapon),
            @intFromBool(self.weapon_toggle.desired),
            @backingInt(self.weapon_toggle.phase),
            @intFromBool(self.controller.weapon_desired),
        });
        for ([_]u32{
            @intFromBool(self.zoom.active),
            @as(u16, @bitCast(self.zoom.origin.x)),
            @as(u16, @bitCast(self.zoom.origin.y)),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
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
            .falling => |fall| @as(u32, @backingInt(fall.phase)) | (@as(
                u32,
                @intFromBool(fall.already_dead),
            ) << 8),
            .ledge => |state| @backingInt(state.phase),
            .operating => |state| @backingInt(state),
            .transporting => |state| @backingInt(state),
            .dead => |phase| @backingInt(phase),
            .recoiling => |state| (@as(
                u32,
                @backingInt(std.meta.activeTag(state.phase)),
            ) << 8) | switch (state.phase) {
                .settling, .resting => |landing| @as(u32, @backingInt(landing)),
                else => @as(u32, 0),
            },
            else => 0,
        };
        for ([_]u32{
            @backingInt(self.environment.room),
            @as(u16, @bitCast(self.pose.position.x)),
            @as(u16, @bitCast(self.pose.position.y)),
            @backingInt(self.pose.facing),
            @backingInt(self.pose.visual.id),
            @intFromBool(self.pose.visual.mirrored),
            activity,
            phase,
            @intCast(self.controller.playback.next_step),
        }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        for ([_]u64{
            self.simulation_steps,
            if (self.clock) |clock| clock.next_tick else 0,
        }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        const held = [_]u8{
            @intFromBool(self.input.left),
            @intFromBool(self.input.right),
            @intFromBool(self.input.up),
            @intFromBool(self.input.down),
            @intFromBool(self.input.left_action),
            @intFromBool(self.input.right_action),
            if (self.input.previous_direction.horizontal) |direction| 1 + @as(
                u8,
                @backingInt(direction),
            ) else 0,
            if (self.input.previous_direction.vertical) |direction| 1 + @as(
                u8,
                @backingInt(direction),
            ) else 0,
            @intFromBool(self.input.previous_direction.conflict),
        };
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
