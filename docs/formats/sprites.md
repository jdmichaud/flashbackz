# Sprites (`PERSO.SPR`, `PERSO.OFF` and the monster libraries)

An SPR file holds the sprite records of one sprite library. Its OFF file gives the position of
each sprite number in the SPR file. Conrad's sprites are in PERSO, and the enemies use four
monster libraries.

| Item | Value |
| --- | --- |
| Files | `DATA/PERSO.SPR` and `DATA/PERSO.OFF`. For each monster library, `DATA/name.SPR` and `DATA/name.OFF`, with the names `JUNKY`, `MERCENAI`, `REPLICAN` and `GLUE`. |
| Byte order | Little-endian |
| Reader | `src/shared/content/sprite.zig` (`fromArchive`, `decode`), `actor_art.zig` (`Catalog`), `character_art.zig` (`load`) |
| Writer | None. The files come with the game. |

## Layout

### OFF file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 6 × n | entry × n | The entries, at most 4,096 |
| 6 × n | 2 | u16 | 0xffff, the end mark |

An entry:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | The sprite number. It must not be 0xffff. |
| 2 | 4 | u32 | The offset of the record from byte 12 of the SPR file. 0xffffffff gives an empty sprite. |

### SPR file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 3 | u8 × 3 | The ASCII text `SPP` |
| 3 | 9 | — | Unknown. The reader ignores these bytes. |
| 12 | — | — | The sprite records, at the offsets that the OFF file gives |

### Sprite record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | i8 | The origin x |
| 1 | 1 | i8 | The origin y |
| 2 | 1 | u8 | The flags and the first size (next table) |
| 3 | 1 | u8 | The second size, 1 to 255 |
| 4 | — | — | The pixels of a packed record or of a raw record |

| Bits of byte 2 | Content |
| --- | --- |
| 7 | 1: a raw record. 0: a packed record. |
| 6 | 1: the pixels are in column order. 0: the pixels are in row order. |
| 0-5 | The first size, 1 to 63. In a raw record, the first size is byte 2 AND 0xbf (128 to 191). |

The first size is the width of a record in row order, and the height of a record in column
order. The second size is the other dimension. In row order, the pixels go from left to right,
then from top to bottom. In column order, the pixels go from top to bottom, then from left to
right.

The pixels of a packed record:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 4 | 2 | u16 (BE) | The count c of packed bytes |
| 6 | c | — | The packed nibbles. The reader ignores the bytes after them. |

The pixels of a raw record:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 4 | w × h | u8 × w × h | One byte for each pixel |

### Packed nibbles

The high nibble of each byte comes first. A token of one, three or five nibbles gives a run of
pixels of one color:

| Nibbles | Pixels |
| --- | --- |
| c, with c from 0 to 14 | 1 pixel of color c |
| 15, c, n, with c from 0 to 14 | n + 4 pixels of color c (4 to 19) |
| 15, 15, h, l, c | h × 16 + l + 4 pixels of color c (4 to 259) |

The tokens must give w × h pixels, or w × h + 1 pixels with a last pixel of color 0. The reader
discards the extra pixel. Thus a writer adds one 0 nibble to an odd count of nibbles.

### Pixel values

The renderer is the code that draws the pictures on the screen.

- A packed record has pixels from 0 to 15. The renderer puts the color block in the high
  nibble.
- A raw record has 8-bit pixels. The renderer does an OR of the color block into the high
  nibble.
- In the two types, a pixel of 0 is transparent.

### Library tables

The executable holds the tables that select the monster libraries. [executable.md](executable.md)
gives their location.

- The library table has four entries, in a fixed order. An entry gives the name of a library
  and its color bank of 16 colors. The name ends with a 0 byte in its first 12 bytes. The reader
  changes the name to upper case.
