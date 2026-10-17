//! The original rule operation codes and their vocabulary names. This is the only place where
//! original code numbers appear; everything the extractor writes uses the names. Meanings and
//! quirks are recorded in flashback-re `docs/rule-vocabulary.md`.
const std = @import("std");

/// How an operation's argument is written in a behavior table.
pub const Argument = union(enum) {
    /// The original ignores the argument.
    none,
    /// A plain number: cells, steps, a scene, sound, text or object id.
    number,
    /// A column offset the original counts backward: written negated, as cells ahead like the
    /// other terrain checks' arguments.
    cells_behind,
    /// A message value, written by name.
    message,
    /// Send a message to the link stored in the given placement parameter.
    send_to_link: u2,
    /// The argument selects a placement parameter that holds a number.
    parameter_number,
    /// The argument selects a placement parameter holding a link; the next one holds an amount.
    parameter_link_and_amount,
    /// The argument selects two consecutive placement parameters holding links, named here.
    parameter_link_pair: [2][]const u8,
    /// A placement index: another character of the level.
    character,
    /// A character kind.
    kind,
    /// Shift, Enter or Space.
    button,
    /// Which side a hit comes from.
    hit_side,
    /// Standing or crouched.
    height,
    /// 0 or 1, written as false or true.
    flag,
    /// A second condition that also reads the first condition's argument as a kind. The
    /// payload names its own argument.
    kind_and: []const u8,
};

pub const Operation = struct {
    name: []const u8,
    argument: Argument,
    /// A placement number the original reads besides the argument, if any.
    implicit: ?Implicit = null,
};

/// The table writes such operations as `.{ .name = .{ .main_field = argument, .field = number } }`,
/// or, when the argument already has fields, adds the number as one more field.
pub const Implicit = struct {
    parameter: u2,
    /// Null when the argument writes its own fields.
    main_field: ?[]const u8 = null,
    field: []const u8,
    /// Name for the number when the overlay gives none.
    default_name: []const u8,
};

