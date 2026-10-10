//! The conditions and effects behavior tables are written in. Each has one implementation in
//! the engine. Field names are the names used in the data set; payload types say how each
//! argument is read. Meanings: flashback-re `docs/rule-vocabulary.md`.
const std = @import("std");

/// A message, interned per level. The engine fixes the meaning of a few (see `Message.fixed`).
pub const Message = enum(u16) {
    hit_behind_high = 1,
    hit_behind_low = 2,
    hit_front_high = 3,
    hit_front_low = 4,
    acknowledged = 12,
    _,

    /// Names the engine itself generates or interprets.
    pub const fixed = [_]Message{
        .hit_behind_high,
        .hit_behind_low,
        .hit_front_high,
        .hit_front_low,
        .acknowledged,
    };

    pub fn isHit(self: Message) bool {
        return @backingInt(self) >= 1 and @backingInt(self) <= 4;
    }
};

/// One of the behavior's links, by its position in the behavior's `links` list.
pub const Link = enum(u2) { _ };
/// One of the behavior's numbers, by its position in the behavior's `numbers` list.
pub const Number = enum(u2) { _ };
/// A character of the level, by placement order.
pub const Character = enum(u16) { _ };
/// A character kind. The engine also tells apart kinds the data set leaves unnamed: 5 and 9,
/// which a touch prefers after `interactive` (`send_to_touching_device`), and 12, which shots
/// hit as they hit the player and enemies.
pub const Kind = enum(i16) {
    any = -1,
    player = 1,
    interactive = 3,
    enemy = 10,
    /// Its composed art draws over the room's foreground (flashback-re engine-presentation 4).
    overlay = 11,
    _,

    /// Whether the kinds match as the original compares them: by their low byte.
    pub fn matches(self: Kind, other: Kind) bool {
        return lowByte(@backingInt(self)) == lowByte(@backingInt(other));
    }
};

/// The low byte of a value, which the original compares where it reads a byte.
pub fn lowByte(value: i16) u8 {
    return @truncate(@as(u16, @bitCast(value)));
}
pub const Button = enum { shift, enter, space };
pub const HitSide = enum {
    from_behind,
    from_front,
    from_front_unannounced,

    /// Whether a rule's `hit` check on this side waits for `message`, at either height. The
    /// unannounced front hit waits for none.
    pub fn awaits(side: HitSide, message: Message) bool {
        return switch (side) {
            .from_behind => message == .hit_behind_high or message == .hit_behind_low,
            .from_front => message == .hit_front_high or message == .hit_front_low,
            .from_front_unannounced => false,
        };
    }
};
pub const Height = enum { standing, crouched };

