# Data set (`messages.zon`, `scenes.zon`, `report.txt`, level directories)

The data set is the readable form of the game's characters, behavior tables, world messages and
scenes. The extractor makes it from the user's disks. The game loads it together with the
original images and sounds, which it always reads from the disks.

| Item | Value |
| --- | --- |
| Files | `messages.zon`, `scenes.zon`, `report.txt`; for each level, `<level>/characters.zon` and `<level>/behaviors/<name>.zon` |
| Format | ASCII text in ZON (Zig object notation). Byte order does not apply. |
| Reader | `src/shared/behavior/data_set.zig`. `src/native/data_set.zig` (`readDirectory`) finds the files. |
| Writer | The extractor: `src/extract/root.zig`, `src/extract/level.zig`, `src/extract/zon.zig`. `src/native/data_set.zig` (`writeDirectory`, `extractInMemory`) gives it a sink. |

The data set holds the user's game content. It must stay out of Git.

## Layout

### Directory

```text
DIR/
    messages.zon
    scenes.zon
    report.txt
    jungle/
        characters.zon
        behaviors/
            conrad.zon
            behavior_12.zon
            ...
    city/
    ...
```

| Path | Content | Specification |
| --- | --- | --- |
| `<level>/characters.zon` | Every placement of the level | [characters.md](characters.md) |
| `<level>/behaviors/<name>.zon` | One behavior table. `<name>` is the behavior name. The reader reads only the files directly in `behaviors/`. | [behaviors.md](behaviors.md) |
| `messages.zon` | The world messages | This document |
| `scenes.zon` | The film of each scene, the opening scene of each level, and the ending | This document |
| `report.txt` | The extraction report. No code reads it. | This document |

Each level has one directory. The extractor reads the placements, the rule groups and the labels
of a level from three files of the disks: `.PGE` ([placements.md](placements.md)), `.OBJ`
([rule-groups.md](rule-groups.md)) and `.TBN` ([labels.md](labels.md)).

| Directory | Original files |
| --- | --- |
| `jungle` | `DATA/LEVEL1.PGE`, `.OBJ`, `.TBN` |
| `city` | `DATA/LEVEL2.PGE`, `.OBJ`, `.TBN` |
| `tower` | `DATA/LEVEL3.PGE`, `.OBJ`, `.TBN` |
| `earth_city` | `DATA/LEVEL4_1.PGE`, `.OBJ`, `.TBN` |
| `spaceport` | `DATA/LEVEL4_2.PGE`, `.OBJ`, `.TBN` |
| `alien_surface` | `DATA/LEVEL5_1.PGE`, `.OBJ`, `.TBN` |
| `alien_base` | `DATA/LEVEL5_2.PGE`, `.OBJ`, `.TBN` |

The extractor also reads tables of the game executable ([executable.md](executable.md)): the
world messages ([world-messages.md](world-messages.md)), the scene table, the ending list, the
credits, the score awards and the enemy sprite libraries. The supported edition
gives 7 character files, 418 behavior files and 1097 characters.

### The ZON that the writer writes

- ASCII only. In a string, a byte outside 0x20 to 0x7e becomes `\xNN` (two lowercase
  hexadecimal digits). `"`, `\` and the line feed become `\"`, `\\` and `\n`.
- Each `.zon` file starts with two `//` comment lines. The first line is `// Generated with
  --extract from the user's game files. Do not commit.` The second line tells what the file
  holds.
- Each field or element is on its own line, with 4 spaces of indent for each level and a comma
  at the end. Short literals stay on one line: `when`, `then`, `position`, the `links` and
  `numbers` of a behavior file, a line of a message, a film and a credit step.
- The values are decimal integers (with `-` when negative), strings, `true`, `false`, `null`,
  enum literals (`.name`), and anonymous struct and list literals (`.{ ... }`).
- A name is `.name` when it is a plain identifier. A plain identifier has only letters, digits
  and `_`, and does not start with a digit. It is not a Zig keyword or primitive type name
  (`type`, `u8`). Other names are `.@"name"`.
- Comments give more data. `// ordinal N` follows the name of a state. `// message N` is a line
  before each message. `// scene N` follows each film. `// never placed` follows an integer
  `minimum_difficulty`. A link that is `.none` has the original value in a comment.

### The ZON that the reader accepts

- The reader accepts all text that the Zig 0.17.0 standard library parses as ZON with no error.
  It accepts comments and white space at all positions that ZON permits.
- A struct literal with the same field name two times is not valid ZON.
- In `characters.zon` and the behavior files, a number must be an integer literal, in any base
  that Zig accepts (`0x10`, `1_000`). There, the reader refuses a float or a character literal
  (`'a'`).
- `messages.zon` and `scenes.zon` must match fixed types (`std.zon.parse`). The reader refuses
  an unknown field. Each field with no default value must be present. For a number, these files
  also accept a character literal and a float with no fraction (`232.0`).
- The reader reads `characters.zon` and the behavior files field by field. Their documents give
  the rules.