pub fn lookup(code: u8) ?Operation {
    return switch (code) {
        // Input. Every character reads Conrad's controls.
        1 => op("input_up", .none),
        2 => op("input_back", .none),
        3 => op("input_down", .none),
        4 => op("input_forward", .none),
        5 => op("input_up_and", .button),
        6 => op("input_back_and", .button),
        7 => op("input_down_and", .button),
        8 => op("input_forward_and", .button),
        9 => op("input_none", .none),
        10 => op("input_button", .button),
        52 => op("use_over_gap", .number),
        53 => op("input_buttons_only", .button),
        // Terrain around the character; "ahead" follows its facing.
        11 => op("ceiling_ahead", .number),
        12 => op("ceiling_here", .none),
        13 => op("ceiling_behind", .number),
        14 => op("wall_ahead", .number),
        15 => op("wall_here", .none),
        16 => op("wall_behind", .number),
        17 => op("floor_ahead", .number),
        18 => op("floor_here", .none),
        19 => op("floor_behind", .number),
        20 => op("no_ceiling_ahead", .number),
        21 => op("no_ceiling_here", .none),
        22 => op("no_ceiling_behind", .number),
        23 => op("no_wall_ahead", .number),
        24 => op("no_wall_here", .none),
        25 => op("no_wall_behind", .number),
        26 => op("no_floor_ahead", .number),
        27 => op("no_floor_here", .none),
        28 => op("no_floor_behind", .number),
        29 => op("ledge_above_behind", .cells_behind),
        30 => op("floor_edge_behind", .cells_behind),
        31 => op("ledge_above_ahead", .cells_behind),
        32 => op("floor_edge_ahead", .cells_behind),
        33 => op("grab_edge_ahead", .cells_behind),
        40 => op("wall_beyond_gap", .cells_behind),
        41 => op("wall_starts", .cells_behind),
        42 => op("wall_ends", .cells_behind),
        103 => op("low_passage_ahead", .number),
        116 => op("floor_below_ahead", .number),
        122 => op("step_clear_ahead", .number),
        136 => op("snap_to_grid", .none),
        // Changing terrain.
        54 => op("make_solid", .number),
        55 => op("make_empty", .number),
        104 => op("make_low_passage", .number),
        114 => op("restore_terrain", .number),
        // Messages.
        34 => op("received", .message),
        35 => op("send", .{ .send_to_link = 0 }),
        36 => op("send", .{ .send_to_link = 1 }),
        37 => op("send", .{ .send_to_link = 2 }),
        38 => op("send", .{ .send_to_link = 3 }),
        47 => op("send_to_touching_object", .message),
        51 => op("send_to_selected_item", .message),
        70 => op("send_to_touching_facing_opposite", .message),
        71 => op("send_to_touching_facing_same", .message),
        72 => withNumber("send_to_matching_device", .message, .{
            .parameter = 0,
            .main_field = "message",
            .field = "kind",
            .default_name = "device_kind",
        }),
        111 => op("acknowledge", .message),
        124 => op("send_to_touching_device", .message),
        126 => op("broadcast", .message),
        // Timers and health.
        62 => op("set_timer", .number),
        63 => op("timer_reaches", .number),
        68 => op("set_timer_from", .parameter_number),
        39 => op("defeated", .none),
        85 => op("set_charge", .number),
        86 => op("add_charge", .number),
        88 => withNumber("copy_health_to", .character, .{
            .parameter = 0,
            .main_field = "character",
            .field = "health",
            .default_name = "health_to_copy",
        }),
        89 => op("mirror_health", .character),
        101 => op("credit", .parameter_link_and_amount),
        102 => op("debit", .parameter_link_and_amount),
        // Presence and activity.
        67 => op("sleep_unless_near_player", .none),
        74 => op("use_up", .character),
        75 => op("remove", .none),
        76 => op("in_view", .none),
        77 => op("out_of_view", .none),
        87 => op("reveal", .parameter_number),
        96 => op("appear_at_sender", .message),
        105 => op("checkpoint", .none),
        // Perception and contact.
        43 => op("touching_facing_opposite", .kind),
        44 => op("touching_facing_same", .kind),
        60 => op("touching_kind_in_pose", .{ .kind_and = "pose" }),
        61 => op("touching_in_pose", .number),
        64 => op("sees", .{ .kind_and = "cells" }),
        69 => op("touching_anyone", .none),
        80 => op("touching", .kind),
        84 => op("player_touching", .kind),
        98 => withNumber("facing_target_unhittable", .{ .kind_and = "hit" }, .{
            .parameter = 0,
            .field = "range",
            .default_name = "shot_range",
        }),
        99 => withNumber("backturned_target_unhittable", .{ .kind_and = "hit" }, .{
            .parameter = 0,
            .field = "range",
            .default_name = "shot_range",
        }),
        106 => op("enemy_in_line", .number),
        118 => op("player_above", .none),
        119 => op("player_below", .none),
        120 => op("player_ahead", .number),
        121 => op("player_behind", .number),
        // Chance: one random draw, true when the value is divisible by the argument.
        97 => op("chance", .number),
        // Combat.
        100 => withNumber("shoot", .height, .{
            .parameter = 0,
            .main_field = "height",
            .field = "range",
            .default_name = "shot_range",
        }),
        107 => op("hit", .hit_side),
        134 => withNumber("strike", .height, .{
            .parameter = 3,
            .main_field = "height",
            .field = "range",
            .default_name = "strike_range",
        }),
        95 => withNumber("snap_to_wall_ahead", .flag, .{
            .parameter = 0,
            .main_field = "through_low_gaps",
            .field = "range",
            .default_name = "range",
        }),
        79 => op("start_defeat", .number),
        92 => withNumber("start_defeat_with_scene", .number, .{
            .parameter = 3,
            .main_field = "scene",
            .field = "delay",
            .default_name = "defeat_delay",
        }),
        // Inventory and items.
        48 => op("carried_by", .character),
        49 => op("drop_at", .character),
        50 => op("selected_item_is", .number),
        108 => withNumber("offer_payment", .message, .{
            .parameter = 0,
            .main_field = "message",
            .field = "seller",
            .default_name = "seller_kind",
        }),
        109 => op("touching_pickup", .number),
        131 => op("player_has_item", .number),
        // Lifts and carriers.
        78 => op("move_with_riders", .number),
        110 => op("board_sender", .message),
        113 => op("release_on", .message),
        115 => op("board_touching", .kind),
        127 => op("no_loose_cargo", .none),
        128 => op("align_with_carrier", .none),
        129 => op("follow_carrier_x", .none),
        // World and presentation.
        90 => op("play_scene", .number),
        123 => op("show_message", .number),
        125 => op("play_sound", .number),
        135 => op("play_sound_from", .parameter_number),
        130 => op("transport", .{ .parameter_link_pair = .{ "move", "to" } }),
        132 => op("exit_level", .number),
        133 => op("shake_screen", .none),
        138 => op("set_weapon_mode", .number),
        139 => op("weapon_mode_is", .number),
        else => null,
    };
}