pub const Operation = union(enum) {
    // Input. Every character reads Conrad's controls.
    input_up,
    input_back,
    input_down,
    input_forward,
    input_up_and: Button,
    input_back_and: Button,
    input_down_and: Button,
    input_forward_and: Button,
    input_none,
    input_button: Button,
    /// Shift held (any direction, no other button) and no floor that many cells ahead.
    shift_over_gap: i16,
    input_buttons_only: Button,
    // Terrain around the character; "ahead" follows its facing.
    ceiling_ahead: i16,
    ceiling_here,
    ceiling_behind: i16,
    wall_ahead: i16,
    wall_here,
    wall_behind: i16,
    floor_ahead: i16,
    floor_here,
    floor_behind: i16,
    no_ceiling_ahead: i16,
    no_ceiling_here,
    no_ceiling_behind: i16,
    no_wall_ahead: i16,
    no_wall_here,
    no_wall_behind: i16,
    no_floor_ahead: i16,
    no_floor_here,
    no_floor_behind: i16,
    ledge_above_behind: i16,
    floor_edge_behind: i16,
    ledge_above_ahead: i16,
    floor_edge_ahead: i16,
    grab_edge_ahead: i16,
    wall_beyond_gap: i16,
    wall_starts: i16,
    wall_ends: i16,
    low_passage_ahead: i16,
    floor_below_ahead: i16,
    step_clear_ahead: i16,
    snap_to_grid,
    // Changing terrain.
    make_solid: i16,
    make_empty: i16,
    make_low_passage: i16,
    restore_terrain: i16,
    // Messages.
    received: Message,
    send: struct { to: Link, message: Message },
    send_to_touching_object: Message,
    send_to_selected_item: Message,
    send_to_touching_facing_opposite: Message,
    send_to_touching_facing_same: Message,
    send_to_matching_device: struct { message: Message, kind: Number },
    acknowledge: Message,
    send_to_touching_device: Message,
    broadcast: Message,
    // Timers and health.
    set_timer: i16,
    timer_reaches: i16,
    set_timer_from: Number,
    defeated,
    set_charge: i16,
    add_charge: i16,
    copy_health_to: struct { character: Character, health: Number },
    mirror_health: Character,
    credit: struct { purse: Link, amount: Number },
    debit: struct { purse: Link, amount: Number },
    // Presence and activity.
    sleep_unless_near_player,
    use_up: Character,
    remove,
    in_view,
    out_of_view,
    reveal: Number,
    appear_at_sender: Message,
    checkpoint,
    // Perception and contact.
    touching_facing_opposite: Kind,
    touching_facing_same: Kind,
    touching_kind_in_pose: struct { kind: Kind, pose: i16 },
    touching_in_pose: i16,
    sees: struct { kind: Kind, cells: i16 },
    touching_anyone,
    touching: Kind,
    player_touching: Kind,
    facing_target_unhittable: struct { kind: Kind, hit: Message, range: Number },
    backturned_target_unhittable: struct { kind: Kind, hit: Message, range: Number },
    enemy_in_line: i16,
    player_above,
    player_below,
    player_ahead: i16,
    player_behind: i16,
    // Chance: one random draw, true when the value is divisible by the argument.
    chance: i16,
    // Combat.
    shoot: struct { height: Height, range: Number },
    hit: HitSide,
    strike: struct { height: Height, range: Number },
    snap_to_wall_ahead: struct { through_low_gaps: bool, range: Number },
    start_defeat: i16,
    start_defeat_with_scene: struct { scene: i16, delay: Number },
    // Inventory and items.
    carried_by: Character,
    drop_at: Character,
    selected_item_is: i16,
    offer_payment: struct { message: Message, seller: Number },
    touching_pickup: i16,
    player_has_item: i16,
    // Lifts and carriers.
    move_with_riders: i16,
    board_sender: Message,
    release_on: Message,
    board_touching: Kind,
    no_loose_cargo,
    align_with_carrier,
    follow_carrier_x,
    // World and presentation.
    play_scene: i16,
    show_message: i16,
    play_sound: i16,
    play_sound_from: Number,
    transport: struct { move: Link, to: Link },
    exit_level: i16,
    shake_screen,
    set_weapon_mode: i16,
    weapon_mode_is: i16,
};

/// A transition of a state: checks in order, at most one effect, changes and a target.
pub const Rule = struct {
    when: []const Operation = &.{},
    then: ?Operation = null,
    turn: bool = false,
    damage: bool = false,
    heal: bool = false,
    kill: bool = false,
    score: u16 = 0,
    /// Toward the character's facing.
    forward: i16 = 0,
    down: i16 = 0,
    /// Index of the target state; the rule's own state when it does not change state.
    next: u16,
};

pub const State = struct { name: []const u8, animation: u16, rules: []const Rule };

pub const Behavior = struct {
    name: []const u8,
    links: []const []const u8,
    numbers: []const []const u8,
    states: []const State,

    pub fn stateIndex(self: Behavior, name: []const u8) ?u16 {
        for (self.states, 0..) |state, index| {
            if (std.mem.eql(u8, state.name, name)) return @intCast(index);
        }
        return null;
    }
};

test "a hit check waits for the hits from its side, at both heights" {
    try std.testing.expect(HitSide.from_behind.awaits(.hit_behind_low));
    try std.testing.expect(!HitSide.from_behind.awaits(.hit_front_high));
    try std.testing.expect(HitSide.from_front.awaits(.hit_front_low));
    for ([_]Message{ .hit_front_high, .hit_behind_high }) |message| {
        try std.testing.expect(!HitSide.from_front_unannounced.awaits(message));
    }
}