- Each of the seven levels has a library list ([executable.md](executable.md#library-list)). A
  list is pairs of bytes, then the byte 0xff. A pair gives a rule group, then the index of its
  library in the library table (0 to 3). A list has at most 8 pairs.

The extractor uses the library list of the level. It gives a library to each enemy (kind 10) and
to each character of rule group 73 ([characters.md](characters.md)). When the list has no pair
for the rule group, the library is `none`.

## Procedures

### Find a sprite in one library

1. Read the OFF file and do the checks of its directory.
2. Read the entries in order until the end mark. Find the entry with the sprite number.
3. If no entry has the number, the library does not hold the sprite.
4. If the offset is 0xffffffff, give an empty sprite: one pixel of color 0, with origin (0, 0).
5. Else, decode the record at byte 12 + offset of the SPR file.

### Decode a record

1. Read the origin, the flags and the two sizes. Get the width w and the height h.
2. For a raw record, copy w × h bytes from byte 4.
3. For a packed record, read the count c at byte 4.
4. Expand the c bytes from byte 6 into nibbles, the high nibble first.
5. Decode the tokens in order in the work area (see Quirks). Keep the first w × h pixels.
6. If bit 6 is 1, change the pixels to row order. Pixel (x, y) is at position x × h + y.

### Find the sprite of an animation frame

The level loader is the code that loads the files of a level when the level starts. It decodes each
sprite that a frame of the level's animations shows ([animations.md](animations.md)). A frame of a
composed animation shows object art ([object-art.md](object-art.md)). For the other frames, the
level loader does these steps:

1. Look for the sprite number in PERSO.
2. If PERSO does not hold it, look in the monster libraries, in the order of the library table.
3. Use the first library that holds the number. An empty sprite also stops the search.
4. If no library holds the number, count the sprite as missing. The frames that show it show
   nothing.

The level loader reads the files of a monster library when it first needs them. In the supplied
files, no sprite number is in two libraries.

### Draw a frame

The renderer puts the origin of a frame at the anchor point (x, y). The top-left pixel of the
frame goes to (x − origin x, y − origin y). A mirrored frame turns over about the left edge of
column x: its left edge goes to x + origin x − width.

The level screen uses the position of the character plus (8, 2) as the anchor point. It draws the
sprites of a character with color block 5 when `palette_bank` of the character is 3
([placements.md](placements.md)). Else, it uses block 4, which holds the colors of Conrad. The level
screen copies the colors of the library of an enemy in the view room into block 5
([level-palette.md](level-palette.md#give-a-room-its-colors)).

## Checks

| Condition | Error |
| --- | --- |
| The SPR file has fewer than 12 bytes, or it does not start with `SPP`. | `InvalidSpriteArchive` |
| The OFF file has fewer than 2 bytes, or its length minus 2 is not a multiple of 6. | `InvalidSpriteDirectory` |
| The OFF file has more than 4,096 entries. | `InvalidSpriteDirectory` |
| The last 2 bytes are not 0xffff, or an entry has the number 0xffff. | `InvalidSpriteDirectory` |
| Two entries have the number that the reader looks for. | `DuplicateSprite` |
| No entry has the number. The search continues in the next library. | `MissingSprite` |
| The offset is not less than the length of the SPR file minus 12. | `InvalidSpriteOffset` |
| A size is 0. | `InvalidSpriteDimensions` |
| The record is shorter than its header, its packed bytes or its raw pixels. | `TruncatedSprite` |
| The packed nibbles stop in a token. | `TruncatedSpriteRun` |
| A run goes past w × h + 1 pixels. | `SpriteRunOverflow` |
| The tokens give fewer than w × h pixels. | `ShortSprite` |
| The tokens give an extra pixel with a color that is not 0. | `TrailingSpriteData` |
| There are more than 4 monster libraries. | `TooManySpriteLibraries` |
| An SPR file has more than 1,048,576 bytes, or an OFF file more than 32,768 bytes. | `TooLarge` |
| A library name has no 0 byte in its first 12 bytes. | `InvalidActorLibrary` |
| A library list has more than 8 pairs, or a library index is 4 or more. | `InvalidLibraryTable` |

The level loader counts a `MissingSprite` and continues. All the other errors stop the level
load.

## Quirks

- The original decodes the tokens in one work area. The output pixels start at position 0, and
  nibble k of the packed bytes is at position 1024 + k. The decoder reads each nibble from the
  work area. Thus output pixel j replaces nibble j − 1024 if the decoder has not read it yet. The
  reader keeps this behavior. It changes the pixels of one frame in the supplied `GLUE.SPR`.
- For a raw record, the original clears only bit 6 of byte 2. Thus bit 7 stays in the first
  size, which is 128 to 191. In the supplied files, one record of `MERCENAI.SPR` is raw.
- An entry with the offset 0xffffffff gives an empty sprite and stops the search. A number that
  has no entry lets the search continue in the next library.

## Sources

- `src/shared/content/sprite.zig`, `actor_art.zig`, `character_art.zig`
- `src/shared/content/floppy_interface.zig` (`actor_libraries`, `library_groups`)
- `src/shared/render/sprite.zig`, `src/shared/scenes/level_screen.zig` (`queue`,
  `libraryReady`), `src/extract/level.zig`
- flashback-re `docs/sprite-port-map.md`