fn op(name: []const u8, argument: Argument) Operation {
    return .{ .name = name, .argument = argument };
}

fn withNumber(name: []const u8, argument: Argument, number: Implicit) Operation {
    return .{ .name = name, .argument = argument, .implicit = number };
}

/// Messages the engine itself generates or interprets; the overlay names the rest.
pub fn engineMessage(value: i16) ?[]const u8 {
    return switch (value) {
        1 => "hit_behind_high",
        2 => "hit_behind_low",
        3 => "hit_front_high",
        4 => "hit_front_low",
        12 => "acknowledged",
        else => null,
    };
}

pub fn kindName(buffer: []u8, kind: i16) []const u8 {
    return switch (kind) {
        -1 => "any",
        1 => "player",
        3 => "interactive",
        10 => "enemy",
        11 => "overlay",
        else => std.fmt.bufPrint(buffer, "kind_{d}", .{ kind }) catch unreachable,
    };
}

test "every operation the floppy levels use has a name" {
    // From flashback-re data/rule-survey.json: the 121 codes used by placed rule groups.
    const used = [_]u8{
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
        31,
        32,
        33,
        34,
        35,
        36,
        37,
        38,
        39,
        40,
        41,
        42,
        43,
        44,
        47,
        48,
        49,
        50,
        51,
        52,
        53,
        54,
        55,
        60,
        61,
        62,
        63,
        64,
        67,
        68,
        69,
        70,
        71,
        72,
        74,
        75,
        76,
        77,
        78,
        79,
        80,
        84,
        85,
        86,
        87,
        88,
        89,
        90,
        92,
        95,
        96,
        97,
        98,
        99,
        100,
        101,
        102,
        103,
        104,
        105,
        106,
        107,
        108,
        109,
        110,
        111,
        113,
        114,
        115,
        116,
        118,
        119,
        120,
        121,
        122,
        123,
        124,
        125,
        126,
        127,
        128,
        129,
        130,
        131,
        132,
        133,
        134,
        135,
        136,
        138,
        139,
    };
    for (used) |code| {
        try std.testing.expect(lookup(code) != null);
    }
}

test "every code in the vocabulary has a distinct name except the four link sends" {
    var seen: std.StringHashMapUnmanaged(u8) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (0..256) |code| {
        const operation = lookup(@intCast(code)) orelse continue;
        const entry = try seen.getOrPut(std.testing.allocator, operation.name);
        if (entry.found_existing) {
            try std.testing.expectEqualStrings("send", operation.name);
        } else {
            entry.value_ptr.* = @intCast(code);
        }
    }
    try std.testing.expectEqual(@as(?Operation, null), lookup(0));
    try std.testing.expectEqual(@as(?Operation, null), lookup(137));
}
