# Room descriptions (`LEVELn.LEV`)

A LEV file holds the packed descriptions of the 64 rooms of a level. A description selects the
room's tiles from the BNQ file and, in the jungle, the room's background pieces from the SGD file.
The reader makes from it the same room image as an installed MAP room (research: flashback-re
`docs/floppy-gameplay-entry.md`).

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.LEV` to `DATA/LEVEL5.LEV`, plain files on disk 1 |
| Byte order | Big-endian. The cells are little-endian. |
| Reader | `src/shared/content/floppy_rooms.zig` (`Archive.decode`), opened by `room_source.zig` |
| Writer | None in flashbackz. The files come with the game. |
| Largest file | 1,048,576 bytes |

## The files of a level

Two levels can share one set of room files. The reader uses these names (`level.zig`):

| Level | Room files | Tile bias |
| --- | --- | --- |
| Jungle | `LEVEL1` | 896 |
| City | `LEVEL2` | 0 |
| Tower | `LEVEL3` | 0 |
| Earth city, spaceport | `LEVEL4` | 0 |
| Alien surface, alien base | `LEVEL5` | 0 |

A level uses these files:

- `LEVELn.MAP`, if it is present: the installed room images ([map-rooms.md](map-rooms.md)). The
  reader then does not open the LEV, BNQ and SGD files.
- If the MAP file is absent, `LEVELn.LEV`, this file, and `LEVELn.BNQ`, the tile banks
  ([bnq-tiles.md](bnq-tiles.md)).
- `LEVELn.SGD`, the background pieces ([sgd-pieces.md](sgd-pieces.md)), only for a level with a
  tile bias. The tile bias is a constant of the reader, not a field of a file.
- `LEVELn.PAL`, the color banks ([level-palette.md](level-palette.md)), with each of the two
  room forms.

## Layout

### The file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 256 | u32[64] | The directory: the end offset of each room, room 0 first |
| 256 | – | – | The packed streams of the rooms, room 0 first |

Each present room is a packed stream ([packed-stream.md](packed-stream.md)) that ends at the end
offset of the room. The stream of a room starts at the end offset of the previous room, or at 256
for room 0. An end offset that is equal to the previous end offset marks an absent room.

The reader gives the decoder the bytes from offset 256 to the end offset of the room. The length
of a packed stream must be a multiple of 4. For this reason, each end offset must be a multiple
of 4.

### The room description

The packed stream unpacks to the room description. A description is 16 to 16,384 bytes. The
offsets in the description start at the start of the description.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | u8 | Unknown. The reader ignores it. |
| 1 | 1 | u8 | The background form: 0 for background cells, another value for a piece list |
| 2 | 2 | u16 | The PAL bank of palette slot 0 |
| 4 | 2 | u16 | The PAL bank of palette slot 1 |
| 6 | 2 | u16 | The PAL bank of palette slot 2 |
| 8 | 2 | u16 | The PAL bank of palette slot 3 |
| 10 | 2 | u16 | The offset of the background: the background cells or the piece list |
| 12 | 2 | u16 | The offset of the front cells |
| 14 | 2 | u16 | The offset of the bank list |

Each PAL bank must be 255 or less. The reader reads only the parts that the offsets give.

### A cell grid

A cell grid is 1,792 bytes: 28 rows of 32 cells, the top row first. Each cell is a `u16 (LE)`.
Cell n covers the 8 x 8 pixels with the top left corner at x = 8 x (n mod 32), y = 8 x (n / 32).

| Bits | Content |
| --- | --- |
| 0-10 | The tile number. 0 is no tile. |
| 11 | 1: flip the tile left to right |
| 12 | 1: flip the tile top to bottom |
| 13-14 | The palette slot, 0 to 3 |
| 15 | 1: the tile is in front of the sprites |

A cell with tile number n, not 0, shows tile n - b of the room's tile set. The value b is the
tile bias of the level ([sgd-pieces.md](sgd-pieces.md#the-tile-bias)).

### The bank list

The bank list selects the tiles of the room from the BNQ banks. It has 1 to 256 entries. An entry:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | Bits 0-14: the BNQ bank number. Bit 15: 1 in the last entry. |
| 2 | 1 | u8 | `0xff`: all the tiles of the bank. A value n below `0xff`: n + 1 tile numbers. |
| 3 | n + 1 | u8[] | Only when byte 2 is not `0xff`: the numbers of the tiles in the bank |

### The piece list

The piece list places SGD pieces on the room. It replaces the background cells when byte 1 of
the description is not 0.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | The count of placements |
| 2 | 6 x count | – | The placements |

A placement:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | `0xffff`: no piece. Other values: the SGD piece number in bits 0-14. |
| 2 | 2 | i16 | The x of the top left corner of the piece |
| 4 | 2 | i16 | The y of the top left corner of the piece |

The reader ignores bit 15 of the piece code, except in `0xffff`.

## Procedures

### Unpack a room

1. Read the end offset of room r at offset 4 x r.
2. Read the end offset of room r - 1. For room 0, use 256.
3. If the two end offsets are equal, the room is absent. Stop.
4. Unpack the packed stream that ends at the end offset of room r.

### Make the tile set

The tile set is a list of 32-byte tiles ([bnq-tiles.md](bnq-tiles.md#a-tile)).

1. Put one tile of 32 bytes of 0 in the tile set. This is tile 0, a transparent tile.
2. Read the first entry of the bank list.
3. Get the tiles of the BNQ bank that the entry gives ([bnq-tiles.md](bnq-tiles.md)).
4. If byte 2 of the entry is `0xff`, add all the tiles of the bank to the tile set.
5. If byte 2 is not `0xff`, add the selected tiles to the tile set, in the order of the list.
6. If bit 15 of the entry is 1, stop. If not, read the next entry and go to step 3.

### Draw the room

1. Make an image of 256 x 224 pixels. Set all the pixels to `0x00`.
2. Make the tile set.
3. If byte 1 of the description is 0, draw the background cells.
4. If byte 1 is not 0, draw the pieces of the piece list
   ([sgd-pieces.md](sgd-pieces.md#draw-a-piece-list)).
5. Draw the front cells.
6. Give the room the colors of its four PAL banks ([level-palette.md](level-palette.md)).

The result has the pixel layout of a MAP room ([map-rooms.md](map-rooms.md#a-pixel)).

### Draw a cell grid

Do these steps for each cell, cell 0 first:

1. If the tile number is 0, go to the next cell.
2. Find tile n - b in the tile set, where n is the tile number and b is the tile bias.
3. For each pixel (x, y) of the 8 x 8 cell, read the tile pixel at (x, y). Use 7 - x when bit 11
   is 1. Use 7 - y when bit 12 is 1.
4. If the tile pixel is 0, keep the image pixel.
5. If the tile pixel is not 0, change the image pixel. The new value is the tile pixel plus
   16 x the palette slot. Add `0x80` when bit 15 is 1. Keep bit 7 of the old image pixel.

## Checks

| Condition | Error |
| --- | --- |
| The MAP file and the LEV or BNQ file are absent. | `NotFound` |
| The file is larger than 1,048,576 bytes. | `TooLarge` |
| The room number is 64 or more. | `RoomOutOfRange` |
| The file is shorter than 256 bytes, the size of the room directory. | `InvalidRoomDirectory` |
| An end offset is less than the previous end offset, or less than 256. | `InvalidRoomRange` |
| The end offset is equal to the previous end offset. | `AbsentRoom` (not a failure: no room) |
| The stream is not a valid packed stream. | See [packed-stream.md](packed-stream.md#checks) |
| The description is longer than 16,384 bytes. | `ExpandedContentTooLarge` |
| A stream, a description part or a tile is outside its data. | `TruncatedRoomContent` |
| A bank word at offset 2 to 8 is more than 255. | `InvalidPaletteBank` |
| The first 256 entries of the bank list have no last entry. | `UnterminatedRoomBanks` |
| The tile set has more than 1,024 tiles (32,768 bytes), with tile 0. | `RoomTilesTooLarge` |
| A tile number is not 0 and is less than the tile bias. | `InvalidRoomTile` |
| The reader refuses a BNQ bank. | See [bnq-tiles.md](bnq-tiles.md#checks) |
| The reader refuses an SGD piece. | See [sgd-pieces.md](sgd-pieces.md#checks) |
| A PAL bank is not in the PAL file. | See [level-palette.md](level-palette.md#checks) |

The level reads all 64 rooms when it starts. If one room has an error, the level does not load.

## Quirks

- A tile pixel keeps bit 7 of the pixel under it. A pixel in front of the sprites stays in front
  when a later tile without bit 15 covers it.

## Sources

- `src/shared/content/floppy_rooms.zig`, `room_source.zig`, `level.zig`, `level_pack.zig`
- flashback-re `docs/floppy-gameplay-entry.md` (installer evidence)
- flashback-re `docs/room-artwork-map.md`
