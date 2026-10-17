# Object art (`GLOBAL.SPC` and `LEVELn.RP`)

`GLOBAL.SPC` holds the compositions of the object art. A composition puts tiles of 8 × 8 to
32 × 32 pixels from one MBK bank into one frame. The RP file of a level selects the bank of each
composition in the MBK file of the level. The composed animations show these frames.

| Item | Value |
| --- | --- |
| Files | `DATA/GLOBAL.SPC`, for all the levels. `DATA/LEVEL1.RP` to `DATA/LEVEL5.RP`, one for each MBK file ([mbk-banks.md](mbk-banks.md)). |
| Byte order | Big-endian |
| Reader | `src/shared/content/object_artwork.zig` (`recordAt`, `fromArchive`, `decode`). `character_art.zig` reads the files. |
| Writer | None. The files come with the game. |

## Layout

### `GLOBAL.SPC`

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 × n | u16 × n | The directory: the offset of each record. The first offset is also 2 × n. |
| 2 × n | — | — | The records |

Two entries of the directory can have the same offset, thus records can share their bytes.

A record:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | u8 | The bank selector: an index in the RP file |
| 1 | 1 | i8 | The origin x |
| 2 | 1 | i8 | The origin y |
| 3 | 2 | — | The source bounds. The reader ignores them. |
| 5 | 1 | u8 | The part count p, 1 or more |
| 6 | 4 × p | part × p | The parts, in the order that the reader composes them |

A part:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | u8 | The offset of the tile in the bank, in units of 32 bytes |
| 1 | 1 | u8 | The x of the tile in the frame |
| 2 | 1 | u8 | The y of the tile in the frame |
| 3 | 1 | u8 | The shape and the flags (next table) |

| Bits of byte 3 | Content |
| --- | --- |
| 0-1 | The height of the tile, divided by 8, minus 1 |
| 2-3 | The width of the tile, divided by 8, minus 1 |
| 4 | 1: the tile is mirrored left to right in its area |
| 5-7 | Unknown. The reader ignores them. |

A tile of width w and height h is w × h / 2 bytes at byte 32 × (part byte 0) of the bank. Its
pixels are in row order, two in each byte, with the high nibble first. A pixel of 0 is
transparent.

### `LEVELn.RP`

The RP file has one byte for each bank selector. Byte k is the index in the MBK file of the bank
that selector k selects. In the supplied files, each RP file has 74 bytes, and each byte is a
valid bank index. Some bytes select a bank of size 0.

### The frame

The frame starts at (0, 0) in the coordinates of the parts. Its width is the largest x + w of
the parts, and its height is the largest y + h of the parts. The pixels are 0 to 15, and 0 is
transparent. The origin of the frame is bytes 1 and 2 of the record.

## Procedures

### Find record i

1. Read the directory size d, the u16 at byte 0.
2. If i is d / 2 or more, the record does not exist.
3. Read the offset of the record, the u16 at byte 2 × i.
4. Read the part count at the offset + 5. The record has 6 + 4 × p bytes.

### Compose record i for a level

1. Find record i.
2. Read the bank selector, byte 0 of the record. Read the RP byte at that index.
3. Read the MBK bank that the RP byte gives ([mbk-banks.md](mbk-banks.md)).
4. Find the size of the frame from the parts. Fill the frame with 0.
5. Do steps 6 to 8 for each part, in the record order.
6. Read the tile at 32 × (part byte 0) of the bank.
7. For a mirrored part, read each tile row from right to left.
8. Write each pixel that is not 0 at (part x + column, part y + row).

A later part thus covers the earlier parts, but its pixels of 0 keep the earlier pixels.

### Use the frames

An animation shows composed frames when the u16 at bytes 4 and 5 of its header is not 0
([animations.md](animations.md)). Its frames give record numbers in `GLOBAL.SPC`. A composed
frame and a sprite with the same number are different frames ([sprites.md](sprites.md)).

The level screen draws a composed frame with the origin at the position of the character plus
(8, 2). The palette bank of the character (0 to 3) gives the color block
([placements.md](placements.md)). These four blocks hold the colors of the room
([level-palette.md](level-palette.md#give-a-room-its-colors)). The renderer mirrors the full
frame as it mirrors a sprite.

## Checks

| Condition | Error |
| --- | --- |
| `GLOBAL.SPC` has fewer than 2 bytes, or d is less than 2, odd, or more than the file length. | `InvalidObjectArtDirectory` |
| The record number is d / 2 or more. | `MissingObjectArt` |
| The offset is less than d, or the file has fewer than 6 bytes from the offset. | `InvalidObjectArtOffset` |
| The parts go past the end of the file. | `TruncatedObjectArt` |
| The part count is 0. | `EmptyObjectArt` |
| A tile goes past the end of the bank. | `TruncatedObjectArtTile` |
| The bank selector is not less than the length of the RP file. | `MissingObjectArtBankBinding` |
| The bank that the RP byte gives is missing or not valid. | The errors of [mbk-banks.md](mbk-banks.md) |
| `GLOBAL.SPC` has more than 65,536 bytes, or the RP file more than 256 bytes. | `TooLarge` |

The level loader counts `MissingObjectArt`, `MissingObjectArtBankBinding` and `MissingArtBank`
as missing sprites and continues. The frames that show a missing sprite show nothing. The other
errors stop the level load.

## Quirks

- The reader ignores bits 5 to 7 of part byte 3, as the original does. In the supplied file,
  44 parts have a 1 in bit 5.
- The reader ignores the source bounds in bytes 3 and 4 of the record. The parts give the size
  of the frame.

## Sources

- `src/shared/content/object_artwork.zig`, `character_art.zig`, `animations.zig`
- `src/shared/scenes/level_screen.zig` (`queue`), `src/shared/render/sprite.zig`
- flashback-re `docs/object-artwork-map.md`
