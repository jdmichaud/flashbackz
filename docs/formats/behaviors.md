# Behavior tables (`<level>/behaviors/<name>.zon`)

A behavior table gives the states of a family of characters and, for each state, the rules that
change it. The engine runs every character, Conrad included, from its table, with one fixed
vocabulary of conditions and effects.

| Item | Value |
| --- | --- |
| Files | `<level>/behaviors/<name>.zon`, any number in each level directory of the data set ([data-set.md](data-set.md)) |
| Format | ASCII text in ZON. Byte order does not apply. |
| Reader | `src/shared/behavior/data_set.zig` (`Loader.parseBehavior`, `parseRule`, `parseOperation`, `parseArgument`); the types are in `src/shared/behavior/vocabulary.zig` |
| Writer | `src/extract/level.zig` (`writeBehavior`, `writeRule`, `writeOperation`, `writeValue`), with the names of `src/extract/codes.zig` |
| Engine | `src/shared/behavior/world.zig` (the order) and `src/shared/behavior/operations/` (one function for each name) |

## Layout

The name of the file, with no `.zon`, is the behavior name. A character refers to its behavior
by this name ([characters.md](characters.md)). The loader reads the behavior files of a level in
the byte order of their names. It reads only the `.zon` files directly in `behaviors/`, not the
files in its subdirectories.

### Root fields

The root is a struct literal.

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `key` | String | Ignored | The structural key of the original rule group ([naming-overlay.md](naming-overlay.md)). The reader ignores it. |
| `links` | List of names, at most 4 | No links | The link names of the behavior. Each character binds each link to a character. |
| `numbers` | List of names, at most 4 | No numbers | The number names of the behavior. Each character gives each number a value. |
| `states` | Struct literal | Necessary | The states. Each field name is a state name. |

The reader refuses other root fields. The rules refer to a link or a number by its name. The
extractor writes the links and the numbers in the order of the original placement parameters.
It leaves out the parameters that the behavior does not use.

### State fields

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `animation` | Integer, 0 to 65535 | Necessary | The animation that the state plays ([animations.md](animations.md)). It must be in the level's files. |
| `rules` | List of rules | Necessary | The rules of the state, in order. In a state with no rules (`.{}`), no rule fires, and the character keeps its last frame. |

The reader refuses other fields of a state. The order of the states in the file is not
important to the engine.

### Rule fields

A rule is a struct literal with the fields below, all optional. `.{}` is a rule with no field: it
always fires, changes nothing, and starts the animation of its state again.

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `when` | List of operations | No checks | The checks, in order. |
| `then` | One operation | No effect | The effect when the rule fires. The engine ignores its result. |
| `turn` | Boolean | `false` | The character turns around. |
| `damage` | Boolean | `false` | Health decreases by 1. For the `player` kind, the protection from hits starts when the character is next in a state that checks for hits. For an `enemy`, the score increases by 100. |
| `heal` | Boolean | `false` | Health increases by 1. |
| `kill` | Boolean | `false` | Health becomes -1. |
| `score` | Integer, 0 to 65535 | 0 | Points to add to the score. |
| `forward` | Integer, -4096 to 4096 | 0 | Pixels to move in the direction that the character faces after `turn`. |
| `down` | Integer, -4096 to 4096 | 0 | Pixels to move down. |
| `next` | State name | The rule's own state | The state that the rule starts. |

### Operations

