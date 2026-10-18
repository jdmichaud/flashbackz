# Rule groups (`LEVELn.OBJ`)

A rule file holds the rule groups of one level. A rule group is the behavior of a character. For
each state, it has a list of rules with conditions, an effect, a movement and a target state. The
extractor converts each rule group that a placement uses into a behavior table of the data set
([behaviors.md](behaviors.md)).

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.OBJ`, `LEVEL2.OBJ`, `LEVEL3.OBJ`, `LEVEL4_1.OBJ`, `LEVEL4_2.OBJ`, `LEVEL5_1.OBJ` and `LEVEL5_2.OBJ`: one file for each level. |
| Byte order | Little-endian. |
| Reader | `rule_table.group` in `src/extract/rule_table.zig`. `level.extract` in `src/extract/level.zig` uses the rules, `src/extract/codes.zig` names the operation codes, and `src/extract/key.zig` calculates a key for each group. The game does not read the file: it runs the behavior tables of the data set. |
| Writer | None: the files come from the original game. |

## Layout

### Directory

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | `count`: the number of rule groups, at most 256. |
| 2 | 4 × `count` | `u32[count]` | The offset of each group, from byte 2 of the file. |

Group `g` starts at file offset `2 + offset[g]`. Two or more entries can give the same offset. In
the original files, the groups follow the directory and each other with no gap.

### Rule group

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The number of rules. |
| 2 | 18 × rules | rule records | The rules. The index of a rule starts at 0 in each group. |

### Rule

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The source state. |
| 2 | 1 | `i8` | `dx`: the movement toward the back of the character, in pixels. |
| 3 | 1 | `i8` | `dy`: the movement down, in pixels. |
| 4 | 2 | `u16` | The target state. |
| 6 | 1 | `u8` | The code of the second condition. The code 0 tells that there is no condition. |
| 7 | 1 | `u8` | The code of the first condition. The code 0 tells that there is no condition. |
| 8 | 1 | `u8` | The flags (see below). |
| 9 | 1 | `u8` | The code of the effect. The code 0 tells that there is no effect. |
| 10 | 2 | `u16` | `next`: the index of the first rule of the target state in the group. |
| 12 | 2 | `i16` | The argument of the first condition. |
| 14 | 2 | `i16` | The argument of the second condition. |
| 16 | 2 | `i16` | The argument of the effect. |

The two condition codes are in the opposite order of their arguments.

### Flags (byte 8)

| Bit | Mask | Description | Table field |
| --- | --- | --- | --- |
| 0 | 0x01 | Turn the character around. | `turn` |
| 1 | 0x02 | Remove one point of health. An enemy also gives 100 points. | `damage` |
| 2 | 0x04 | Add one point of health. | `heal` |
| 3 | 0x08 | Set the health to -1. | `kill` |
| 4 to 7 | 0xf0 | A score award: an index in the table of 16 score awards of the executable ([executable.md](executable.md)). The index 0 gives no award. | `score` |

### States and rules

- A state number is also the number of the animation of the state
  ([animations.md](animations.md)).
- The rules of a state are the consecutive rules whose source is the state, from the first such
  rule in the group. Other rules with that source cannot fire.
- When the animation of a character ends, the engine tries the rules of its state in order. A
  rule fires when its first condition and then its second condition hold. A missing condition
  holds.
- When a rule fires, the effect runs. Then the character enters the target state, and the flags
  and the movement apply.
- The extractor writes `dx` negated, as `forward`, and `dy` as `down`.

## Operations

A condition or an effect is an operation: a code and an argument of type `i16`. The table gives
each code that the extractor knows. "Also reads" gives a placement parameter that the original
reads in addition to the argument ([placements.md](placements.md)). The extractor writes it as one
more field of the operation, with the name of the parameter.

A hit is the message that a shot (`shoot`) or a blow (`strike`) sends to the character that it
reaches. The message gives the side and the height of the hit: 1 `hit_behind_high`,
2 `hit_behind_low`, 3 `hit_front_high` and 4 `hit_front_low`.

| Code | Hex | Name | Area | Argument | Also reads |
| --- | --- | --- | --- | --- | --- |
| 1 | 0x01 | `input_up` | Input | None | |
| 2 | 0x02 | `input_back` | Input | None | |
| 3 | 0x03 | `input_down` | Input | None | |
| 4 | 0x04 | `input_forward` | Input | None | |
| 5 | 0x05 | `input_up_and` | Input | Button | |
| 6 | 0x06 | `input_back_and` | Input | Button | |
| 7 | 0x07 | `input_down_and` | Input | Button | |
| 8 | 0x08 | `input_forward_and` | Input | Button | |
| 9 | 0x09 | `input_none` | Input | None | |
| 10 | 0x0a | `input_button` | Input | Button | |
| 11 | 0x0b | `ceiling_ahead` | Terrain | Number | |
| 12 | 0x0c | `ceiling_here` | Terrain | None | |
| 13 | 0x0d | `ceiling_behind` | Terrain | Number | |
| 14 | 0x0e | `wall_ahead` | Terrain | Number | |
| 15 | 0x0f | `wall_here` | Terrain | None | |
| 16 | 0x10 | `wall_behind` | Terrain | Number | |
| 17 | 0x11 | `floor_ahead` | Terrain | Number | |
| 18 | 0x12 | `floor_here` | Terrain | None | |
| 19 | 0x13 | `floor_behind` | Terrain | Number | |
| 20 | 0x14 | `no_ceiling_ahead` | Terrain | Number | |
| 21 | 0x15 | `no_ceiling_here` | Terrain | None | |
| 22 | 0x16 | `no_ceiling_behind` | Terrain | Number | |
| 23 | 0x17 | `no_wall_ahead` | Terrain | Number | |
| 24 | 0x18 | `no_wall_here` | Terrain | None | |
| 25 | 0x19 | `no_wall_behind` | Terrain | Number | |
| 26 | 0x1a | `no_floor_ahead` | Terrain | Number | |
| 27 | 0x1b | `no_floor_here` | Terrain | None | |
| 28 | 0x1c | `no_floor_behind` | Terrain | Number | |
| 29 | 0x1d | `ledge_above_behind` | Terrain | Cells behind | |
| 30 | 0x1e | `floor_edge_behind` | Terrain | Cells behind | |
| 31 | 0x1f | `ledge_above_ahead` | Terrain | Cells behind | |
| 32 | 0x20 | `floor_edge_ahead` | Terrain | Cells behind | |
| 33 | 0x21 | `grab_edge_ahead` | Terrain | Cells behind | |
| 34 | 0x22 | `received` | Messages | Message | |
| 35 | 0x23 | `send` | Messages | Link 0 and message | |
| 36 | 0x24 | `send` | Messages | Link 1 and message | |
| 37 | 0x25 | `send` | Messages | Link 2 and message | |
| 38 | 0x26 | `send` | Messages | Link 3 and message | |
| 39 | 0x27 | `defeated` | Timers and health | None | |
| 40 | 0x28 | `wall_beyond_gap` | Terrain | Cells behind | |
| 41 | 0x29 | `wall_starts` | Terrain | Cells behind | |
| 42 | 0x2a | `wall_ends` | Terrain | Cells behind | |
| 43 | 0x2b | `touching_facing_opposite` | Perception | Kind | |
| 44 | 0x2c | `touching_facing_same` | Perception | Kind | |
| 47 | 0x2f | `send_to_touching_object` | Messages | Message | |
| 48 | 0x30 | `carried_by` | Items | Character | |
| 49 | 0x31 | `drop_at` | Items | Character | |
| 50 | 0x32 | `selected_item_is` | Items | Number | |
| 51 | 0x33 | `send_to_selected_item` | Messages | Message | |
| 52 | 0x34 | `use_over_gap` | Input | Number | |
| 53 | 0x35 | `input_buttons_only` | Input | Button | |
| 54 | 0x36 | `make_solid` | Terrain change | Number | |
| 55 | 0x37 | `make_empty` | Terrain change | Number | |
| 60 | 0x3c | `touching_kind_in_pose` | Perception | Kind and pose | |
| 61 | 0x3d | `touching_in_pose` | Perception | Number | |
| 62 | 0x3e | `set_timer` | Timers and health | Number | |
| 63 | 0x3f | `timer_reaches` | Timers and health | Number | |
| 64 | 0x40 | `sees` | Perception | Kind and cells | |
| 67 | 0x43 | `sleep_unless_near_player` | Presence | None | |
| 68 | 0x44 | `set_timer_from` | Timers and health | Parameter (number) | |
| 69 | 0x45 | `touching_anyone` | Perception | None | |
| 70 | 0x46 | `send_to_touching_facing_opposite` | Messages | Message | |
| 71 | 0x47 | `send_to_touching_facing_same` | Messages | Message | |
| 72 | 0x48 | `send_to_matching_device` | Messages | Message | Parameter 0 (`kind`) |
| 74 | 0x4a | `use_up` | Presence | Character | |
| 75 | 0x4b | `remove` | Presence | None | |
| 76 | 0x4c | `in_view` | Presence | None | |
| 77 | 0x4d | `out_of_view` | Presence | None | |
| 78 | 0x4e | `move_with_riders` | Carriers | Number | |
| 79 | 0x4f | `start_defeat` | Combat | Number | |
| 80 | 0x50 | `touching` | Perception | Kind | |
| 84 | 0x54 | `player_touching` | Perception | Kind | |
| 85 | 0x55 | `set_charge` | Timers and health | Number | |
| 86 | 0x56 | `add_charge` | Timers and health | Number | |
| 87 | 0x57 | `reveal` | Presence | Parameter (number) | |
| 88 | 0x58 | `copy_health_to` | Timers and health | Character | Parameter 0 (`health`) |
| 89 | 0x59 | `mirror_health` | Timers and health | Character | |
| 90 | 0x5a | `play_scene` | World | Number | |
| 92 | 0x5c | `start_defeat_with_scene` | Combat | Number (`scene`) | Parameter 3 (`delay`) |
| 95 | 0x5f | `snap_to_wall_ahead` | Combat | Flag (`through_low_gaps`) | Parameter 0 (`range`) |
| 96 | 0x60 | `appear_at_sender` | Presence | Message | |
| 97 | 0x61 | `chance` | Chance | Number | |
| 98 | 0x62 | `facing_target_unhittable` | Perception | Kind and hit message | Parameter 0 (`range`) |
| 99 | 0x63 | `backturned_target_unhittable` | Perception | Kind and hit message | Parameter 0 (`range`) |
| 100 | 0x64 | `shoot` | Combat | Height | Parameter 0 (`range`) |
| 101 | 0x65 | `credit` | Timers and health | Parameter (link and amount) | |
| 102 | 0x66 | `debit` | Timers and health | Parameter (link and amount) | |
| 103 | 0x67 | `low_passage_ahead` | Terrain | Number | |
| 104 | 0x68 | `make_low_passage` | Terrain change | Number | |
| 105 | 0x69 | `checkpoint` | Presence | None | |
| 106 | 0x6a | `enemy_in_line` | Perception | Number | |
| 107 | 0x6b | `hit` | Combat | Hit side | |
| 108 | 0x6c | `offer_payment` | Items | Message | Parameter 0 (`seller`) |
| 109 | 0x6d | `touching_pickup` | Items | Number | |
| 110 | 0x6e | `board_sender` | Carriers | Message | |
| 111 | 0x6f | `acknowledge` | Messages | Message | |
| 113 | 0x71 | `release_on` | Carriers | Message | |
| 114 | 0x72 | `restore_terrain` | Terrain change | Number | |
| 115 | 0x73 | `board_touching` | Carriers | Kind | |
| 116 | 0x74 | `floor_below_ahead` | Terrain | Number | |
| 118 | 0x76 | `player_above` | Perception | None | |
| 119 | 0x77 | `player_below` | Perception | None | |
| 120 | 0x78 | `player_ahead` | Perception | Number | |
| 121 | 0x79 | `player_behind` | Perception | Number | |
| 122 | 0x7a | `step_clear_ahead` | Terrain | Number | |
| 123 | 0x7b | `show_message` | World | Number | |
| 124 | 0x7c | `send_to_touching_device` | Messages | Message | |
| 125 | 0x7d | `play_sound` | World | Number | |
| 126 | 0x7e | `broadcast` | Messages | Message | |
| 127 | 0x7f | `no_loose_cargo` | Carriers | None | |
| 128 | 0x80 | `align_with_carrier` | Carriers | None | |
| 129 | 0x81 | `follow_carrier_x` | Carriers | None | |
| 130 | 0x82 | `transport` | World | Parameter (link pair `move`, `to`) | |
| 131 | 0x83 | `player_has_item` | Items | Number | |
| 132 | 0x84 | `exit_level` | World | Number | |
| 133 | 0x85 | `shake_screen` | World | None | |
| 134 | 0x86 | `strike` | Combat | Height | Parameter 3 (`range`) |
| 135 | 0x87 | `play_sound_from` | World | Parameter (number) | |
| 136 | 0x88 | `snap_to_grid` | Terrain | None | |
| 138 | 0x8a | `set_weapon_mode` | World | Number | |
| 139 | 0x8b | `weapon_mode_is` | World | Number | |

The original files use the 121 codes of the table, and no other code. The extractor knows no other
code. For an unknown code, it writes `.unknown_N = argument` and adds a note to `report.txt`.

### Arguments

| Argument | Description |
| --- | --- |
| None | The original ignores the argument. The extractor counts the operations with an argument that is not 0. |
| Number | A plain number: cells, steps, a scene, a sound, a text or an object number. |
| Cells behind | A column offset that the original counts toward the back. The extractor writes it negated, as cells ahead. |
| Message | A message value. The extractor writes it by name. |
| Link `p` and message | The message goes to the character in placement parameter `p`. The argument is the message. |
| Parameter (number) | The index, from 0 to 3, of a placement parameter that holds a number. |
| Parameter (link and amount) | The index `p` of a placement parameter that holds a link. Parameter `p + 1` holds an amount. |
| Parameter (link pair) | The index `p` of two placement parameters, `p` and `p + 1`, that hold links. |
| Character | A placement index. |
| Kind | A character kind ([placements.md](placements.md)). The value -1 is `any`. |
| Button | 0 for Shift, 1 for Enter, 2 for Space. |
| Hit side | 0 for a hit from behind, 1 for a hit from the front. Another value accepts a hit from the front, but a shot or a blow never finds that the character waits for it. |
| Height | 0 for standing, 1 for crouched. |
| Flag | 0 for false, 1 for true. |
| Kind and `x` | A second condition. It reads the argument of the first condition as a kind, also when the code of the first condition is 0. Its own argument is `x`. In another position, the extractor writes `.name_raw = argument` and adds a note to `report.txt`. |

The extractor names a message value from the naming overlay
([naming-overlay.md](naming-overlay.md)). If the overlay has no name for it, the extractor uses
the name that the engine gives: 1 `hit_behind_high`, 2 `hit_behind_low`, 3 `hit_front_high`,
4 `hit_front_low` and 12 `acknowledged`. Else it writes `signal_N`, or `signal_minus_N` for a
negative value.

## Procedures

### Read a rule group

1. Read `DATA/name.OBJ`, where `name` is the file name of the level. The file must have at most
   262144 bytes.
2. Read `count`. Make sure that `count` is at most 256 and more than the group index. Make sure
   that the directory is in the file.
3. Read the offset of the group. Make sure that it is not in the directory, and that 2 bytes at it
   are in the file.
4. Read the number of rules. Make sure that all the rules are in the file.

### Extract the behaviors of a level

1. For each rule group that a placement names, read the group.
2. Make a list of the states, in the order of their first appearance in the rules. In each rule,
   the source comes before the target. The index in this list is the ordinal of the state.
3. For each state, take the run of rules that starts at the first rule whose source is the state.
   Drop the rules outside these runs, and count them in `report.txt`.
4. If a placement starts in a state that no rule names, add a state with no rules.
5. Calculate the key of the group (see below).
6. Find the names of the behavior and of its states in the naming overlay
   ([naming-overlay.md](naming-overlay.md)), by the key.
7. Decide from the operations if each placement parameter is a link, a number, or both.
8. Write one behavior table for each group.

### Calculate the key of a group

The key identifies a behavior, also when its copies use other state numbers or message values. The
naming overlay finds a behavior by its key.

1. Give each state number a new number, in the order of its first appearance: 0, 1, 2 and so on.
   Do the same for the message values, in a separate list. Only the arguments of the kinds
   "Message" and "Link `p` and message" are message values here.
2. Encode each rule in 18 bytes, in this order:
   - the new source and the new target (`u16` each);
   - `dx`, `dy` and the flags (one byte each);
   - `next` (`u16`);
   - the code (`u8`) and the argument (`u16`) of the first condition, of the second condition and
     of the effect.
3. Calculate the SHA-256 digest of all the encoded rules.
4. The key is the first 8 bytes of the digest, as 16 lowercase hexadecimal digits.

## Checks

| Condition | Error |
| --- | --- |
| The file has more than 262144 bytes. | `error.TooLarge` |
| The file has fewer than 2 bytes. | `error.TruncatedRuleDirectory` |
| `count` is more than 256, the group index is not less than `count`, or the directory goes past the end of the file. | `error.InvalidRuleDirectory` |
| The offset of the group is in the directory or past the end of the file, or fewer than 2 bytes follow it. | `error.InvalidRuleOffset` |
| The rules go past the end of the file. | `error.TruncatedRules` |

The extractor does not refuse unknown codes, unexpected arguments or a "Kind and `x`" operation
that is not the second condition. It writes a field with the raw value, `.unknown_N` or
`.name_raw`, and adds a note to `report.txt`.

## Quirks

- **Code 52 tests Enter.** The DOS executable prepares the Enter entry of its button table but
  reads the Shift entry, so its Conrad throws a stone at a gap with no step back and can fall.
  The Mega Drive edition reads the Enter entry, and its Conrad steps back first. flashbackz
  tests Enter, as the Mega Drive does (user decision, 2026-10-17; flashback-re
  `docs/floppy-stones.md`). Conrad's rules use code 52 one time in each level.

- **The `next` field.** The original starts the scan of the target state at rule `next`
  (research: flashback-re `docs/rules/README.md`). The extractor ignores `next`, except in the key,
  and starts at the first rule of the state. In the original files, `next` always gives that rule.
- **Unreachable rules.** The original scans the rules of a state while their source is the state.
  Thus a second run of rules with the same source cannot fire.

## Sources

- `src/extract/rule_table.zig`, `src/extract/codes.zig`, `src/extract/key.zig`,
  `src/extract/level.zig` (`collectBehavior`, `classifyParameters`, `writeRule` and
  `writeValue`) and `src/extract/root.zig`.
- `src/shared/behavior/world.zig` (`fireFirstRule` and `enter`).
- flashback-re: `docs/rule-vocabulary.md`, `docs/rules/README.md`, `docs/rules/codes-001-033.md`,
  `docs/rules/codes-034-072.md`, `docs/rules/codes-074-110.md` and
  `docs/rules/codes-111-139.md`.
