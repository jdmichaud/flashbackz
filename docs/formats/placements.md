# Placements (`LEVELn.PGE`)

A placement file lists the characters of one level: Conrad, the enemies, the objects and the
devices. Each record gives the start state, the position, the rule group, the links and the flags
of a character. The extractor converts the records into `characters.zon` of the data set
([characters.md](characters.md)).

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.PGE`, `LEVEL2.PGE`, `LEVEL3.PGE`, `LEVEL4_1.PGE`, `LEVEL4_2.PGE`, `LEVEL5_1.PGE` and `LEVEL5_2.PGE`: one file for each level. |
| Byte order | Little-endian. |
| Reader | `placement.Table` in `src/extract/placement.zig`. `extractAll` in `src/extract/root.zig` reads the file, and `level.extract` in `src/extract/level.zig` uses the records. The game does not read the file: it reads the data set. |
| Writer | None: the files come from the original game. |

## Layout

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | `count`: the number of records, at most 256. |
| 2 | 32 × `count` | records | The records. Record `i` is placement `i`. |

The file has no other bytes. Placement 0 is Conrad. The engine updates the characters in the
order of the records.

### Record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The start state: a state of the rule group, and the number of its animation ([animations.md](animations.md)). Data set: `start`. |
| 2 | 2 | `i16` | `x`, in pixels. Data set: `position`. |
| 4 | 2 | `i16` | `y`, in pixels. Data set: `position`. |
| 6 | 2 | `u16` | The rule group: an entry of the OBJ directory ([rule-groups.md](rule-groups.md)). Data set: `behavior`. |
| 8 | 2 | `i16` | The health at the start. Data set: `health`. |
| 10 | 8 | `i16[4]` | The parameters 0 to 3: links to other placements, or numbers. The rule group gives the use of each parameter. Data set: `links` and `numbers`. |
| 18 | 1 | `u8` | The kind (see below). Data set: `kind`. |
| 19 | 1 | `u8` | The room, from 0 to 63. The value 64 tells that the character is in no room. Data set: `room`. |
| 20 | 1 | `u8` | Not 0: the character is active at the start. Data set: `active`. |
| 21 | 1 | `u8` | The visual flags (see below). |
| 22 | 1 | `u8` | The contact icon. Data set: `contact_icon`. |
| 23 | 1 | `u8` | The inventory icon: an icon of `GLOBAL.ICN` ([icons.md](icons.md)). Data set: `inventory_icon`. |
| 24 | 1 | `u8` | The object number. Data set: `object`. |
| 25 | 1 | `u8` | The minimum difficulty: 0 easy, 1 normal, 2 expert. A larger value tells that the game never places the character. Data set: `minimum_difficulty`. |
| 26 | 1 | `u8` | Not 0: the character faces right at the start. Data set: `facing`. |
| 27 | 1 | `u8` | The wake flags (see below). |
| 28 | 1 | `u8` | The width: the number of cells that the character covers, for contacts and terrain changes. Data set: `width`. |
| 29 | 1 | `u8` | Unknown. The extractor keeps the value. Data set: `unknown_byte_29`. |
| 30 | 2 | `u16` | The label number: an entry of the label file ([labels.md](labels.md)). Data set: `label_number` and `label`. |

### Kind

| Value | Name in the data set |
| --- | --- |
| 1 | `player` (Conrad) |
| 3 | `interactive` |
| 10 | `enemy` |
| 11 | `overlay` |
| Another value `N` | `kind_N` |

An enemy starts with double health at the expert difficulty.

### Visual flags (byte 21)

| Bit | Mask | Description | Data set field |
| --- | --- | --- | --- |
| 0 to 1 | 0x03 | The colors. For composed object art, the room bank 0 to 3. For a sprite, the value 3 selects the colors at 0x50, and the other values the colors at 0x40. | `palette_bank` |
| 2 | 0x04 | The inventory shows the health of the item as a quantity. | `other_visual_flags` |
| 3 | 0x08 | The engine draws the character behind Conrad and the other characters. | `behind_player` |
| 4 to 7 | 0xf0 | Unknown. The extractor keeps the bits. | `other_visual_flags` |

### Wake flags (byte 27)

| Bit | Mask | Description | Data set field |
| --- | --- | --- | --- |
| 0 | 0x01 | A message wakes the character. | `wakes_on_message` |
| 1 | 0x02 | A contact wakes the character. | `wakes_on_contact` |
| 2 | 0x04 | The character wakes when it is in the view room or near it ([characters.md](characters.md)). | `wakes_when_near` |
| 3 to 7 | 0xf8 | Unknown. The extractor keeps the bits. The original files do not set them. | `other_flags` |

### Icons and objects

- **Contact icon.** When Conrad touches the character, the touch label can show icon
  `value - 1` of `GLOBAL.ICN` ([icons.md](icons.md)). A value of 0, or of 0x80 or more, shows no
  icon. `touching_pickup` (code 109) compares the contact icon with its argument.
- **Object number.** `selected_item_is` (code 50) and `player_has_item` (code 131) compare it with
  the low byte of their argument.

## Procedures

### Extract a level

1. Read `DATA/name.PGE`, where `name` is the file name of the level. The file must have at most
   16384 bytes.
2. Read `count`. Make sure that `count` is at most 256 and that the file has
   `2 + 32 * count` bytes.
3. Read the rule group of each record from the OBJ file ([rule-groups.md](rule-groups.md)).
4. Decide from the rules if each parameter is a link, a number, or both.
5. Write `characters.zon`, with one character for each record, in the order of the records.

The extractor writes a link as the name of the placement that it gives. A link value outside 0 to
`count - 1` becomes `.none`. A room above 63 becomes `.outside`. A minimum difficulty above 2
stays a number, with the comment "never placed".

## Checks

| Condition | Error |
| --- | --- |
| The file has more than 16384 bytes. | `error.TooLarge` |
| The file has fewer than 2 bytes, `count` is more than 256, or the file size is not `2 + 32 * count`. | `error.InvalidPlacementTable` |
| A rule group is not in the OBJ file. | The errors of [rule-groups.md](rule-groups.md). |

The extractor does not refuse these values. It writes a note in `report.txt`:

- A room above 64.
- A start state that no rule of the group names. The character then waits in that state.
- A label number that gives no valid label ([labels.md](labels.md#checks)). The character then
  has no label.

## Quirks

- **The sight scan reads the records.** The original keeps the records in memory in the order of
  the file. The leftward sight scan (`sees`, code 64) can continue into the bytes before the
  record of a character that it sees. It takes each byte below 0x80 as a contact slot.
  - A scan reads at most bytes 17 to 31 of a record.
  - The engine rebuilds bytes 0, 1 and 18 to 31 from the data set
    (`original_memory.placementByte`). Thus the data set keeps `other_flags`, `unknown_byte_29`
    and `label_number`.
  - The engine does not rebuild byte 17, the high byte of parameter 3. It counts a read of byte
    17 in `World.unmodeled_reads`.
  - The engine rebuilds bytes 20 and 26 as 0 or 1, and byte 19 as 64 for no room. A new file must
    use only these values, to give the scan the same bytes as the original.
  - Before record 0, the scan reads other game state. The engine models a part of it.
- **Characters that the difficulty leaves out.** The game does not place a record whose minimum
  difficulty is above the chosen difficulty. That character keeps the direction, the wake state,
  the mirror and the art kind of the character at the same index in the previous level.
- **Carriers 120 and 248.** `board_touching` (code 115) never finds a carrier at placement 120 or
  248. The original tests only the low byte of an address that it calculates from the index.

## Sources

- `src/extract/placement.zig`, `src/extract/level.zig` (`extract`, `writeCharacters` and
  `writeParameters`) and `src/extract/root.zig`.
- `src/shared/behavior/original_memory.zig`, `src/shared/behavior/operations/perception.zig`
  (`sees`), `src/shared/behavior/operations/carriers.zig` (`boardTouching`) and
  `src/shared/behavior/world.zig` (`init`).
- `src/shared/scenes/level_screen.zig` (the touch label) and `src/shared/scenes/level.zig` (the
  inventory quantity).
- flashback-re: `docs/rules/engine-level.md` (sections 1.3, 1.4 and 5) and `docs/rules/README.md`.
