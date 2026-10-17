# Characters (`<level>/characters.zon`)

`characters.zon` lists the characters of one level. Each character is one placement of the
original level, with its behavior table, start state, position and links. The engine updates the
characters in the order of this file.

| Item | Value |
| --- | --- |
| Files | `<level>/characters.zon`, one in each level directory of the data set ([data-set.md](data-set.md)) |
| Format | ASCII text in ZON. Byte order does not apply. |
| Reader | `src/shared/behavior/data_set.zig` (`loadLevel`, `Loader.parseCharacter`, `bindLinks`, `bindNumbers`) |
| Writer | `src/extract/level.zig` (`writeCharacters`, `writeParameters`, `characterId`) |

## Layout

The root is a struct literal. Each field is one character: the field name is the character name,
and the value is a struct literal with the fields below.

- The position of a character in the file is its index. The engine updates the characters in
  index order.
- A level has at most 256 characters.
- The first character must be of kind `player`. The engine finds Conrad as character 0. Its
  `room` must be 0 to 63: the level takes its colors and its first view from that room.
- Each character name must be unique. The behavior tables and the links refer to characters by
  name.

### Character fields

The "Placement" column gives the byte of the original placement record that the extractor reads
([placements.md](placements.md)). "Necessary" fields must be present.

| Field | Type and range | If absent | Placement | Content |
| --- | --- | --- | --- | --- |
| `placement` | Integer, 0 to 65535 | Necessary | Index | The index of the placement in the original file. Comparisons with the original use it. The engine uses the index in this file. |
| `label` | String | `""` | 30 (labels file) | The name that the touch label and the inventory show. Each byte must have a glyph in the level font and in the inventory font. |
| `label_number` | Integer, 0 to 65535 | 0 | 30 | The number of the label in the level's labels file ([labels.md](labels.md)) |
| `kind` | Kind name ([Kinds](#kinds)) | Necessary | 18 | The kind of the character |
| `behavior` | Name | Necessary | 6 | The behavior table: the name of a file in `<level>/behaviors/`, with no `.zon` ([behaviors.md](behaviors.md)) |
| `start` | Name | Necessary | 0 | The state of the behavior at level start |
| `room` | Integer 0 to 255, or `.outside` | Necessary | 19 | The start room. Rooms 0 to 63 are the rooms of the level. `.outside`: out of the world (room 64) until an effect moves the character in. |
| `position` | `.{ .x = X, .y = Y }`, each -4096 to 4096 | Necessary | 2, 4 | The position in the room, in pixels. Both fields are necessary, and the reader refuses other fields. |
| `facing` | `.left` or `.right` | Necessary | 26 | The start direction. The extractor writes `.right` for a byte that is not 0. |
| `health` | Integer, -32768 to 32767 | Necessary | 8 | The health. Items use it as a charge, a code, a price or an amount of money. |
| `width` | Integer, 0 to 16 | Necessary | 28 | The number of cells (columns) of the footprint. The terrain effects also use it. |
| `active` | Boolean | `false` | 20 | The character is awake at level start. |
| `wakes_on_message` | Boolean | `false` | 27, bit 0 | A message wakes the character. |
| `wakes_on_contact` | Boolean | `false` | 27, bit 1 | A character in one of its cells wakes it. |
| `wakes_when_near` | Boolean | `false` | 27, bit 2 | The character wakes when it is in the view room, or near Conrad's new room. |
| `other_flags` | Integer, 0 to 255 | 0 | 27, bits 3 to 7 | The other bits of the byte, in their positions. The engine reads them only where it copies the original's memory. |
| `minimum_difficulty` | `.easy`, `.normal`, `.expert`, or an integer from 3 to 255 | Necessary | 25 | The lowest difficulty that places the character. With an integer, no difficulty places it. |
| `palette_bank` | Integer, 0 to 255 | 0 | 21, bits 0 and 1 | Selects the palette of the character's art. The extractor writes 1 to 3. |
| `behind_player` | Boolean | `false` | 21, bit 3 | The screen draws the character behind Conrad. |
| `other_visual_flags` | Integer, 0 to 255 | 0 | 21, bit 2 and bits 4 to 7 | The other bits of the byte, in their positions. Bit 2 (value 4): the inventory shows the item's health as a quantity. |
| `contact_icon` | Integer, 0 to 255 | 0 | 22 | The icon that the touch label shows ([icons.md](icons.md)). `touching_pickup` compares it. |
| `inventory_icon` | Integer, 0 to 255 | 0 | 23 | The icon of the item in the inventory ([icons.md](icons.md)) |
| `object` | Integer, 0 to 255 | 0 | 24 | The object number that `selected_item_is` and `player_has_item` compare |
| `unknown_byte_29` | Integer, 0 to 255 | 0 | 29 | Unknown. The engine reads it only where it copies the original's memory. |
| `sprite_library` | `.junky`, `.mercenai`, `.replican`, `.glue` or `.none` | No library | — | The enemy sprite library of the character's art ([sprites.md](sprites.md)). `.none`: the art needs a library but has none, so the screen never draws it. |
| `links` | Struct literal | No links | 10 to 17 | Binds the links of the behavior ([Links](#links)). |
| `numbers` | Struct literal | All 0 | 10 to 17 | Gives the numbers of the behavior ([Numbers](#numbers)). |

The label comes from the labels file, at the label number in bytes 30 and 31. The extractor
writes `label` when the label is not empty, and `label_number` when the number is not 0. A label
that does not read gives an empty label and a note in the report ([labels.md](labels.md)).

The extractor writes a field with a default value only when the value is not the default. It
always writes `active`. It writes `sprite_library` for each enemy and for each character of
rule group 73, from the sprite library table of the executable.

### Links

`links` is a struct literal. Each field name is a link of the behavior, from the `links` list of
the behavior table. The value is a character name, or `.none` for no character. A link that is
absent names no character.

The extractor writes each link of the behavior. A placement parameter that is not the index of a
character becomes `.none`, with the parameter value in a comment.

### Numbers

`numbers` is a struct literal. Each field name is a number of the behavior, from the `numbers`
list of the behavior table. The value is an integer from -4096 to 4096. A number that is absent
is 0.

The names `parameter_0` to `parameter_3` are special when the behavior has no number with that
name. Such a field gives a placement parameter that no rule uses. The reader accepts it and
ignores the value. The extractor writes one for each parameter that is not 0 and is not a link
or a number of the behavior.

One placement parameter can be a link and a number of the same behavior. The two fields then come
from the same parameter value.

### Kinds

The extractor writes each placement kind (a byte) by name. The rules also use kinds
([behaviors.md](behaviors.md)).

| Name | Value | Use in the engine |
| --- | --- | --- |
| `any` | -1 | In the rules, the searches of a first cell match all kinds with it. |
| `player` | 1 | Conrad's kind. Room changes move the view with it. `damage` starts its protection from hits. |
| `interactive` | 3 | Items and devices: the touch label, the pickups and the object messages look for this kind. |
| `enemy` | 10 | Double health at difficulty expert. `damage`, `defeated` and `remove` give points. Shots and blows hit it. The extractor gives it a sprite library. |
| `overlay` | 11 | The screen draws its composed art over the foreground of the room. |
| `kind_N` | N | Any other kind, with N in decimal. The engine also uses kinds 5, 9 and 12 ([behaviors.md](behaviors.md)). |

Many checks compare kinds by their low byte ([behaviors.md](behaviors.md#kinds-in-the-rules)).

### Names that the extractor gives

1. Placement 0 is `conrad`.
2. Another placement is `BASE_I`, where I is the placement index.
3. BASE is the behavior name when the naming overlay names the behavior
   ([naming-overlay.md](naming-overlay.md)).
4. If not, BASE is the label in lower case. Each group of characters that are not letters or
   digits becomes one `_`. The start and the end get no `_` (`SAMPLE ITEM-2` gives
   `sample_item_2`). The extractor keeps at most 64 bytes.
5. If the label is empty, BASE is the kind name. If the label has no letters or digits, BASE is
   `character`.

### Example

This example is synthetic.

```zon
// Generated with --extract from the user's game files. Do not commit.
// Every placement of city, in the original update order.
.{
    .conrad = .{
        .placement = 0,
        .kind = .player,
        .behavior = .conrad,
        .start = .state_1,
        .room = 3,
        .position = .{ .x = 32, .y = 142 },
        .facing = .right,
        .health = 4,
        .width = 1,
        .active = true,
        .minimum_difficulty = .easy,
    },
    .guard_1 = .{
        .placement = 1,
        .kind = .enemy,
        .behavior = .guard,
        .start = .waiting,
        .room = .outside,
        .position = .{ .x = 96, .y = 214 },
        .facing = .left,
        .health = 2,
        .width = 1,
        .active = false,
        .wakes_on_message = true,
        .minimum_difficulty = .normal,
        .sprite_library = .junky,
        .links = .{
            .friend = .conrad,
            .cover = .none, // -1
        },
        .numbers = .{
            .room_to_appear = 5,
            .shot_range = 8,
        },
    },
}
```

## Procedures

### How a level starts its characters

1. A character is present when its `minimum_difficulty` is at most the difficulty of the game.
   Only present characters go into the rooms.
2. At difficulty expert, a present enemy starts with double health.
3. A present character starts awake when `active` is true. It also starts awake when
   `wakes_when_near` is true and its room is the `room` of the first character.
4. A character that is not present goes into no room. It keeps the direction, the look and the
   awake flag of the same index in the previous level.
5. Each present character shows the frame of its start state's animation.

### How a character wakes during play

- `wakes_on_message`: a message to the character wakes it. With no such flag, the engine loses a
  message to a character that is not awake.
- `wakes_on_contact`: at the start of an update, a character that shares one of its cells wakes
  it. A character that is not awake registers its cells only in the view room.
- `wakes_when_near`: the character wakes when it is in the view room at the start of an update.
  It also wakes when a `player` character crosses a room edge into its room. Then such
  characters of the room above wake at y 48 or more, and of the room below at y 176 or more.
  Enemies there do not wake.

## Checks

The loader stops at the first failure. The game logs `data set: TEXT` as an error. CHAR is the
character name.

| Check | Text |
| --- | --- |
| More than 256 characters | `characters.zon: N characters; a level holds at most 256` |
| No character, or the first is not of kind `player` | `characters.zon: the first character must be the player` |
| The `room` of the first character is more than 63, or `.outside` | `characters.zon: the player must start in a room from 0 to 63` |
| The root is not a struct literal | `characters.zon: expected a struct` |
| The file is not valid ZON, for example two characters have the same name | `characters.zon: not valid ZON` |
| A field is not in the list of fields | `CHAR: unknown field F` |
| A necessary field is absent | `CHAR: missing F` |
| `kind`, `behavior`, `start`, `facing`, `minimum_difficulty` or `sprite_library` is not a name | `CHAR: F must be a name` |
| No behavior file has that name | `CHAR: unknown behavior B` |
| The kind name is not known | `CHAR: unknown kind K` |
| The behavior has no state with that name | `CHAR: unknown start state S` |
| An integer field is not an integer, or is out of the range of its type | `CHAR: F out of range` |
| `x` or `y` is out of -4096 to 4096 | `CHAR: F must lie within -4096 and 4096` |
| A boolean field is not `true` or `false` | `CHAR: F must be true or false` |
| `facing`, `sprite_library` or `minimum_difficulty` has an unknown name | `CHAR: F cannot be V` |
| `minimum_difficulty` is an integer that is not 3 to 255 | `CHAR: minimum_difficulty out of range` |
| `width` is more than 16 | `CHAR: width W; a footprint covers at most 16 columns` |
| `label` is not a string | `CHAR: label must be a string` |
| `room` is a name that is not `outside` | `CHAR: room must be a number or .outside` |
| `links` or `numbers` is not a struct literal | `CHAR: expected a struct` |
| The behavior has no link with that name | `CHAR: behavior has no link L` |
| The value of a link is not a name | `CHAR: link L must name a character` |
| No character has the name of a link value | `CHAR: unknown character C` |
| A number is not an integer from -4096 to 4096 | `CHAR: number N must lie within -4096 and 4096` |
| The behavior has no number with that name | `CHAR: behavior has no number N` |
| At level start, a byte of a label has no glyph | `CHAR's label: the font has no character B` |

## Quirks

- When a `player` character crosses into a new room, the characters of the rooms above and below
  can also wake. There, the original's height limits apply (y 48 and y 176), and enemies do not
  wake.
- A character that the difficulty does not place keeps its flags from the previous level. If
  that level left it awake, messages reach it, but nothing updates it. If not, a message can wake
  it, and the engine then updates it.

## Sources

- `src/extract/level.zig`: `writeCharacters`, `writeParameters`, `characterId`,
  `classifyParameters`.
- `src/extract/placement.zig`: the placement record. `src/extract/codes.zig`: `kindName`.
  `src/extract/zon.zig`: `sanitize`.
- `src/shared/behavior/data_set.zig`: `Character`, `parseCharacter`, `bindLinks`,
  `bindNumbers`, `character_fields`.
- `src/shared/behavior/vocabulary.zig`: `Kind`.
- `src/shared/behavior/world.zig`: `World.init`, `buildContacts`, `followConrad`, `send`.
- `src/shared/behavior/original_memory.zig`: the fields that only the copied memory reads.
- `src/shared/scenes/level.zig` and `src/shared/scenes/level_screen.zig`: labels, icons, the
  quantity flag, the palette and the sprite libraries.
- flashback-re `docs/rules/engine-level.md`, section 1.3 to 1.5: the start of the records.
