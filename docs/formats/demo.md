# Demo file (`DATA/*.BIN`, with descriptors in `FB.EXE`)

A demo file holds the input of Conrad for each update of a recorded game. A descriptor in
`FB.EXE` gives the file name, the level and the start position. The title menu plays the three
demos in turn.

| Item | Value |
| --- | --- |
| Files | Three files in `DATA/`, 2,048 bytes each. The descriptors in `FB.EXE` give their names. On the supplied disks, they are in an [ABA archive](aba-archive.md). |
| Byte order | Little-endian (the descriptors). The demo file holds single bytes. |
| Reader | `src/shared/content/demo.zig` (`load`, `decode`). The descriptors: `src/shared/content/floppy_interface.zig`. The playback: `src/shared/scenes/level.zig`. |
| Writer | None |

## Layout

### Descriptors

The descriptors are two tables in the data segment of `FB.EXE` ([executable.md](executable.md)).
The table at offset 4064 (`0xfe0`) has 3 records of 4 bytes:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | A pointer to the file name in the data segment. The name has at most 11 characters and a 0 byte at its end. |
| 2 | 2 | `u16` | The level, 0-6: jungle, city, tower, earth_city, spaceport, alien_surface, alien_base. |

The table at offset 4076 (`0xfec`) has 3 records of 8 bytes:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `i16` | The start room, 0-63. A negative value: Conrad starts at the start position of the level. |
| 2 | 2 | `i16` | The start x. |
| 4 | 2 | `i16` | The start y. |
| 6 | 2 | - | Unknown. The reader ignores it. |

Record i of each table is for demo i.

### Demo file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2,047 | `u8` | The input bytes, one for each read. |
| 2,047 | 1 | `u8` | The end byte. The reader ignores it. |

An input byte has one bit for each control:

| Bit | Mask | Control |
| --- | --- | --- |
| 0 | `0x01` | Up |
| 1 | `0x02` | Down |
| 2 | `0x04` | Left |
| 3 | `0x08` | Right |
| 4 | `0x10` | Use (Return) |
| 5 | `0x20` | Gun (Space) |
| 6 | `0x40` | Action (Shift) |
| 7 | `0x80` | Inventory (Tab) |

## Procedures

### Play a demo

1. Read the descriptor of the demo. Read the file `DATA/NAME`, where NAME is the file name. The
   names compare without case ([floppy-image.md](floppy-image.md#asset-names)).
2. Load the level of the descriptor at the normal difficulty, with a fixed random state.
3. If the start room is not negative, put Conrad in that room at (x, y). Do not play the start
   scene of the level.
4. Do not show the code notice.
5. For each update, read the next input byte in place of the keys.
6. While a world message or the inventory is open, read the next byte at each poll.
7. When the game needs a byte after the last input byte, stop the demo.

Before an update, the game removes a diagonal from the byte, as it does for the keys. The player
stops a demo with Escape or the inventory key. The title menu plays demos 0, 1 and 2, then the
introduction, then starts again.

## Checks

| Condition | Error |
| --- | --- |
| The demo index is 3 or more. | `InvalidDemoIndex` |
| The reader of `FB.EXE` refuses the file. | See [executable.md](executable.md#checks). |
| A descriptor has a level of 7 or more. | `InvalidDemoLevel` |
| A file name has no 0 in 12 bytes. | `InvalidDemoFilename` |
| A start room is 64 or more. | `InvalidDemoRoom` |
| The demo file is absent. | `NotFound` |
| The demo file has more than 2,048 bytes. | `TooLarge` |
| The demo file has less than 2,048 bytes. | `InvalidDemoLength` |

## Quirks

The original tests for the end of the demo after it moves to the next byte, and before it
uses the byte. Thus the last byte never gets to the game: a demo has 2,047 inputs.

## Sources

- `src/shared/content/demo.zig`: the reader of the demo file.
- `src/shared/content/floppy_interface.zig`: the reader of the descriptors.
- `src/shared/scenes/level.zig`: `loadDemo`, `input`, `pollMessage` and the inventory poll.
- `src/shared/input.zig`: the bits of the input byte.
- `src/shared/game.zig`: the order of the demos.
- flashback-re `docs/floppy-demo.md`: the descriptors, the file size, the bits and the last byte.
