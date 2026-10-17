# Level palettes (`LEVELn.PAL`)

A level PAL file holds the color banks of a level, with 16 colors in each bank. Each room selects
four banks for its four palette slots. The reader converts each color to 8-bit RGB.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.PAL` to `DATA/LEVEL5.PAL`, in `GLOB2_FB.ABA` on disk 2 |
| Byte order | Big-endian |
| Reader | `src/shared/content/palette.zig` (`decodeLevelBank`), called by `room_artwork.zig` and `level_pack.zig` (`loadRooms`) |
| Writer | None in flashbackz. The files come with the game. |
| Largest file | 8,192 bytes (256 banks) |

The levels use the same `LEVELn` names as the room files
([lev-rooms.md](lev-rooms.md#the-files-of-a-level)). The level reads its PAL file with each of the
two room forms: the LEV form and the installed MAP form ([map-rooms.md](map-rooms.md)). The menu
PAL files have a different layout ([menu-palette.md](menu-palette.md)).

## Layout

The file holds banks of 32 bytes, bank 0 first. Bank b starts at offset 32 x b. A bank holds 16
colors:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 2 x i | 2 | u16 | Color i of the bank, 0 to 15 |

A color:

| Bits | Content |
| --- | --- |
| 0-3 | The red value |
| 4-7 | The green value |
| 8-11 | The blue value |
| 12-15 | Not used, but the black test of the conversion includes them |

## Procedures

### Convert a color to 8-bit RGB

1. If the color word is `0x0000`, the color is black: (0, 0, 0). Stop.
2. For each of the red, green and blue values v, calculate the 6-bit value d = 4 x v + 3.
3. For each d, calculate the 8-bit component 4 x d + d / 16, with an integer division.

Synthetic examples:

| Word | Red | Green | Blue |
| --- | --- | --- | --- |
| `0x0000` | 0 | 0 | 0 |
| `0x0001` | 28 | 12 | 12 |
| `0x0f00` | 12 | 12 | 255 |

### Give a room its colors

A room has 256 colors. Its four bank numbers select the PAL banks of its palette slots 0 to 3. A
LEV room gives the bank numbers in its description
([lev-rooms.md](lev-rooms.md#the-room-description)). A MAP room gives them in the first 4 bytes
of its record ([map-rooms.md](map-rooms.md#a-room-record)).

The colors of a room:

| Colors | Content |
| --- | --- |
| `0x00`-`0x3f` | Slots 0 to 3: the bank of slot n at `0x10` x n |
| `0x40`-`0x4f` | The colors of Conrad, from the executable ([executable.md](executable.md)) |
| `0x50`-`0x5f` | The colors of the enemy sprite library, from the executable. The level screen sets them. |
| `0x60`-`0x7f` | Not set: black |
| `0x80`-`0x9f` | Slots 0 and 1 again, for the pixels in front of the sprites |
| `0xa0`-`0xaf` | The icon colors: the slot 2 bank of the first room |
| `0xb0`-`0xbf` | Slot 3 again, for the pixels in front of the sprites |
| `0xc0`-`0xdf` | The film colors ([vector-films.md](vector-films.md)). The room does not set them. |
| `0xe0`-`0xef` | The text colors, from the executable |
| `0xf0`-`0xff` | The interface colors, from the executable |

The first room is the room where Conrad starts the level. The executable has two sets of colors
for Conrad. A room uses the second set when its slot 2 bank is not the slot 2 bank of the first
room.

The icon colors replace the second copy of slot 2. For this reason, a pixel of slot 2 in front of
the sprites shows the slot 2 colors of the first room.

## Checks

| Condition | Error |
| --- | --- |
| The file is absent. | `NotFound` |
| The file is larger than 8,192 bytes. | `TooLarge` |
| The file is empty, or its size is not a multiple of 32. | `InvalidPaletteLength` |
| A room selects a bank that the file does not have. | `InvalidPaletteBank` |
| The room where Conrad starts is 64 or more, or is absent. | `AbsentRoom` |

## Quirks

- In a color that is not black, the two low bits of each 6-bit value are 1. For this reason, a
  value of 0 in a color that is not black shows as 12, not as 0. Only the word
  `0x0000` gives black.

## Sources

- `src/shared/content/palette.zig`, `room_artwork.zig`, `floppy_rooms.zig`, `level_pack.zig`,
  `src/shared/scenes/level_screen.zig`
- flashback-re `docs/room-artwork-map.md`, section "Exact palette conversion"
