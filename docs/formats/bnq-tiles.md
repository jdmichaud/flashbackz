# Tile banks (`LEVELn.BNQ`)

A BNQ file holds the banks of 8 x 8 tiles of a level. The bank list of a LEV room description
selects banks and tiles from it ([lev-rooms.md](lev-rooms.md#the-bank-list)). A bank is raw or
packed.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.BNQ` to `DATA/LEVEL5.BNQ`, in `GLOB2_FB.ABA` on disk 2 |
| Byte order | Big-endian |
| Reader | `src/shared/content/floppy_rooms.zig` (`loadTiles`), opened by `room_source.zig` |
| Writer | None in flashbackz. The files come with the game. |
| Largest file | 1,048,576 bytes |

The reader opens a BNQ file only when the installed MAP file of the level is absent
([lev-rooms.md](lev-rooms.md#the-files-of-a-level)).

## Layout

### The file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 6 x count | – | The directory: one entry for each bank, bank 0 first |
| 6 x count | – | – | The packed banks and the raw banks |

Byte 0 of the file is the count of banks, 1 to 255. It is also byte 0 of entry 0.

### A directory entry

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | Not used. Byte 0 of entry 0 is the count of banks. |
| 2 | 2 | u16 | The offset of the bank |
| 4 | 2 | i16 | The count of tiles. A negative count marks a raw bank of -count tiles. |

The offset is 16 bits. Thus the start of a raw bank and the end of a packed bank must be at
offset 65,535 or less.

### A raw bank

A raw bank starts at the offset of the bank. It holds 32 x n bytes for n tiles, tile 0 first.

### A packed bank

A packed bank is a packed stream ([packed-stream.md](packed-stream.md)) that ends at the offset
of the bank. It unpacks to 32 x n bytes for n tiles, tile 0 first.

The reader gives the decoder the bytes from the end of the directory to the offset of the bank.
This length must be 12 or more, and a multiple of 4.

### A tile

A tile is 32 bytes: 8 rows of 4 bytes, the top row first. A byte holds two pixels. Bits 4-7 are
the left pixel and bits 0-3 are the right pixel. A pixel is a color from 0 to 15 in the palette
slot of the cell ([lev-rooms.md](lev-rooms.md#a-cell-grid)). Pixel 0 is transparent.

## Procedure

To get the tiles of bank b:

1. Make sure that b is less than the count of banks.
2. Read the offset and the count of tiles from entry b.
3. If the count is negative, read 32 x (-count) bytes at the offset.
4. If the count is positive, unpack the packed stream that ends at the offset. The result must be
   32 x count bytes.

## Checks

| Condition | Error |
| --- | --- |
| The file is absent and the MAP file of the level is absent. | `NotFound` |
| The file is larger than 1,048,576 bytes. | `TooLarge` |
| The file is shorter than 6 bytes, or byte 0 is 0. | `InvalidArtBankDirectory` |
| The file is shorter than its directory: 6 x the count of banks. | `TruncatedRoomContent` |
| The bank number is not less than the count of banks. | `InvalidArtBank` |
| The count of tiles is 0, or more than 1,024 tiles (32,768 bytes). | `InvalidArtBank` |
| The offset of the bank is less than 6 x count of banks. | `InvalidArtBank` |
| A raw bank, or the offset of a packed bank, goes past the end of the file. | `TruncatedRoomContent` |
| The packed bank is not a valid packed stream. | See [packed-stream.md](packed-stream.md#checks) |
| The packed bank unpacks to more bytes than 32 x count. | `ExpandedContentTooLarge` |
| The packed bank unpacks to fewer bytes than 32 x count. | `ArtBankSizeMismatch` |
| A tile number in the bank list is not less than the count of tiles. | `TruncatedRoomContent` |

## Quirks

- The BNQ directory entry has the size of the MBK directory entry ([mbk-banks.md](mbk-banks.md)),
  but it marks a raw bank in a different way. BNQ uses a negative count of tiles. MBK uses a flag
  bit. The reader keeps the two forms, as the original reads them.

## Sources

- `src/shared/content/floppy_rooms.zig`, `src/shared/content/backward_stream.zig`,
  `src/shared/content/art_bank.zig` (the MBK form, for comparison)
- flashback-re `docs/floppy-gameplay-entry.md` (installer evidence)