### `messages.zon`

The root is a list. Element N is world message N: the number that the effect `show_message`
gives.

| Level | Type | Content |
| --- | --- | --- |
| Root | List of world messages | One world message for each number, from 0 |
| World message | List of pages | The pages show one after the other |
| Page | List of lines | The lines, from the top |
| Line | `.{ .text = ..., .ink = ... }` | One line of text |

| Field | Type | Content |
| --- | --- | --- |
| `text` | String | The glyph codes of the line, one byte for each glyph of the game font ([font.md](font.md)) |
| `ink` | `u8` | The text color of the line. The extractor writes 232 (0xe8) where the original sets no text color. |

A world message with no pages shows nothing. A number past the end of the list shows nothing.

```zon
// Generated with --extract from the user's game files. Do not commit.
// The world messages, by number: each is a list of pages, and each page a list
// of lines, each with its text color (ink).
.{
    // message 0
    .{
        .{
            .{ .text = "FIRST LINE", .ink = 232 },
            .{ .text = "SECOND LINE", .ink = 232 },
        },
    },
}
```

### `scenes.zon`

The root is a struct literal with three fields. All three are necessary.

| Field | Type | Content |
| --- | --- | --- |
| `openings` | Struct | For each level directory name, the scene that the level asks for when it starts, or `null`. A demo plays no opening scene ([demo.md](demo.md)). |
| `films` | List of film or `null` | Element N is the film of scene N: the number that `play_scene` gives. `null`, or a number past the end of the list: the scene plays no film. A request for scene 61 in a level starts the ending. |
| `ending` | Struct | The scenes and the credits of the ending |

`openings` has the fields `jungle`, `city`, `tower`, `earth_city`, `spaceport`,
`alien_surface` and `alien_base`. Each is a `u8` or `null`, and each must be present.

A film is a struct literal:

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `film` | String | Necessary | The base name of the film files ([vector-films.md](vector-films.md)) |
| `entry` | `u8` | Necessary | The entry of the film to play |
| `music` | String | `null` | The music file that plays with the film, in upper case ([music.md](music.md)) |
| `flagged` | Boolean | `false` | The original sets it on one scene. The reader ignores it. |

`ending` has two fields:

| Field | Type | Content |
| --- | --- | --- |
| `scenes` | List of `u8` | The scenes that the ending plays, in order, after its first film (the film of scene 61) |
| `credits` | List of credit steps | The credits that the game types over these scenes |

| Credit step | Content |
| --- | --- |
| `.{ .text = "..." }` | Text, typed one character for each presented frame. `\|` starts a new line. The text must not be empty. |
| `.{ .hold = N }` | Keep the picture for N timer ticks (`u8`). |
| `.{ .at = .{ .column = C, .row = R } }` | Move the text to column C and row R, in units of 8 pixels (`u8` each). |
| `.block_end` | The end of a block of credits. |

The extractor writes one element of `films` for each scene of the executable's scene table, with
a `// scene N` comment.

```zon
// Generated with --extract from the user's game files. Do not commit.
// A scene is a numbered request for a film: a level makes one when it starts,
// and a rule makes one with play_scene. The sections:
// - openings: the scene of each level when it starts (null: none).
// - films: the film of each scene, by number: its name, entry and music (null: none).
// - ending: the scenes that the ending plays after scene 61, and its credits.
.{
    .openings = .{
        .jungle = 1,
        .city = null,
        .tower = null,
        .earth_city = null,
        .spaceport = null,
        .alien_surface = null,
        .alien_base = null,
    },
    .films = .{
        null, // scene 0
        .{ .film = "SAMPLE", .entry = 0, .music = "TUNE" }, // scene 1
    },
    .ending = .{
        .scenes = .{
            1,
        },
        .credits = .{
            .{ .at = .{ .column = 4, .row = 10 } },
            .{ .text = "A LINE|ANOTHER LINE" },
            .{ .hold = 50 },
            .block_end,
        },
    },
}
```

### `report.txt`

The report is plain text. `--extract` also prints it.

1. The first two lines: `Extracted C characters and B behaviors; the overlay names N
   behaviors and S of` and `the T states.`
2. The third line: `Dropped D unreachable rules; A operations had an argument the original
   ignores.`
3. One line for each note, in the order of the levels.

