# Menu pictures (`MENUn.MAP`, `INSTRU_E.MAP`)

A menu MAP file holds one picture of 256 x 224 pixels as four VGA planes. The file is not
packed. The title menu and its pages show these pictures, with the colors of the menu PAL file of
the same name ([menu-palette.md](menu-palette.md)).

| Item | Value |
| --- | --- |
| Files | `DATA/MENU1.MAP`, `DATA/MENU2.MAP`, `DATA/MENU3.MAP`, `DATA/INSTRU_E.MAP`, in `GLOB_UK.ABA` on disk 1 |
| Byte order | None: the file holds bytes only |
| Reader | `src/shared/content/bitmap.zig` (`decodePlanar`), called by `menu_artwork.zig` (`load`, `loadNamed`) |
| Writer | None in flashbackz. The files come with the game. |
| File size | 57,344 bytes |

The installed room images also have the extension MAP, but they have a different layout
([map-rooms.md](map-rooms.md)).

| Picture | Use (`src/shared/scenes/front_end.zig`) |
| --- | --- |
| `MENU1` | The main page of the title menu |
| `MENU2` | The load page and the password page |
| `MENU3` | The skill page |
| `INSTRU_E` | The info page |

## Layout

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 14,336 | u8[] | Plane 0: the columns with x mod 4 = 0 |
| 14,336 | 14,336 | u8[] | Plane 1: the columns with x mod 4 = 1 |
| 28,672 | 14,336 | u8[] | Plane 2: the columns with x mod 4 = 2 |
| 43,008 | 14,336 | u8[] | Plane 3: the columns with x mod 4 = 3 |

A plane holds 224 rows of 64 bytes, the top row first. Byte i of row y in plane p is the pixel at
x = 4 x i + p, y. A pixel is an index in the 256 colors of the menu PAL file.

## Procedure

To find the pixel at (x, y), read the byte at offset (x mod 4) x 14,336 + y x 64 + x / 4. The
division is an integer division.

To open the picture `NAME`:

1. Open `DATA/NAME.MAP`.
2. If it is absent, open `NAME.MAP`, at the top level of the source.
3. Open `NAME.PAL` and `FB_TXT.FNT` ([font.md](font.md)) in the same way.

## Checks

| Condition | Error |
| --- | --- |
| `MENU1.MAP` is absent. | `MissingMenu`: the game stops |
| Another picture, a menu PAL file or the font file is absent. | `NotFound` |
| The file is larger than 57,344 bytes. | `TooLarge` |
| The file is smaller than 57,344 bytes. | `InvalidBitmapLength` |
| The menu PAL file or the font file is not valid. | See [menu-palette.md](menu-palette.md#checks) and [font.md](font.md#checks) |

## Sources

- `src/shared/content/bitmap.zig`, `menu_artwork.zig`, `src/shared/scenes/front_end.zig`,
  `src/shared/game.zig`
- flashback-re `docs/bitmap-port-map.md`, section 1
