# Font (`FB_TXT.FNT`)

`FB_TXT.FNT` holds the glyphs of the game font: 8 × 8 pixels with 4-bit inks, from the
character 32 (space) up. The menus, the level screen, the inventory screen, the films, the
continue screen, the credits and the level atlas use it.

| Item | Value |
| --- | --- |
| Files | `DATA/FB_TXT.FNT`. The menu also finds it as `FB_TXT.FNT`. |
| Byte order | None. The file holds only bytes. |
| Reader | `src/shared/content/font.zig` (`decode`, `Font.glyph`). The files that read it: `level_pack.zig`, `cinematic_text.zig`, `menu_artwork.zig`, `continue_artwork.zig`, `src/shared/scenes/ending.zig`, `src/atlas/main.zig`. |
| Writer | None. The file comes with the game. |

## Layout

The file has no header. Glyph g is at offset 32 × g and is the glyph of the character 32 + g.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 32 × g | 32 | — | 8 rows of 4 bytes. Each byte gives two pixels, the left pixel in the high nibble. |

The file can hold 1 to 224 glyphs. The supplied file has 3,360 bytes: 105 glyphs, for the
characters 32 to 136. A character below 32 or after the last glyph has no glyph.

### Inks

| Ink | Text renderer |
| --- | --- |
| 0 | Transparent |
| 2 | The shadow color |
| 15 | The foreground color |
| Other | The palette bank × 16 + ink, if the caller gives a palette bank. Else, the renderer refuses the glyph. |

The supplied font uses one more ink in some glyphs. Most callers give the palette bank 14 and
the shadow color 0xe2. The title menu and its pages give no palette bank. The renderer moves 8
pixels to the right after each character. The level atlas draws ink 2 in its shadow color and
the other inks in its text color.

## Procedures

### Read the font

1. Read the file and do the checks.
2. Expand each byte into two pixels, the high nibble first.

### Find the glyph of a character c

1. If c is less than 32, there is no glyph.
2. Find the offset 64 × (c − 32) in the expanded pixels.
3. If this offset is not in the pixels, there is no glyph.
4. Else, the glyph is the 64 pixels from the offset, in row order.

## Checks

| Condition | Error |
| --- | --- |
| The file is empty, or its length is not a multiple of 32. | `InvalidFontLength` |
| The file has more than 224 glyphs. | `InvalidFontLength` |
| The file has more than 16,384 bytes. | `TooLarge` |
| A text has a character with no glyph. | `MissingGlyph` |
| A glyph has an ink other than 0, 2 and 15, and the caller gives no palette bank. | `UnknownGlyphInk` |

The level loader examines the characters of the world messages and of the labels when the level
loads. The end sequence examines the characters of the credits when it loads, except the
character `|`. The level atlas skips a character that has no glyph.

## Sources

- `src/shared/content/font.zig`, `src/shared/render/text.zig`
- `src/shared/content/level_pack.zig`, `cinematic_text.zig`, `menu_artwork.zig`,
  `continue_artwork.zig`
- `src/shared/scenes/level.zig`, `level_screen.zig`, `inventory_menu.zig`, `ending.zig`,
  `menu.zig`, `src/atlas/main.zig`, `src/atlas/draw.zig`
- flashback-re `docs/bitmap-port-map.md` (section 3), `docs/inventory-menu-map.md`