| Note | Unexpected | Cause |
| --- | --- | --- |
| `L: rule group G has K unreachable rules (dropped)` | No | Rules of a state after the first run of that state ([behaviors.md](behaviors.md)) |
| `L: placement P starts in state S, which no rule names` | Yes | The extractor adds a state with no rules |
| `L: placement P starts in room R` | No | A start room above 64. The extractor writes `.outside`. |
| `L: F uses parameter P both as a link and as a number` | No | One placement parameter is a link and a number of behavior F |
| `L: F uses unknown operation C` | Yes | The extractor writes `.{ .unknown_C = A }`, which the reader refuses |
| `L: F gives N the unexpected argument A` | Yes | The extractor writes `.{ .N_raw = A }`, which the reader refuses |
| `L: F has N where no first condition gives its kind` | Yes | N takes its kind from the first condition, but it is not the second condition ([rule-groups.md](rule-groups.md#arguments)). The extractor writes `.{ .N_raw = A }`, which the reader refuses |
| `L: placement P: label N does not read (ERROR)` | Yes | The labels file gives no valid label N ([labels.md](labels.md#checks)). The extractor writes no `label` |

An unexpected note is a note on data that the extractor does not understand. The supported edition
gives none.

## Procedures

### How the game gets the data set

1. With `--data DIR`, the game reads each `.zon` file under DIR, at all depths. A file must be
   smaller than 8 MiB. The name of a file is its path in DIR, with `/` separators. The game ignores
   all other files.
2. With no `--data`, the game extracts the data set in memory from the disks, with the built-in
   naming overlay ([naming-overlay.md](naming-overlay.md)). It keeps only the `.zon` files.
   When there are unexpected notes, it logs a warning with all the notes.
3. When the extraction in memory fails, the game logs `data set not extracted: ERROR` and starts
   with no data set. The screens that need no data set still run. A level, a demo or the ending
   cannot start.

`--extract DIR` writes the data set into DIR and prints the report. DIR must be a new or empty
directory. `--names FILE` replaces the built-in naming overlay; it is valid only with
`--extract`. The game refuses all other options with `--extract`.

### When the game reads the files

| Time | Files |
| --- | --- |
| The game starts, with a data set | `scenes.zon`. The game also imports each film that it names, one time for each film and entry. |
| A level or a demo starts | `<level>/characters.zon`, the `.zon` files directly in `<level>/behaviors/`, `messages.zon`, `scenes.zon` |
| The ending starts | `scenes.zon` |

The reader reads the behavior files of a level in the byte order of their names. This order gives
the same result from a directory and from memory.

## Checks

The reader stops at the first failure. The game logs `data set: TEXT` as an error. TEXT is one
of the texts below. A text of the reader has at most 256 bytes. [characters.md](characters.md) and
[behaviors.md](behaviors.md) give the checks of their files.

| Check | Text |
| --- | --- |
| The data set has no `messages.zon` | `the data set has no messages.zon` |
| `messages.zon` is not valid ZON or does not match its type | `messages.zon: not a list of pages of lines` |
| The data set has no `scenes.zon` | `the data set has no scenes.zon` |
| `scenes.zon` is not valid ZON or does not match its type | `scenes.zon: not openings and films` |
| A credit text is empty | `scenes.zon: a credit's text is empty` |
| The level has no `characters.zon` | `the data set has no <level>/characters.zon` |
| A level file is not valid ZON | `FILE: not valid ZON` |
| A character of a world message is not in the game font | `message N: the font has no character B` |
| Scene 61 and the scenes of `ending.scenes` have no film | `scenes.zon: no film for the ending (scene 61 and the scenes of ending)` |
| A character of the credits is not in the game font | `scenes.zon: the font has no character B of the credits` |

Other failures have other texts:

| Check | Text |
| --- | --- |
| At start, a film of `scenes.zon` cannot play | `scene N: film F entry E cannot play: ERROR` |
| The `--data` directory or one of its `.zon` files cannot be read | `PROGRAM: cannot open the data set DIR: not a data set written by --extract` |
| The `--extract` directory is not empty | `PROGRAM: DIR must be a new or empty directory` |
| The `--names` file cannot be read | `PROGRAM: cannot open the names file FILE: WHY`, with WHY `not found`, `permission denied` or `read error` |
| `--extract` fails for another cause | `PROGRAM: extraction failed: ERROR` |

The extraction stops with `DuplicateBehaviorFile` when two behaviors of a level get the same file
name ([naming-overlay.md](naming-overlay.md#how-the-extractor-applies-the-overlay)).

A save records the shape of its level: the characters in order, and the states of their
behaviors in order ([save.md](save.md#level-shape)). A character or a state added, removed or
moved in that level makes the game refuse its older saves. The comments, the names, the rules and
the other files do not.

## Sources

- `src/extract/root.zig`: the stages of the extraction, `scenes.zon`, `messages.zon`,
  `report.txt`.
- `src/extract/level.zig`: the level files and the notes.
- `src/extract/zon.zig`: the ZON writer, the quotes of names and strings.
- `src/shared/behavior/data_set.zig`: `loadLevel`, `loadMessages`, `loadScenes`, the
  diagnostics.
- `src/native/data_set.zig` and `src/native/cli.zig`: `--data`, `--extract`, `--names`.
- `src/shared/content_check.zig`, `src/shared/scenes/level.zig` (`checkContent`) and
  `src/shared/scenes/ending.zig`: the checks at start, at level start and at the ending.
- `src/shared/content/floppy_interface.zig`: the scene table, the ending list and the credits.
- `src/shared/save.zig` (`levelShape`, `LevelShapes`).
- DESIGN.md, section 3.
