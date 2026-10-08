//! Import diagnostics only: records which gameplay systems accepted each source placement.
//! A registration establishes runtime support, not complete behavioral qualification.
const std = @import("std");
pub const System = enum(u6) {
    player,
    starting_equipment,
    world_props,
    operated_controls,
    key_locks,
    energy_stations,
    electrical_hazards,
    detectors,
    ceiling_guns,
    doors,
    lifts,
    platform_sections,
    gunmen,
    ground_robots,
    mobile_guards,
    rescued_guides,
    story_stations,
    traders,
    inventory_grants,
    event_barriers,
    force_fields,
    level_exits,
    triggered_effects,
    item_aid,
    weapon_effects,
    casings,
    ambience,
    surface_reactions,
    service_counters,
    credential_use,
    mission_terminals,
    quest_contacts,
    attentive_contacts,
    escort_followers,
    arrival_triggers,
    scripted_transport,
    transport_templates,
    timed_items,
    credential_terminals,
    environmental_alarms,
};
pub const Ledger = struct {
    entries: [256]u64 = @splat(0),
    pub fn record(self: *Ledger, index: u16, system: System) void {
        std.debug.assert(index < self.entries.len);
        self.entries[index] |= @as(u64, 1) << @backingInt(system);
    }
    pub fn contains(self: Ledger, index: u16, system: System) bool {
        return self.entries[index] & (@as(u64, 1) << @backingInt(system)) != 0;
    }
};
