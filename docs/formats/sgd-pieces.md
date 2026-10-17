# Background pieces (`LEVEL1.SGD`)

An SGD file holds the background pieces of a level: images with a mask, raw or run-packed. The
piece list of a LEV room description places the pieces on the room
([lev-rooms.md](lev-rooms.md#the-piece-list)). Only the jungle uses an SGD file.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.SGD`, in `GLOB1_FB.ABA` on disk 1 |
| Byte order | Big-endian |
| Reader | `src/shared/content/floppy_rooms.zig` (`drawBackground`), opened by `room_source.zig` |
| Writer | None in flashbackz. The file comes with the game. |
| Largest file | 1,048,576 bytes |

## The tile bias

The tile bias is a constant of the reader for each level (`level.zig`). It is not a field of a
file. The jungle (`LEVEL1`) has a tile bias of 896. The other levels have a tile bias of 0.

The tile bias has two effects:

- The reader opens the SGD file only for a level with a tile bias that is not 0. It opens it only
  when the installed MAP file of the level is absent.
- A LEV cell with tile number n, not 0, shows tile n - 896 of the room's tile set
  ([lev-rooms.md](lev-rooms.md#a-cell-grid)). A tile number from 1 to 895 is an error. The tile
  number 896 shows tile 0, the transparent tile.

A room of a level without a tile bias cannot place pieces, because the reader has no SGD file
for that level.

## Layout

### The file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 4 x count | i32[count] | The directory: the offset of each piece, piece 0 first |
| 4 x count | – | – | The stored pieces |

Byte 0 of the file is the count of pieces, 1 to 255. It is also the high byte of entry 0. The
reader uses only the low 24 bits of entry 0 as the offset of piece 0.

A negative offset marks a raw piece at the absolute value of the offset. An offset of 0 or more
marks a run-packed piece at the offset. Entry 0 cannot be negative, because the reader clears its
high byte. For this reason, piece 0 must be a run-packed piece.

### A stored piece

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | The size n of the data |
| 2 | n | – | The piece: raw, or run codes that unpack to the piece |

### The run codes

A run-packed piece is a sequence of run codes. A run code c is one byte:

| Code | Bytes after the code | Output |
| --- | --- | --- |
| `0x00`-`0x7f` | c + 1 | A copy of the c + 1 bytes |
| `0x80`-`0xff` | 1 | The byte, 257 - c times (129 to 2 times) |

A run-packed piece unpacks to at most 32,768 bytes. The MAP strips use the same run codes
([map-rooms.md](map-rooms.md#the-run-codes)).

### A piece

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | u8 | w: the width of the piece is 8 x (w + 1) pixels |
| 1 | 1 | u8 | h: the height of the piece is h + 1 pixels |
| 2 | 2 | u16 | The size of the mask: width / 8 x height bytes |
| 4 | mask size | – | The mask |
| 4 + mask size | width x height / 2 | – | The pixels |

The mask has one bit for each pixel. It holds the rows of the piece, the top row first, with
width / 8 bytes in each row. Bit 7 of a byte is the leftmost pixel of the byte. A pixel with a
mask bit of 1 is opaque, also when its color is 0.

The pixels are colors from 0 to 15, 4 bits each. They hold the rows of the piece, the top row
first, with width / 2 bytes in each row. Bits 4-7 of a byte are the left pixel.

The reader ignores data after the pixels.

## Procedures

### Get a piece

1. Make sure that the piece number is less than the count of pieces.
2. Read the entry of the piece. For piece 0, use only the low 24 bits.
3. Read the stored piece at the absolute value of the offset.
4. If the offset is negative, the data is the piece.
5. If the offset is not negative, unpack the run codes of the data to get the piece.

### Draw a piece list

Do these steps for each placement of the piece list, the first placement first:

1. If the piece code is `0xffff`, go to the next placement.
2. Get the piece with the number in bits 0-14 of the piece code.
3. For each pixel of the piece with a mask bit of 1, find the room position: x + column,
   y + row.
4. If the position is in the 256 x 224 room, set the room pixel to the piece pixel.

A piece pixel uses palette slot 0, and it is behind the sprites: bits 4-7 of the room pixel are
0. A later piece covers an earlier piece. The front cells of the room come after the pieces
([lev-rooms.md](lev-rooms.md#draw-the-room)).

## Checks

| Condition | Error |
| --- | --- |
| The level has a tile bias, and the SGD and MAP files are absent. | `NotFound` |
| The file is larger than 1,048,576 bytes. | `TooLarge` |
| A placement selects a piece, and the reader has no SGD file or the file is shorter than 4 bytes. | `InvalidBackgroundIndex` |
| The piece number is not less than the count of pieces. | `InvalidBackgroundIndex` |
| A directory entry, a stored piece or a run code goes past the end of its data. | `TruncatedRoomContent` |
| A run-packed piece unpacks to more than 32,768 bytes. | `BackgroundPieceTooLarge` |
| The piece is shorter than 4 bytes, or than its mask and pixels. | `TruncatedRoomContent` |
| The size of the mask is not width / 8 x height. | `InvalidBackgroundMask` |

## Sources

- `src/shared/content/floppy_rooms.zig`, `room_source.zig`, `level.zig`
- flashback-re `docs/floppy-gameplay-entry.md` (installer evidence)
