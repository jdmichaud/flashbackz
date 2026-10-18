# Installed room images (`LEVELn.MAP`)

An installed MAP file holds the 64 room images of a level as indexed pixels, with the four
PAL banks of each room. The DOS installer writes it from the LEV, BNQ and SGD files. When a
MAP file is present, the reader uses it and does not open the LEV, BNQ and SGD files.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.MAP` to `DATA/LEVEL5.MAP`, in an installed game. The floppy disks do not hold them. |
| Byte order | Little-endian |
| Reader | `src/shared/content/room_artwork.zig` (`decode`), opened by `room_source.zig` |
| Writer | `INSTALL.EXE` of the original game (research: flashback-re `docs/room-artwork-map.md`). None in flashbackz. |
| Largest file | 8,388,608 bytes |

The levels use the same `LEVELn` names as the LEV files
([lev-rooms.md](lev-rooms.md#the-files-of-a-level)). The menu pictures also have the extension
MAP, but they have a different layout ([menu-bitmap.md](menu-bitmap.md)).

## Layout

### The file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 384 | – | The directory: 64 entries of 6 bytes, room 0 first |
| 384 | – | – | The room records |

### A directory entry

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 4 | i32 | The offset of the room record. 0: no room. Negative: raw planes. Positive: packed strips. |
| 4 | 2 | u16 | The size of the room record |

The room record starts at the absolute value of the offset. The reader does not require an order
of the room records.

### A room record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | u8 | The PAL bank of palette slot 0 |
| 1 | 1 | u8 | The PAL bank of palette slot 1 |
| 2 | 1 | u8 | The PAL bank of palette slot 2 |
| 3 | 1 | u8 | The PAL bank of palette slot 3 |
| 4 | size - 4 | – | The pixels: raw planes or four packed strips |

The four PAL banks select the colors of the room ([level-palette.md](level-palette.md)).

### Raw planes

The raw planes are 57,344 bytes. They have the layout of a menu picture: four VGA planes of
14,336 bytes ([menu-bitmap.md](menu-bitmap.md#layout)). The size of a raw room record is 57,348.

### Packed strips

The pixels are four strips, strip 0 first. Strip s holds the rows 56 x s to 56 x s + 55 of the
image, row by row, left to right. The strips fill the room record to its end.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | The size n of the run codes |
| 2 | n | – | The run codes. They unpack to 14,336 bytes: 56 rows of 256 pixels. |

### The run codes

A run code c is one byte:

| Code | Bytes after the code | Output |
| --- | --- | --- |
| `0x00`-`0x7f` | c + 1 | A copy of the c + 1 bytes |
| `0x80`-`0xff` | 1 | The byte, 257 - c times (129 to 2 times) |

The reader accepts all valid run codes. The research document flashback-re
`docs/room-artwork-map.md` gives the choices of the installer, for a writer that must make the
same bytes.

### A pixel

A room image is 256 x 224 pixels. The LEV room form gives pixels with the same layout
([lev-rooms.md](lev-rooms.md#draw-the-room)).

| Bits | Content |
| --- | --- |
| 0-3 | The color in the palette slot |
| 4-5 | The palette slot, 0 to 3 |
| 6 | Must be 0 |
| 7 | 1: the pixel is in front of the sprites |

For this reason, a pixel must be `0x00`-`0x3f`, or `0x80`-`0xbf` in front of the sprites.

## Procedure

To read room r:

1. Read the directory entry at offset 6 x r.
2. If the offset is 0, the room is absent. Stop.
3. Find the room record at the absolute value of the offset.
4. Read the four PAL banks.
5. If the offset is negative, read the raw planes.
6. If the offset is positive, read the four strips, strip 0 first. For each strip, read the size
   n. Then unpack the n bytes of run codes into the next 56 rows.
7. Make sure that each pixel is a valid pixel.

## Checks

| Condition | Error |
| --- | --- |
| The file is larger than 8,388,608 bytes. | `TooLarge` |
| The file is shorter than 384 bytes. | `TruncatedRoomDirectory` |
| The offset is 0. | `AbsentRoom` (not a failure: no room) |
| The room record starts in the directory or goes past the end of the file. | `InvalidRoomRange` |
| The room record is shorter than 4 bytes. | `TruncatedRoomPalette` |
| A PAL bank is not in the PAL file. | See [level-palette.md](level-palette.md#checks) |
| The raw planes are not 57,344 bytes. | `InvalidBitmapLength` |
| The size of a strip is not in the room record. | `TruncatedStripLength` |
| The run codes of a strip go past the end of the room record. | `TruncatedStrip` |
| A run code needs more bytes than the strip has. | `TruncatedRun` |
| A strip unpacks to more than 14,336 bytes. | `StripOverflow` |
| A strip unpacks to fewer than 14,336 bytes. | `ShortStrip` |
| The room record has bytes after strip 3. | `TrailingRoomData` |
| A pixel is `0x40`-`0x7f` or `0xc0`-`0xff`. | `UnboundBackgroundColor` |

The level reads all 64 rooms when it starts. If one room has an error, the level does not load.

## Sources

- `src/shared/content/room_artwork.zig`, `room_source.zig`, `bitmap.zig`, `level_pack.zig`
- flashback-re `docs/room-artwork-map.md`: the directory, the strips, the run codes and the
  installer's choices