An operation is a condition or an effect of the [vocabulary](#vocabulary). It has one of two
forms:

- `.name`, for an operation with no argument.
- `.{ .name = argument }`, a struct literal with exactly one field, for an operation with an
  argument.

Any operation can be a check in `when` or the effect in `then`. Some operations that the
vocabulary calls effects are always true, so they can be checks that always pass.

### Argument types

| Type | Example | Values |
| --- | --- | --- |
| integer | `16` | An integer from -4096 to 4096 |
| message | `.call` | A message name ([Messages](#messages)) |
| link | `.friend` | A name of the behavior's `links` list |
| number | `.shot_range` | A name of the behavior's `numbers` list. The engine reads the character's value of that number. |
| character | `.conrad` | A character name of the level's `characters.zon` |
| kind | `.player` | A kind name ([characters.md](characters.md#kinds)) |
| button | `.shift` | `.shift`, `.enter` or `.space` |
| side | `.from_front` | `.from_behind`, `.from_front` or `.from_front_unannounced` |
| height | `.standing` | `.standing` (a high hit) or `.crouched` (a low hit) |
| boolean | `true` | `true` or `false` |
| struct | `.{ .kind = .player, .cells = 16 }` | The fields that the vocabulary gives, each of its own type. All are necessary. The reader refuses other fields. |

### Messages

A message name is any name. All behavior files of a level share their message names: the same
name in two files is the same message. The engine gives five names a fixed function:

| Name | Original value | Description |
| --- | --- | --- |
| `hit_behind_high` | 1 | A standing hit from a character that faces the same way |
| `hit_behind_low` | 2 | A crouched hit from a character that faces the same way |
| `hit_front_high` | 3 | A standing hit from a character that faces the other way |
| `hit_front_low` | 4 | A crouched hit from a character that faces the other way |
| `acknowledged` | 12 | The reply that `acknowledge` sends |

The extractor writes the other message values with the name of the naming overlay
([naming-overlay.md](naming-overlay.md)). With no name there, it writes `signal_N`, or
`signal_minus_N` for a negative value.

### Example

This example is synthetic.

```zon
// Generated with --extract from the user's game files. Do not commit.
// Original city rule group 7. Name this behavior in the overlay with its key.
.{
    .key = "0123456789abcdef",
    .links = .{ .friend, .cover },
    .numbers = .{ .room_to_appear, .shot_range },
    .states = .{
        .waiting = .{ // ordinal 0
            .animation = 100,
            .rules = .{
                .{
                    .when = .{.{ .received = .call }},
                    .then = .{ .reveal = .room_to_appear },
                },
                .{
                    .when = .{ .out_of_view, .{ .chance = 5 } },
                    .then = .{ .send = .{ .to = .friend, .message = .call } },
                    .turn = true,
                    .forward = -16,
                    .next = .aiming,
                },
                .{},
            },
        },
        .aiming = .{ // ordinal 1
            .animation = 101,
            .rules = .{
                .{
                    .when = .{.{ .sees = .{ .kind = .player, .cells = 16 } }},
                    .then = .{ .shoot = .{ .height = .standing, .range = .shot_range } },
                    .damage = true,
                    .next = .waiting,
                },
            },
        },
    },
}
```

## Procedures

### How the extractor writes a table

The extractor writes one file for each rule group that a placement of the level uses
([rule-groups.md](rule-groups.md)).

1. It collects the state numbers of the group, each at its first appearance. It reads the source
   and then the target of each rule, in rule order. This order is the ordinal of a state. The
   file shows it as `// ordinal N`, and the naming overlay uses it.
2. The rules of a state are the consecutive rules that start at the first rule with that state
   as source. The extractor drops the later rules of that state, because the original never
   reaches them. The report counts them.
3. A placement can start in a state that no rule names. Then the extractor adds that state after
   the others, with no rules. The report notes it.
4. The state name is the overlay name of its ordinal, or `state_N` with N the animation number.
   The `animation` field holds the state number.
5. For each rule, the extractor writes the first condition and then the second condition into
   `when`. A condition with code 0 is absent. An effect that is not code 0 goes into `then`.
6. Flag bits 0 to 3 become `turn`, `damage`, `heal` and `kill`. Bits 4 to 7 select a score award
   in the executable's table, and `score` holds the award.
7. `forward` is the negated dx of the rule, because the original's dx points to the character's
   back. `down` is the dy. `next` is present when the target differs from the source.
8. A rule with no checks, no effect, no flags, no movement and the same target becomes `.{}`.

Some original operations also read a placement parameter that is not their argument. The
extractor adds that parameter as a number field of the struct argument:

| Operation | Field | Parameter | Default name |
| --- | --- | --- | --- |
| `send_to_matching_device` | `kind` | 0 | `device_kind` |
| `copy_health_to` | `health` | 0 | `health_to_copy` |
| `offer_payment` | `seller` | 0 | `seller_kind` |
| `facing_target_unhittable`, `backturned_target_unhittable` | `range` | 0 | `shot_range` |
| `shoot` | `range` | 0 | `shot_range` |
| `snap_to_wall_ahead` | `range` | 0 | `range` |
| `strike` | `range` | 3 | `strike_range` |
| `start_defeat_with_scene` | `delay` | 3 | `defeat_delay` |

Other numbers and links get their names from the overlay, or `number_P` and `link_P`, with P the
parameter (0 to 3). These rules also apply:

- `set_timer_from`, `reveal` and `play_sound_from` select a parameter that holds a number.
- `credit` and `debit` select a parameter that holds a link (`purse`). The next parameter holds
  the `amount`.
- `transport` selects two consecutive parameters that hold links (`move` and `to`).
- `send` comes from four original codes, one for each parameter that holds the link.
- `touching_kind_in_pose`, `sees`, `facing_target_unhittable` and
  `backturned_target_unhittable` read their `kind` from the argument of the first condition of
  the rule. When one of them is the second condition, the extractor writes that argument as its
  `kind`. In another position, it writes the raw form `.{ .NAME_raw = A }`, and the report notes
  it.
- For `ledge_above_behind`, `floor_edge_behind`, `ledge_above_ahead`, `floor_edge_ahead`,
  `grab_edge_ahead`, `wall_beyond_gap`, `wall_starts` and `wall_ends`, the original counts the
  columns backward. The extractor negates the argument, so it counts cells ahead.
- A `hit` argument of 0 is `from_behind` and 1 is `from_front`. All other values are
  `from_front_unannounced`.

### How the engine runs the tables

These steps give the order of one update. The order is part of each behavior.

1. The engine registers the cells of the characters: first the characters of the view room,
   then all other awake characters.
2. It walks the characters in index order, the order of `characters.zon`. It skips each
   character that is not awake when the walk gets to it. A character that wakes during the walk
   runs in the same walk if its index is higher.
3. If a rule of the current state waits for a message in the mailbox, the animation stops now.
   The movement of its frames that are left applies at once. A rule waits for a message with a
   `received` or an `acknowledge` of it. It also waits for a hit with a `hit` check on its side.
4. If the animation has frames left, the character plays the next frame. Go to step 8.
5. If not, the engine tries the rules of the current state in order. For each rule, it runs the
   checks of `when` from left to right and stops at the first false check.
6. The first rule with all checks true fires. The engine runs `then`. Then it sets the state to
   `next` and applies `score`, `turn`, `damage`, `heal`, `kill`, `forward` and `down`, in that
   order. Then the new animation plays its entry sound, and the character can go into the next
   room. Then it plays the first frame.
7. If no rule fires, the character keeps its last frame and tries its rules again in the next
   update.
8. The engine clears the mailbox of the character.

A check that changes the world (`set_timer`, `send`, `chance`) does its change when the engine
runs it. The change stays when a later check of the same rule is false. A random draw occurs only
where a check runs.

A message goes into the mailbox of the recipient at once, at the front. A recipient later in the
walk reads it in the same update; an earlier one reads it in the next update. The engine loses
these sends:

- A send to a character that is not awake and has no `wakes_on_message`.
- A hit to a character in another room than the sender, or to Conrad while his protection runs.
- A send when the 256 messages of the pool are in use.

## Vocabulary

Each name has one implementation in the engine. It is a function with the camel-case name in
`src/shared/behavior/operations/` (`no_floor_ahead` is `noFloorAhead`). "Always true" means that
the operation is true each time it runs. The other operations are true only as the description says.

Some terms:

- **Cells**: columns of 16 pixels. "Ahead" is the direction that the character faces.
- **Tier**: one of the three floors of a room. The rows of a tier are the ceiling (row 0), the
  body (row 1) and the floor (row 2). The floor of the tier below is row 4. A cell that is not 0
  is solid.
- **Its cells**: the cells of the character's footprint, registered at the start of the update.
  They are the `width` cells from its column to the right, on its tier. **Its first cell** is the
  first of them. A cell with a column outside 0 to 15 gets no contact slot. For an x outside 0
  to 255, the engine takes the column in the left or right room. Such a cell stops the
  registration of the character.
- **Waits for a hit**: the current state has a `received` of that hit message, or a `hit` check
  on that side (not `from_front_unannounced`).

### Input

Every character reads Conrad's controls. "Back" and "forward" follow the direction of the
character that reads them. A check is false when another direction or button is held, except
where the description says otherwise.

| Name | Argument | Description |
| --- | --- | --- |
| `input_up` | — | Only Up is held. |
| `input_down` | — | Only Down is held. |
| `input_back` | — | Only the direction behind the character is held. |
| `input_forward` | — | Only the direction ahead of the character is held. |
| `input_up_and`, `input_down_and`, `input_back_and`, `input_forward_and` | button | Only that direction and that button are held. |
| `input_none` | — | Nothing is held. |
| `input_button` | button | That button is the only button held. Directions do not matter. |
| `input_buttons_only` | button | Only that button is held, with no direction. |
| `use_over_gap` | integer | Enter is the only button held, and the floor that many cells ahead is empty. Directions do not matter. The DOS original tests Shift here; Enter is a user decision ([rule-groups.md](rule-groups.md#quirks)). |

### Terrain

These checks read the cells from the character's column at the start of its update. "Ahead"
follows the current direction of the character.

| Name | Argument | Description |
| --- | --- | --- |
| `ceiling_ahead`, `wall_ahead`, `floor_ahead` | integer | The ceiling, body or floor cell that many cells ahead is solid. |
| `ceiling_here`, `wall_here`, `floor_here` | — | That cell of the character's column is solid. |
| `ceiling_behind`, `wall_behind`, `floor_behind` | integer | That cell that many cells behind is solid. |
| `no_ceiling_ahead`, `no_wall_ahead`, `no_floor_ahead` | integer | The ceiling, body or floor cell that many cells ahead is empty. |
| `no_ceiling_here`, `no_wall_here`, `no_floor_here` | — | That cell of the character's column is empty. |
| `no_ceiling_behind`, `no_wall_behind`, `no_floor_behind` | integer | That cell that many cells behind is empty. |
| `ledge_above_ahead` | integer k | The ceiling is solid at k and empty at k + 1, and the body cell of the tier above is empty at k. |
| `ledge_above_behind` | integer k | The ceiling is solid at k and empty at k - 1, and the body cell of the tier above is empty at k. |
| `floor_edge_ahead` | integer k | The floor is solid at k and empty at k + 1, and the body cell is empty at k. |
| `floor_edge_behind` | integer k | The floor is solid at k and empty at k - 1, and the body cell is empty at k. |
| `grab_edge_ahead` | integer k | The floor is empty at k and solid at k + 1, and the body cell is empty at k + 1. |
| `wall_beyond_gap` | integer k | The floor is empty at k, and the body cell is solid at k + 1. |
| `wall_starts` | integer k | The body cell is empty at k and solid at k + 1. |
| `wall_ends` | integer k | The body cell is solid at k and empty at k + 1. |
| `low_passage_ahead` | integer | The body cell that many cells ahead has bit 1 set: a low passage that only a roll goes through. |
| `floor_below_ahead` | integer | The floor of the tier below, that many cells ahead, is solid. |
| `step_clear_ahead` | integer | The body cell that many cells ahead is empty, and the floor one cell farther is solid. |
| `snap_to_grid` | — | Sets x to a multiple of 16, and y to the floor line of its tier (70, 142 or 214). Always true. |

In this table, k counts cells ahead; a negative k is behind.

### Terrain changes

The row is 1 for the body and 2 for the floor of the character's tier. The changed cells start at
the character's column and go toward its back, as many as its `width`. A character out of the 64
rooms changes nothing. The engine keeps the old cells of each change for `restore_terrain`. When
this history is full, a change at a new start cell writes nothing.

| Name | Argument | Description |
| --- | --- | --- |
| `make_solid` | integer (row) | Fills the cells with solid terrain and keeps the old cells. Always true. |
| `make_empty` | integer (row) | Empties the cells and keeps the old cells. Always true. |
| `make_low_passage` | integer (row) | Fills the cells with low passage (value 2) and keeps the old cells. Always true. |
| `restore_terrain` | integer (row) | Puts back the old cells of the newest change that starts at the character's column on that row. The result is false at some positions (quirk). |

### Messages

| Name | Argument | Description |
| --- | --- | --- |
| `received` | message | A message with that name is in the mailbox. |
| `send` | `.{ .to = link, .message = message }` | Sends the message to the character that the link names. Always true. |
| `send_to_selected_item` | message | Sends to the selected item of the character, if it has one. Always true. |
| `send_to_touching_object` | message | Sends to the first `interactive` character in its first cell. True when there is one. |
| `send_to_touching_facing_opposite` | message | Sends to each other character in its cells that faces the other way. Conrad sends only to the first. True when it sends. |
| `send_to_touching_facing_same` | message | Sends to each other character in its cells that faces the same way. Conrad sends only to the first. True when it sends. |
| `send_to_matching_device` | `.{ .message = message, .kind = number }` | Sends to the character in Conrad's first cell of the kind that the number holds, when its health equals this character's health. True when it sends. |
| `send_to_touching_device` | message | Sends to a character in its first cell. Kinds 3, 5 and 9 come first, in that order. Never true. |
| `broadcast` | message | Sends to each other character in its cells, one message for each shared cell. True when it sends. |
| `acknowledge` | message | Sends `acknowledged` to the newest sender of a message with that name. True when there is such a message. |

A send that the engine loses still counts as a send for the result.

### Timers, health and money

Each character has one counter. Items use the health as a charge, a code or an amount of money.

| Name | Argument | Description |
| --- | --- | --- |
| `set_timer` | integer | Sets the counter. Always true. |
| `set_timer_from` | number | Sets the counter to the value of the number. Always true. |
| `timer_reaches` | integer | Decreases the counter by 1. True when the counter then equals the integer. |
| `defeated` | — | The health is 0 or less. Each time this is true for an `enemy`, the score increases by 100. |
| `set_charge` | integer | Sets the health. Always true. |
| `add_charge` | integer | Adds the integer to the health. Always true. |
| `copy_health_to` | `.{ .character = character, .health = number }` | Sets the health of that character to the value of the number. Always true. |
| `mirror_health` | character | Sets the health to the health of that character, minus 1. Always true. |
| `credit` | `.{ .purse = link, .amount = number }` | Adds the amount to the health of the linked character. Always true. |
| `debit` | `.{ .purse = link, .amount = number }` | Subtracts the amount from the health of the linked character. Always true. |

### Presence and activity

| Name | Argument | Description |
| --- | --- | --- |
| `in_view` | — | The character is in the view room. |
| `out_of_view` | — | The character is not in the view room. |
| `sleep_unless_near_player` | — | The engine stops the updates of the character, unless it has `wakes_when_near` and is in or beside the view room. The animation that starts in this update has no entry sound. Always true. |
| `reveal` | number | Moves the character to the room that the number holds and shows its frame. For the `player` kind, the view follows after the update. Always true. |
| `appear_at_sender` | message | Takes the position, room and direction of the newest sender of a message with that name, and leaves its owner. True when there is such a message. |
| `remove` | — | The character leaves the world, and the engine stops its updates. An `enemy` gives 200 points. Always true. |
| `use_up` | character | The character leaves the world and the inventory of that character, and the engine stops its updates. Always true. |
| `checkpoint` | — | Keeps the state that a continue restores: all characters, the score and the terrain. Always true. |

### Perception and contact

| Name | Argument | Description |
| --- | --- | --- |
| `touching` | kind | A character of that kind is in its cells. The character itself counts. An `enemy` with negative health does not count. |
| `touching_anyone` | — | Another character is in its cells. |
| `touching_facing_opposite` | kind | A character of that kind in its cells faces the other way. |
| `touching_facing_same` | kind | A character of that kind in its cells faces the same way. The character itself counts. |
| `touching_kind_in_pose` | `.{ .kind = kind, .pose = integer }` | A character of that kind in its cells plays an animation with that pose. The character itself counts. |
| `touching_in_pose` | integer | Another character in its cells plays an animation with that pose. |
| `player_touching` | kind | Conrad's first cell holds another character of that kind. |
| `sees` | `.{ .kind = kind, .cells = integer }` | An active character of that kind is on its tier, within that many cells (at most 16) and before a solid body cell. A positive value looks ahead. |
| `enemy_in_line` | integer | An awake `player` or `enemy` is on its tier, within the integer + 1 cells and before a solid body cell. Its health is 0 or more. A positive value looks ahead. |
| `facing_target_unhittable` | `.{ .kind = kind, .hit = message, .range = number }` | An active character of that kind within the range faces the other way and does not wait for that hit. |
| `backturned_target_unhittable` | `.{ .kind = kind, .hit = message, .range = number }` | An active character of that kind within the range faces the same way and does not wait for that hit. |
| `player_above` | — | Conrad is on a higher tier of the same room, or in the room above. |
| `player_below` | — | Conrad is on a lower tier of the same room, or in the room below. |
| `player_ahead` | integer | Conrad is on this tier, ahead by more than 0 and less than that many cells. With 0: anywhere ahead in this room, or on this tier of the next room ahead. |
| `player_behind` | integer | As `player_ahead`, behind the character. |

The pose is a tag of the animation ([animations.md](animations.md)). The engine compares its low
byte. `sees` and `enemy_in_line` watch only the view room and the rooms on its left and right.

### Chance

| Name | Argument | Description |
| --- | --- | --- |
| `chance` | integer, at least 1 | One random draw. True when the drawn value, read as signed, divides by the integer with no remainder. |

### Combat

A standing shot or blow gives a high hit, and a crouched one gives a low hit. The hit is from
behind when the two characters face the same way.

| Name | Argument | Description |
| --- | --- | --- |
| `hit` | side | A hit from that side is in the mailbox, at either height. `from_front` and `from_front_unannounced` both match a hit from the front. |
| `shoot` | `.{ .height = height, .range = number }` | Fires along its tier, from the next cell, up to the range (positive: ahead). The first active `player`, `enemy` or `kind_12` character that waits for the hit gets it. True when it sends a hit. |
| `strike` | `.{ .height = height, .range = number }` | A close blow, as `shoot`, but only a `player` or an `enemy` can get it. |
| `snap_to_wall_ahead` | `.{ .through_low_gaps = boolean, .range = number }` | Moves x to the first wall within the range, from its own cell. With `true`, a low passage does not stop it. True when it finds a wall. |
| `start_defeat` | integer | Starts a defeat countdown of that many updates, unless one runs. Always true. |
| `start_defeat_with_scene` | `.{ .scene = integer, .delay = number }` | Starts a defeat countdown of the delay + 1 updates, then that scene, unless a countdown runs. Always true. |

A wall stops a shot or a blow. A low passage stops it only when it is standing.

### Inventory and items

| Name | Argument | Description |
| --- | --- | --- |
| `carried_by` | character | Becomes the last item of that character and leaves the rooms. Always true. |
| `drop_at` | character | Takes the position, room and direction of that character, and leaves its owner. Always true. |
| `selected_item_is` | integer | Conrad's selected item has that `object` number. |
| `player_has_item` | integer | Conrad carries an item with that `object` number. |
| `touching_pickup` | integer | The first `interactive` character in its first cell, itself included, has that `contact_icon`. A kind with the low byte 0xff also counts. With no such character, the icon is 0. |
| `offer_payment` | `.{ .message = message, .seller = number }` | The seller is the character in Conrad's first cell of the kind that the number holds. When this character's health is at least the seller's health, it sends the message to the seller. True when it sends. |

### Lifts and carriers

A rider is in the item list of its carrier.

| Name | Argument | Description |
| --- | --- | --- |
| `move_with_riders` | integer | Moves the character and its direct riders down by the integer. Always true. |
| `board_sender` | message | Becomes the last rider of the newest sender of a message with that name. True when there is such a message. |
| `board_touching` | kind | Becomes a rider of the first other character of that kind in its first cell. False when there is none, or when the carrier's index is 120 or 248 (quirk). |
| `release_on` | message | When a message with that name is in the mailbox, the character stops its ride. True when there is such a message. |
| `no_loose_cargo` | — | Each `interactive` character in its cells is its own rider. |
| `align_with_carrier` | — | Takes the x of its carrier, if it has one. Always true. |
| `follow_carrier_x` | — | With r the carrier's x modulo 256: takes r when r is at or past its own x, else adds r. Always true. |

### World and presentation

| Name | Argument | Description |
| --- | --- | --- |
| `play_scene` | integer | Asks for that scene of `scenes.zon` after the update, unless a defeat countdown runs. Scene 61 starts the ending. Always true. |
| `show_message` | integer | Shows that world message of `messages.zon`. Always true. |
| `play_sound` | integer | Plays the sound in the low byte, wherever the character is. A high byte that is not 0 plays it quieter. Always true. |
| `play_sound_from` | number | As `play_sound`, with the value of the number. Always true. |
| `transport` | `.{ .move = link, .to = link }` | Moves the `move` character to the position and room of the `to` character, when that room is 0 to 63. If the two have the same behavior, it also takes the state and the direction. Always true. |
| `exit_level` | integer | Loads that level after the update, counted from 1 in the order of the levels. True, except for level 1 (quirk). |
| `shake_screen` | — | One random draw sets the vertical shake of the view. Always true. |
| `set_weapon_mode` | integer | Sets the weapon mode that all characters share. Always true. |
| `weapon_mode_is` | integer | The shared weapon mode equals the integer. |

### Kinds in the rules

The contact checks, `facing_target_unhittable` and `backturned_target_unhittable` compare kinds
by their low byte. `sees`, `enemy_in_line`, `shoot`, `strike` and `no_loose_cargo` compare the
whole value. In the searches of a first cell (`player_touching`, `board_touching`,
`send_to_matching_device`, `offer_payment`), `any` matches all kinds. The engine also uses three
kinds that have no name: `send_to_touching_device` prefers kinds 5 and 9 after kind 3, and a shot
hits kind 12.

## Checks

The loader stops at the first failure. The game logs `data set: TEXT` as an error. FILE is the
name of the behavior file, for example `guard.zon`. OP is the name of an operation.

| Check | Text |
| --- | --- |
| The file is not valid ZON (two fields with the same name included) | `FILE: not valid ZON` |
| The root is not a struct literal | `FILE: expected a struct` |
| The root has a field that is not `key`, `links`, `numbers` or `states` | `FILE: unknown field F` |
| `states` is absent | `FILE: no states` |
| `states` or a rule is not a struct literal | `FILE: expected a struct` |
| A state has a field that is not `animation` or `rules` | `FILE: STATE: unknown field F` |
| A state has no `animation` | `FILE: STATE has no animation` |
| `animation` is not an integer from 0 to 65535 | `FILE: STATE has an invalid animation` |
| A state has no `rules` | `FILE: STATE has no rules` |
| `rules` is not a list | `FILE: STATE rules must be a list` |
| `links` or `numbers` is not a list | `FILE: links and numbers must be lists` |
| `links` or `numbers` has more than 4 names | `FILE: at most four links or numbers` |
| A name of `links` or `numbers` is not an enum literal | `FILE: names must be enum literals` |
| A rule field is not in the list of fields | `FILE: unknown rule field F` |
| `when` is not a list | `FILE: when must be a list` |
| `next` is not a name | `FILE: next must name a state` |
| `next` names no state of the file | `FILE: unknown state S` |
| `turn`, `damage`, `heal` or `kill` is not `true` or `false` | `FILE: F must be true or false` |
| `score`, `forward` or `down` is not an integer in its range | `FILE: F must be a number in range` |
| An operation name is not in the vocabulary, or has the other form (`.received` with no argument) | `FILE: unknown condition or effect OP` |
| An operation has another form | `FILE: a condition or effect is a name or .{ .name = argument }` |
| An integer argument is not an integer | `FILE: OP needs a number` |
| An integer argument is out of -4096 to 4096 | `FILE: OP must lie within -4096 and 4096` |
| `chance` is less than 1 | `FILE: chance must be at least 1` |
| A boolean argument is not `true` or `false` | `FILE: OP needs true or false` |
| A struct argument has a field that the vocabulary does not give | `FILE: OP has no field F` |
| A field of a struct argument is absent | `FILE: OP needs .F` |
| A name argument is not an enum literal | `FILE: OP needs a name` |
| A link name is not in `links` | `FILE: unknown link L` |
| A number name is not in `numbers` | `FILE: unknown number N` |
| A character name is not in `characters.zon` | `FILE: unknown character C` |
| A kind name is not known | `FILE: unknown kind K` |
| A button, side or height name is not known | `FILE: OP cannot be V` |
| At level start, an animation is not in the level's files | `behavior B, state S: animation N is not in the level's files (ERROR)` |

The extractor writes `.{ .unknown_C = A }` for an original code C that it does not know, and
`.{ .NAME_raw = A }` for an argument that it cannot write. The loader refuses both as unknown
operations. The report notes them ([data-set.md](data-set.md)).

## Quirks

- `restore_terrain` is false at some positions: the original tests the low byte of a memory
  address.
- `exit_level` is false for level 1: the original returns the low byte of the level index.
- `send_to_touching_device` is never true. As a check, it sends each time it runs, and its rule
  never fires.
- The searches of a first cell (`send_to_touching_object`, `send_to_touching_device`,
  `player_touching`, `board_touching`, `send_to_matching_device`, `offer_payment`) use only bits
  0-6 of the contact slot of that cell. Thus a first cell in slot 128 or more finds the characters
  of slot − 128.
- `board_touching` never finds a carrier at index 120 or 248.
- `from_front_unannounced` matches a hit from the front. But shots and blows do not count it as a
  wait for the hit, and it does not stop an animation early.
- `defeated` gives 100 points each time it is true for an enemy.
- `snap_to_wall_ahead` is true and does not move when its range ends after a low passage that it
  went through. A wall just past a room edge gives x 256 or -16, with the old room.

## Sources

- `src/extract/level.zig`: `collectBehavior`, `classifyParameters`, `writeBehavior`,
  `writeRule`, `writeOperation`, `writeValue`, `messageName`.
- `src/extract/codes.zig`: the names, the argument forms, the implicit numbers,
  `engineMessage`, `kindName`.
- `src/shared/behavior/data_set.zig`: `parseBehavior`, `nameList`, `parseRule`,
  `parseOperation`, `parseArgument`.
- `src/shared/behavior/vocabulary.zig`: `Operation`, `Rule`, `Message`, `Kind`, `HitSide`.
- `src/shared/behavior/world.zig`: `update`, `updateCharacter`, `skipToAwaitedRule`,
  `fireFirstRule`, `enter`, `send`.
- `src/shared/behavior/operations.zig` and `src/shared/behavior/operations/`: one function for
  each name.
- DESIGN.md, section 4.
- flashback-re `docs/rule-vocabulary.md` and `docs/rules/` (codes 1 to 139): the functions and
  the quirks of the original codes.
