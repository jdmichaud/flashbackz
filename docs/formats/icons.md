# Icons (`GLOBAL.ICN`)

`GLOBAL.ICN` holds icons of 16 × 16 pixels with 4-bit colors. The level screen shows the icons
of the items and of the characters that Conrad touches. The inventory screen makes its panel,
its marker and its page arrows from icons.

| Item | Value |
| --- | --- |
| Files | `DATA/GLOBAL.ICN` |
| Byte order | Little-endian |
| Reader | `src/shared/content/sprite.zig` (`fromIcons`), `level_pack.zig` (`loadIcons`), `inventory_artwork.zig` (`load`) |
| Writer | None. The file comes with the game. |

## Layout

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 × n | u16 × n | The directory: the offset of each icon record. The first offset is also 2 × n. |
| 2 × n | — | — | The icon records |

An icon record:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | — | Unknown. The reader ignores these bytes. |
| 2 | 128 | — | 256 pixels: 16 rows of 16 pixels, two in each byte, with the high nibble first |

The pixels are 0 to 15, and 0 is transparent. An icon has no origin. The supplied file has 79
icons. Its records are in the directory order, 130 bytes each, and their first two bytes are the
same in all the records.

### Icon numbers

| Icon number | User | Use |
| --- | --- | --- |
| 0 to n − 1 | `level_pack.zig` | The level loader decodes all the icons. |
| The inventory icon of an item ([placements.md](placements.md)) | `level_screen.zig`, `level.zig` | The icon of the selected item at (232, 8). The icon of the item in the inventory screen. |
| The contact icon of a character minus 1, for a contact icon of 1 to 127 | `level_screen.zig` | The icon at (80, 8) beside the name of what Conrad touches, and beside a message |
| 31 to 75 | `inventory_artwork.zig` | The 45 tiles of the inventory panel |
| 76 | `inventory_artwork.zig` | The marker on the selected item |
| 77 | `inventory_artwork.zig` | The arrow to the previous page |
| 78 | `inventory_artwork.zig` | The arrow to the next page |

The inventory panel is 144 × 80 pixels: 9 columns and 5 rows of tiles. Tile k (0 to 44) is icon
31 + k. Its position in the panel is x = (k mod 9) × 16, y = (k / 9) × 16.

## Procedures

### Read icon i

1. Read the directory size d, the u16 at byte 0.
2. If i is d / 2 or more, the icon does not exist.
3. Read the offset of the record, the u16 at byte 2 × i.
4. Skip the first 2 bytes of the record.
5. Expand the next 128 bytes into 256 pixels, the high nibble first, in row order.

### Show an icon

The level screen writes each pixel p that is not 0 as the color 0xa0 + p. Color block 10 (0xa0
to 0xaf) holds the colors of bank slot 2 of the room where Conrad starts
([level-palette.md](level-palette.md#give-a-room-its-colors)). The level screen also writes the
icon of the selected item into the room background. There, the icon hides the sprites.

When an icon number is d / 2 or more, the level screen shows no icon. The inventory screen does
not show an item that has such an icon.

The inventory screen draws the panel with color block 15 at (56, 140). It draws the item icons,
the marker and the arrows with color block 10.

## Checks

| Condition | Error |
| --- | --- |
| The file has fewer than 2 bytes, or d is less than 2, odd, or more than the file length. | `InvalidIconDirectory` |
| The icon number is d / 2 or more. | `MissingIcon` |
| The offset is less than d, or the file has fewer than 130 bytes from the offset. | `TruncatedIcon` |
| The file has more than 32,768 bytes. | `TooLarge` |

The level loader decodes all the icons, and it stops on an error. It also needs icons 31 to 78
for the inventory screen.

## Sources

- `src/shared/content/sprite.zig`, `level_pack.zig`, `inventory_artwork.zig`
- `src/shared/scenes/level_screen.zig` (`iconFrame`, `drawIcon`, `paintHudIcon`, `drawLabel`),
  `src/shared/scenes/level.zig`, `src/shared/scenes/inventory_menu.zig`
- flashback-re `docs/sprite-port-map.md`, `docs/inventory-menu-map.md`
