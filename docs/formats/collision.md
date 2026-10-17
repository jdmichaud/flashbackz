# Collision grid (`LEVELn.CT`)

A collision file holds the terrain of a level. For each of the 64 rooms, it gives the four
neighbors and a grid of 7 rows by 16 columns of cells. The behavior rules probe the cells, and the
level atlas uses the neighbors to put the rooms on a map.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.CT` to `DATA/LEVEL5.CT`. The levels `earth_city` and `spaceport` share `LEVEL4.CT`. The levels `alien_surface` and `alien_base` share `LEVEL5.CT`. |
| Container | One packed stream ([packed-stream.md](packed-stream.md)). The unpacked data has 7424 bytes. |
| Byte order | Not applicable: all the fields are `u8`. |
| Reader | `collision.decode` in `src/shared/content/collision.zig`, called by `level_pack.load`. `src/shared/behavior/grid.zig` keeps a copy of the unpacked bytes in their layout. |
| Writer | None: the files come from the original game. The save file keeps a copy of the grid with its changes ([save.md](save.md)). |

## Layout

The unpacked data:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 64 | `u8[64]` | The up links: the room above each room. |
| 64 | 64 | `u8[64]` | The down links: the room below each room. |
| 128 | 64 | `u8[64]` | The right links: the room to the right of each room. |
| 192 | 64 | `u8[64]` | The left links: the room to the left of each room. |
| 256 | 7168 | `u8[64][112]` | The room records, one for each room from 0 to 63. |

A link table has one byte for each room. The byte for room `r` is at offset `r` in the table. A
link is a room number from 0 to 63. The value 0xff tells that there is no room on that side. The
original files contain no other link values.

A room record has 7 rows of 16 cells. The cell at row `row` and column `column` of room `r` is at
offset `256 + 112 * r + 16 * row + column`.

| Cell value | Description |
| --- | --- |
| 0x00 | Empty. |
| Not 0x00 | Solid. The terrain checks and the sight scans stop at the cell. |
| Bit 1 (0x02) set | A low passage. The cell is solid, but `low_passage_ahead` is true at the cell. A crouched `shoot` or `strike`, and `snap_to_wall_ahead` with `through_low_gaps`, go through the cell. |

The original files contain only the values 0x00, 0x01 and 0x02.

### Room geometry

- A cell is 16 pixels wide. A character at `x` is in column `(x + 8) >> 4`, with an arithmetic
  shift.
- A room has three tiers of 72 pixels. A character at `y` is in tier `y / 72`.
- Tier `t` has its ceiling on row `2t`, its body on row `2t + 1` and its floor on row `2t + 2`.
  Thus rows 0, 2, 4 and 6 are slabs, and rows 1, 3 and 5 are body rows.
- The engine finds the ceiling row of a tier (the band) as `(y / 36) & ~1`. The division rounds
  toward zero.

## Procedures

### Read the file

1. Read `DATA/LEVELn.CT`. The file must have at most 65536 bytes.
2. Unpack the stream ([packed-stream.md](packed-stream.md)) with a limit of 7424 bytes.
3. Make sure that the unpacked data has exactly 7424 bytes.
4. Keep the bytes in the layout of the file. The probes and the terrain changes use them in place.

### Probe a cell

A probe gives the cell at `row` and `column` relative to the room `room` of a character. The row
and the column can be outside the room. The engine uses the first step that applies:

1. If `column < 0`, read the left link of `room` as `i8`. If the link is negative, the result
   is 1. Else read the cell at `row` and `column + 16` of the left room.
2. If `column >= 16`, read the right link of `room` as `u8`. Read the cell at `row` and
   `column - 16` of that room (see the quirks).
3. If `row < 1`, read the up link as `i8`. If the link is negative, the result is 1. Else read the
   cell at `row + 6` and `column` of the room above.
4. If `row >= 7`, read the down link as `i8`. If the link is negative, the result is 1. Else read
   the cell at `row - 6` and `column` of the room below.
5. Else read the cell at `row` and `column` of `room`.

To read a cell, calculate its offset with the formula of the layout. Do not check the row or the
column. The result is the byte at that offset, as `i8`. A result that is not 0 is solid.

The probe follows one link only, and a horizontal link wins over a vertical link. A probe at row 0
reads row 6 of the room above.

### Change the terrain

The effects `make_solid`, `make_empty` and `make_low_passage` write 0x01, 0x00 and 0x02:

1. If the character is in a room above 63, stop.
2. Find the first cell: the cell of room `room` in the column of the character, on the row
   `band + argument`. For this column and band, the engine uses the current position, with `y`
   read as `u16`.
3. If the character faced right at the start of its update, move the first cell back by
   `width - 1` bytes. The width is byte 28 of the placement ([placements.md](placements.md)).
4. Write `width` consecutive bytes from the first cell. The bytes continue into the next row or
   room record. The engine skips bytes outside the grid.

The engine keeps the old bytes, so that `restore_terrain` can write them back. If the history of
changes is full, a change at a new first cell writes nothing (`TerrainHistory` in `world.zig`).

## Checks

| Condition | Error |
| --- | --- |
| The file has more than 65536 bytes. | `error.TooLarge` |
| The stream is not valid. | The errors of [packed-stream.md](packed-stream.md). |
| The stream gives more than 7424 bytes. | `error.ExpandedContentTooLarge` |
| The stream gives fewer than 7424 bytes. | `error.InvalidCollisionLayout` |

The reader does not check the links or the cell values.

## Quirks

- **A missing right link.** The probe reads the right link as `u8`, so it does not see 0xff as a
  missing link. It reads the cells of room 255, past the end of the grid. In the original, these
  bytes are other game variables. The engine gives these values for offsets from the start of the
  grid:

  | Offset | Value |
  | --- | --- |
  | 28896, 28897 | The direction of the character that the engine updates: 0xffff for right, 0 for left. |
  | 28900, 28901 | The column of that character for its update (`World.column`), as `i16`. |
  | 28902, 28903 | The band of that character for its update (`World.band`), as `i16`. |
  | All other offsets past the grid | 0. The engine counts the read in `World.unmodeled_reads`. |

  The low byte of each value is at the even offset. A probe on row 5 at the columns 16 to 23
  reaches the offsets 28896 to 28903.
- **Rows and columns outside a room.** After the probe selects a room, it does not check the row
  or the column. A read outside the room continues into the bytes before or after the room
  record. For example, row 7 of room `r` is row 0 of room `r + 1`. Row -1 of room 0 is in the left
  link table.
- **Rooms above 63.** A character can be in a room above 63, outside the map. The link of room
  `r` is the byte `64 * side + r`, with the sides 0 to 3 in the order up, down, right, left. For a
  room above 63, this byte is in the next table or in the room records.
- **Links from 64 to 127.** Such a link is not negative as `i8`, so the probe reads a room record
  past the end of the grid. The original files contain no such links.
- **A band above the room.** For `y` from -107 to -36, the update calculates the band as 254. The
  probes then read the room below, at a row far outside it.
- **The result of `restore_terrain`.** The original gives the address of the cell where the
  restore starts, and the rule tests only its low byte. Thus the result depends on the position of
  the cell in the grid. `original_memory.addressLowByte` keeps this behavior. If the history has
  no changes, the original gives the offset of the cell in its room record.

## Sources

- `src/shared/content/collision.zig`, `src/shared/content/level_pack.zig` and
  `src/shared/content/level.zig` (the file names).
- `src/shared/behavior/grid.zig` and `src/shared/behavior/original_memory.zig`.
- `src/shared/behavior/operations/terrain.zig` and `perception.zig` (the probes), and
  `carriers.zig` (the terrain changes).
- flashback-re: `docs/rules/codes-001-033.md` (sections B and C), `docs/rules/engine-update.md`
  (the link tables) and `docs/collision-port-map.md` (the stream).
