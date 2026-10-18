# Saves (`QUICK`, `SAVE1` to `SAVE8`, `.INFO`)

A save holds a level in play as one ZON record: the session, the world and the play state of the
level. The session is the game in progress: the level, the difficulty, the score, and what passes
from one level to the next. The world is the state of the level that the engine keeps, for example
the characters and the terrain. A checkpoint is a copy of the characters, the score and the
terrain that the effect `checkpoint` makes. After a defeat, play can continue from the last
checkpoint. Beside each save, an INFO record holds what the pages of the save slots show. The game
writes the two records into the save directory and reads them back.

| Item | Value |
|---|---|
| Files | Save records: `QUICK`, `SAVE1` to `SAVE8`. INFO records: the same names with `.INFO` at the end. |
| Place | The save directory (see [Storage](#storage)). The [settings](settings.md) record is in the configuration directory. |
| Format | ZON text in ASCII, with a newline (`0x0a`) at the end. |
| Byte order | Not applicable: the records are text. |
| Reader | `src/shared/save.zig` (`decode`, `readSlot`, `restoreWorld`), `src/shared/game.zig` (`loadGame`, `slotList`) |
| Writer | `src/shared/save.zig` (`encode`, `encodeInfo`, `captureWorld`, `picture`), `src/shared/game.zig` (`saveGame`) |

## Slots

The options dialog is the dialog that Escape opens during play. Its SAVE GAME page and the LOAD
GAME page of the title menu show 9 rows. Row 0 is the quick slot. Row r is save slot r.

| Row | Save record | INFO record | Other access |
|---|---|---|---|
| 0 | `QUICK` | `QUICK.INFO` | In a level, F5 saves and F9 loads. |
| 1 to 8 | `SAVE1` to `SAVE8` | `SAVE1.INFO` to `SAVE8.INFO` | None. |

The agent host can save and load under any valid record name (see
[agent-output.md](agent-output.md)). A save needs a slot name of at most 59 characters. The INFO
record name has 5 more characters, and the name rules allow at most 64 (see [Storage](#storage)).

## Storage

The game keeps each record as one file. The file name is the record name.

The host finds the save directory in this order:

1. The `--saves DIR` option gives the directory.
2. On Windows, the directory is `%APPDATA%\flashbackz\saves`.
3. On other systems, the directory is `$XDG_DATA_HOME/flashbackz/saves` when `XDG_DATA_HOME` is
   set and not empty. Else it is `$HOME/.local/share/flashbackz/saves`.
4. The host creates the directory if necessary.

The end of `flashbackz --help` gives the directory of steps 2 and 3 for the current
environment.

When the necessary variable is missing or empty, the host stops with "no per-user directory here;
give --saves DIR and --config DIR". Without `--saves`, the agent host keeps its records in memory
only.

A record name has 1 to 64 ASCII characters: letters, digits, `.`, `_` and `-`. It must not start
or end with `.`, and it must not contain `..`. Its part before the first `.` must not be a Windows
device name: `CON`, `PRN`, `AUX`, `NUL`, `COM1` to `COM9` or `LPT1` to `LPT9`, in any case. The
storage refuses other names with `error.InvalidName`.

The storage replaces a record in these steps:

1. Write the bytes to a new temporary file `.NAME.HHHHHHHHHHHHHHHH.tmp` in the same directory.
   `NAME` is the record name, and `H` is a random hexadecimal digit.
2. Sync the file to the disk.
3. Rename the temporary file to `NAME`.
4. Sync the directory (not on Windows). A failure of this step does not stop the save.

A failure in steps 1 to 3 deletes the temporary file and keeps the old record. A file with a name
that starts with `.` is not a record.

## ZON notation

The records use ZON (Zig Object Notation). The writer uses `std.zon.stringify.serialize` with its
default options:

- A struct is `.{ .name = value, ... }`. A list is `.{ value, ... }`. An empty list is `.{}`.
- A struct or a list with more than two items has each item on its own line, with 4 spaces of
  indent for each level. A comma follows each item, the last item too.
- A struct or a list with one or two items stays on one line, for example
  `.{ .x = 1, .y = null }`. A list with one item has no spaces in its braces: `.{7}`. An item with
  more than two fields keeps its own lines, for example `.{.{` and `}}` around one struct.
- An integer is in decimal. A bool is `true` or `false`. An enum value is `.name`. An optional
  value is the value or `null`. A string is in double quotes.
- A hex string holds two hexadecimal digits for each byte, first byte first. The writer writes
  lower-case digits. The reader also reads upper-case digits, but not in `data_set`.

The reader (`std.zon.parse.fromSlice`) accepts the fields in any order, with any white space. It
refuses an unknown field. It refuses a missing field, unless the tables give a default for it.
It refuses a value that is not of the type of the field, or that is out of the range of the type.

A synthetic INFO record, with the picture cut short:

```zon
.{
    .version = 2,
    .data_set = "00000000000000ff",
    .level = .city,
    .play_walks = 3505,
    .date = "2026-10-10 14:32",
    .picture = "070707070707",
}
```

## Save record

In the tables, "Default" is the value that the reader uses for a missing field. A dash means that
the field must be present.

### Record

| Field | Type | Default | Content |
|---|---|---|---|
| `version` | u32 | - | The format version. It must be 2. |
| `data_set` | string | - | The fingerprint of the data set, in 16 lower-case hexadecimal digits (see [Fingerprint](#fingerprint)). |
| `level` | enum | - | `jungle`, `city`, `tower`, `earth_city`, `spaceport`, `alien_surface` or `alien_base`. |
| `difficulty` | enum | - | `easy`, `normal` or `expert`. |
| `play_walks` | u64 | - | The walks of this game, the walks of this level included. The play time comes from it. |
| `inherited` | list of 256 Inherited | - | By character index: the flags that a character keeps from the levels before, when a level does not place it. |
| `scene` | Scene | - | The play state of the level outside the world. |
| `world` | World | - | The world of the level. |

### Inherited

| Field | Type | Default | Content |
|---|---|---|---|
| `facing_right` | bool | `false` | The character faces right. |
| `awake` | bool | `false` | The character counts as awake. |
| `mirrored` | bool | `false` | The look of the character is mirrored. |
| `composed` | bool | `false` | The look of the character is object artwork in parts. |

### Scene

| Field | Type | Default | Content |
|---|---|---|---|
| `last_direction` | u8 | - | The last input byte without a diagonal. An input with a diagonal uses its bits 0 to 3. |
| `inventory_delay` | u8 | - | The pictures that the level presents before the inventory key works. |
| `catch_up_due` | bool | - | The last host frame ended late: the next host frame runs two updates. |
| `requested_scene` | ?i16 | - | The scene that the last update requested. It plays at the start of the next update. |

### World

| Field | Type | Default | Content |
|---|---|---|---|
| `characters` | list of Character | - | One item for each character of the level, in the order of the data set ([characters.md](characters.md)). |
| `room_lists` | list of 256 ?u16 | - | By room value: the first character in the list of that room. |
| `contacts` | Contacts | - | The contact registrations of the last update. |
| `letters` | list of 256 Letter | - | The message pool. A letter is one sent message that waits in the pool. |
| `free_letter` | ?u16 | - | The first free letter of the pool. |
| `inbox` | list of ?u16 | - | One item for each character: the first letter that waits for it. |
| `random` | u32 | - | The state of the random generator. |
| `controls` | u8 | - | The controls of the last walk. Bits 0 to 7: up, down, left, right, enter, space, shift, inventory. |
| `view_room` | u8 | - | The view room ([animations.md](animations.md)). |
| `view_dirty` | bool | - | The view must go to the room of Conrad after the update. |
| `room_loads` | u32 | - | The count of loads of the view room. |
| `checkpoint_saves` | u32 | - | The count of checkpoint saves. |
| `score` | u32 | - | The score. |
| `entry_score` | u32 | - | The score at the start of the level. |
| `protection` | u8 | - | The updates that remain in the protection of Conrad after a hit. |
| `hurt` | bool | - | Conrad is hurt. The protection starts at his next check for hits. |
| `defeat_countdown` | i16 | - | The walks that remain before the defeat scene. 0: no countdown. A walk counts it down only when bits 0 to 7 are not 0. |
| `defeat_scene` | i16 | - | The scene that plays when the countdown stops at 0. |
| `weapon_mode` | i16 | - | The value that the rules set with `set_weapon_mode` and test with `weapon_mode_is`. |
| `shake` | i8 | - | The vertical shake offset of the view, -1 to 2. |
| `grid` | hex string, 7424 bytes | - | The collision layout of the level with its terrain changes ([collision.md](collision.md)). |
| `terrain` | Terrain | - | The terrain changes. |
| `checkpoint` | ?Checkpoint | - | The last checkpoint of the level, or `null`. |

### Character

| Field | Type | Default | Content |
|---|---|---|---|
| `state` | u16 | - | The index of the state in the behavior of the character ([behaviors.md](behaviors.md)). |
| `cursor` | u8 | 0 | The frames of the current animation that played. |
| `x` | i16 | - | The horizontal position. |
| `y` | i16 | - | The vertical position. |
| `room` | u8 | - | The room: 0 to 63, or 64 (outside), 254 (`0xfe`, removed), 255 (`0xff`, carried). |
| `health` | i16 | - | The health. |
| `counter` | i16 | 0 | The timer: `set_timer` sets it, and `timer_reaches` counts it down. |
| `facing_right` | bool | - | The character faces right. |
| `active` | bool | `false` | The character is awake: the walk updates it. |
| `present` | bool | - | The level places the character at this difficulty. Other characters never go into a room. |
| `contact` | u8 | 255 | The first contact slot of the last registration. 255 (`0xff`): none. |
| `owner` | ?u16 | `null` | Inventory: the character that carries this item. |
| `first_item` | ?u16 | `null` | Inventory: the first item, which is the selected item. |
| `next_item` | ?u16 | `null` | Inventory: the next item of the same owner. |
| `next_in_room` | ?u16 | `null` | The next character in the list of the same room. |
| `look` | Look | all defaults | What the character shows. |
| `stale_awake` | bool | `false` | The previous level left this unplaced character awake. It counts as awake, but the walk does not update it. |

### Look

| Field | Type | Default | Content |
|---|---|---|---|
| `sprite` | u15 (0 to 32767) | 0 | The sprite of the last frame ([sprites.md](sprites.md)). |
| `mirrored` | bool | `false` | The sprite is mirrored. |
| `composed` | bool | `false` | The look is object artwork in parts ([object-art.md](object-art.md)). |

### Contacts

| Field | Type | Default | Content |
|---|---|---|---|
| `entries` | list of 256 Entry | - | The registered cells. |
| `entry_count` | u16 | - | The entries in use. |
| `slots` | list of 256 ?u16 | - | For each slot: its newest entry. |
| `slot_count` | u8 | - | The slots in use. The slots after this count keep older contents. |
| `window` | hex string, 144 bytes | - | The slots of the cells near the view (see below). |

The `window` holds 3 groups of 48 bytes. Bytes 0 to 47 are for the left neighbor of the view
room. Bytes 48 to 95 are for the view room, and bytes 96 to 143 for its right neighbor. In each
group, byte tier × 16 + column holds the slot of that cell, or `0xff` for none.

### Entry

| Field | Type | Default | Content |
|---|---|---|---|
| `key` | u16 | 0 | The cell: room × 64 + tier × 16 + column. |
| `next` | ?u16 | `null` | The next entry in the same slot. |
| `character` | u16 | 0 | The index of the character. |
| `next_slot` | ?u8 | `null` | The next slot of the same character. |

### Letter

| Field | Type | Default | Content |
|---|---|---|---|
| `sender` | u16 | - | The index of the character that sent the message. |
| `message` | u16 | - | The message number. |
| `next` | ?u16 | - | The next letter in the same list. |

### Terrain

| Field | Type | Default | Content |
|---|---|---|---|
| `changes` | list of 0 to 254 Change | - | The terrain changes, oldest first. |
| `used_words` | u16 | - | The words in use in the pool of the original (762 words). |
| `saved` | hex string, 0 to 1784 bytes | - | The cells that the changes replaced. |

### Change

| Field | Type | Default | Content |
|---|---|---|---|
| `start` | i32 | - | The first cell, as an index into `grid`. |
| `width` | u8 | - | The cells that a restore puts back. |
| `saved_from` | u16 | - | The first byte of the change in `saved`. |
| `saved_count` | u8 | - | The bytes of the change in `saved`. |

### Checkpoint

| Field | Type | Default | Content |
|---|---|---|---|
| `characters` | list of Character | - | The characters at the checkpoint, one for each character of the level. |
| `score` | u32 | - | The score at the checkpoint. |
| `grid` | hex string, 7424 bytes | - | The collision layout at the checkpoint. |
| `terrain` | Terrain | - | The terrain changes at the checkpoint. |

## INFO record

All the fields must be present.

| Field | Type | Content |
|---|---|---|
| `version` | u32 | The format version. It must be 2. |
| `data_set` | string | The fingerprint, as in the save record. |
| `level` | enum | The level, as in the save record. |
| `play_walks` | u64 | The walks, as in the save record. |
| `date` | string | The local date and time of the save as `YYYY-MM-DD HH:MM`. Empty when the host does not give the time (the agent host). |
| `picture` | hex string, 10752 bytes | The picture of the save: 64 × 56 pixels, rows from the top, 3 bytes (R, G, B) for each pixel. |

## Procedures

### Fingerprint

1. Take all the `.zon` files of the data set ([data-set.md](data-set.md)). The name of a file is
   its path in the data set directory, with `/` between the parts.
2. Sort the files by name, byte by byte, in ascending order.
3. For each file, append its name, a `0x00` byte, its contents and a `0x00` byte.
4. Hash the result with Wyhash (Zig `std.hash.Wyhash`), seed 0.
5. Write the 64-bit hash as 16 lower-case hexadecimal digits, with zeros on the left as necessary.

A data set from `--data` and a data set that the host extracts in memory have the same
fingerprint when they have the same files. The order in which the host lists the files does not
change the fingerprint.

### Picture

1. Take the level picture at the save: 256 × 224 palette indices, without the options dialog or
   the inventory.
2. For each pixel (x, y) of the save picture, take the 4 × 4 block at (4x, 4y).
3. For each of R, G and B, add the palette values (0 to 255) of the 16 pixels.
4. Divide each sum by 16, and discard the remainder.
5. Write the pixels row by row, from the top, as R, G and B.

The slot pages show the picture at (16, 158) of the 256 × 224 page.

### Play time

The slot pages show the play time as `H:MM:SS`. The time in seconds is
`play_walks × 2 × 17024 / 1193182`, rounded down: a walk takes two ticks of the timer of the
original.

### Save

The game saves only a level in play. It does not save during a film, a demo, the inventory or a
message. A save with the options dialog open is possible. The game also needs the storage and
the data set. Else the save gives `error.NothingToSave`, `error.NoStorage` or
`error.DataSetRequired`.

1. Make the INFO record name: the slot name with `.INFO` at the end. If it has more than 64
   characters, stop with `error.InvalidName`.
2. Write the save record under the slot name.
3. Make the picture and the date.
4. Write the INFO record under the INFO record name.
5. Read the slot list again when a slot page needs it.

If step 1 or 2 fails, the old records stay. If step 4 fails, the new save record stays with the
old INFO record, or with none.

### Load

The game needs the storage, the data set and the original files.

1. Read the save record. F9 does nothing when `QUICK` is missing.
2. Read the `version` field only. The reader ignores the other fields in this step.
3. Read the full record.
4. Compare `data_set` with the fingerprint of the data set in use.
5. Load the level again from the data set, at the difficulty of the record and with the
   `inherited` flags.
6. Put back the world (`restoreWorld`) and the play state (`scene`).
7. Stop the screen in play. The loaded level takes its place, with the level, the difficulty and
   the play walks of the record.

If a step fails, the screen in play continues. F9 and the agent host do not read the INFO record.

### Slot list

For each row, the game reads the INFO record and gives the row one of these states. The first
condition that applies gives the state.

| INFO record | State | Row | On the LOAD GAME page |
|---|---|---|---|
| Missing, or no storage | empty | `- EMPTY -` | Nothing occurs. |
| Other read error, or no `version` field that reads | broken | `UNREADABLE` | Refused: `IT DOES NOT READ`. |
| `version` is not 2 | other version | `OTHER VERSION` | Refused: `ANOTHER VERSION`. |
| The full record does not read (see [ZON notation](#zon-notation)) | broken | `UNREADABLE` | Refused: `IT DOES NOT READ`. |
| `data_set` is not the fingerprint in use | save, not loadable | The level and the play time | Refused: `OTHER GAME DATA`. |
| Else | save | The level and the play time | The game loads the save record. |

Without a data set, the fingerprint in use is `0000000000000000`. The page shows the picture only
when `picture` has exactly 21504 valid hexadecimal digits. On the SAVE GAME page, the game saves
into an empty row at once. For another row, it asks first. The LOAD GAME page shows a save
without its INFO record as empty.

## Checks

A load of a save record refuses these conditions:

| Condition | Error |
|---|---|
| The game has no storage. | `error.NoStorage` |
| The game has no data set. | `error.DataSetRequired` |
| The game has no original files. | `error.OriginalContentRequired` |
| The storage cannot read the record. | `error.Io` |
| The record is not valid ZON, a field is missing or unknown, or a value has a wrong type or range. | `error.InvalidSave` |
| `version` is not 2. | `error.OtherVersion` |
| `data_set` is not the fingerprint of the data set in use. | `error.OtherDataSet` |
| `inherited` does not have 256 items. | `error.InvalidSave` |
| `characters` or `inbox` does not have one item for each character of the level. | `error.InvalidSave` |
| `room_lists`, `letters`, `contacts.entries` or `contacts.slots` does not have 256 items. | `error.InvalidSave` |
| `grid` or `checkpoint.grid` does not have 14848 digits, or `contacts.window` does not have 288 digits. | `error.InvalidSave` |
| `terrain.saved` (also in `checkpoint`) has an odd count of digits or more than 3568 digits. | `error.InvalidSave` |
| A hex string has a character that is not a hexadecimal digit. | `error.InvalidSave` |
| `terrain.changes` (also in `checkpoint`) has more than 254 items. | `error.InvalidSave` |
| `checkpoint.characters` does not have one item for each character of the level. | `error.InvalidSave` |
| A `state` (also in `checkpoint`) is not a state of the behavior of its character. | `error.InvalidSave` |
| A character link is not `null` and not less than the count of characters: `owner`, `first_item`, `next_item`, `next_in_room` (also in `checkpoint`), an item of `room_lists`, the `character` of an entry or the `sender` of a letter. | `error.InvalidSave` |
| `contacts.entry_count` is more than 256, or a contact link is 256 or more: the `next` of an entry or an item of `contacts.slots`. | `error.InvalidSave` |
| A letter link is 256 or more: the `next` of a letter, `free_letter` or an item of `inbox`. | `error.InvalidSave` |
| A change in `terrain` (also in `checkpoint`) has saved bytes past the end of `saved`. | `error.InvalidSave` |
| `terrain.used_words` (also in `checkpoint`) is less than 3 × the count of changes, or less than half the count of bytes in `saved`. | `error.InvalidSave` |
| The record name breaks the name rules. | `error.InvalidName` |
| The record is missing. | `error.NotFound` |

The game never writes a value outside these ranges. An edited record can, and the engine trusts
the values that it loads. The reader does not check the other values, for example `room` or
`view_room`. A writer must keep each value in the range that the engine uses.

The reader refuses a record of another version. It does not convert it.

## Sources

- `src/shared/save.zig`, `src/shared/game.zig` (`saveGame`, `loadGame`, `slotList`,
  `quickKey`), `src/shared/scenes/save_slots.zig`, `src/shared/scenes/level.zig` (`canSave`,
  `saveState`, `restoreState`, `playPicture`).
- `src/shared/behavior/world.zig`, `src/shared/behavior/contacts.zig`,
  `src/shared/content/collision.zig`.
- `src/native/storage.zig`, `src/native/cli.zig` (`defaultSaveDirectory`),
  `src/native/data_set.zig`, `src/shared/platform.zig` (`validateName`).
- DESIGN.md, section 4 (Saves).
- flashback-re: `docs/rules/engine-level.md` 3.3 (the checkpoint), `docs/rules/codes-034-072.md`
  54 and 55, and `docs/terrain-port-map.md` (the terrain changes).
