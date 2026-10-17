# Menu palettes (`MENUn.PAL`, `INSTRU_E.PAL`)

A menu PAL file holds the 256 colors of a menu picture as 8-bit RGB triples. The reader uses it
with the menu MAP file of the same name ([menu-bitmap.md](menu-bitmap.md)). The level PAL files
have a different layout ([level-palette.md](level-palette.md)).

| Item | Value |
| --- | --- |
| Files | `DATA/MENU1.PAL`, `DATA/MENU2.PAL`, `DATA/MENU3.PAL`, `DATA/INSTRU_E.PAL`, in `GLOB_UK.ABA` on disk 1 |
| Byte order | None: the file holds bytes only |
| Reader | `src/shared/content/palette.zig` (`decodeRgb8`), called by `menu_artwork.zig` (`load`, `loadNamed`) |
| Writer | None in flashbackz. The files come with the game. |
| File size | 768 bytes |

## Layout

The file holds 256 colors, color 0 first. Color i:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 3 x i | 1 | u8 | The red component |
| 3 x i + 1 | 1 | u8 | The green component |
| 3 x i + 2 | 1 | u8 | The blue component |

## Procedure

To convert a component c of the file to the 8-bit component that shows:

1. Divide c by 4, with an integer division. The result d is a 6-bit value, 0 to 63.
2. Calculate 4 x d + d / 16, with an integer division. This is the 8-bit component.

Synthetic examples: 19 gives d = 4 and shows as 16. 255 gives d = 63 and shows as 255.

The reader opens the file in the same way as the menu picture
([menu-bitmap.md](menu-bitmap.md#procedure)).

## Checks

| Condition | Error |
| --- | --- |
| The file is absent. | `NotFound` |
| The file is larger than 768 bytes. | `TooLarge` |
| The file is smaller than 768 bytes. | `InvalidPaletteLength` |

## Quirks

- The conversion removes the two low bits of each component. The original sends 6-bit values to
  the VGA DAC, so a component of 19 shows as 16.

## Sources

- `src/shared/content/palette.zig`, `menu_artwork.zig`
- flashback-re `docs/bitmap-port-map.md`, section 2
