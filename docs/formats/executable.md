# Game executable (`FB.EXE`)

`FB.EXE` is the DOS program of the floppy edition, packed with EXEPACK. The readers unpack it in
memory and read data tables from its data segment. They do not run or keep its code.

| Item | Value |
| --- | --- |
| Files | `FB.EXE`, or `DATA/FB.EXE` when `FB.EXE` is absent. The supplied disk has `DATA/FB.EXE`, 128,188 bytes. |
| Byte order | Little-endian |
| Reader | `src/shared/content/floppy_interface.zig` (`loadImage`, `load`). The table of [data tables](#data-tables) gives the modules that use each value. |
| Writer | None |

## Edition

The reader accepts one file only. Its SHA-256 must be
`d5abe9fde0af738d91933a727ad9a0e186210f1ccbf8630092fd80c8b457e777`: the supplied English floppy
release. The file must have at most 256 KiB. The offsets below are valid for this file only.

## Layout

### MZ header

The reader uses two fields of the MZ header:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 8 | 2 | `u16` | The header size, in 16-byte paragraphs. The packed image starts at header size × 16. |
| 22 | 2 | `u16` | The initial code segment: the start of the EXEPACK stub, in paragraphs from the start of the packed image. |

The reader ignores the other fields and does not check the `MZ` signature. The SHA-256 identifies
the file.

### EXEPACK stub header

The reader uses one field of the stub header:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 12 | 2 | `u16` | The size of the unpacked image, in paragraphs. |

The reader ignores the other fields and the rest of the stub. In the EXEPACK format, the rest of
the stub holds the unpacker and the packed relocations. The reader does not apply relocations: the
data tables that it reads contain no segment values.

### Packed image

The packed image starts after the MZ header and ends at the stub. It holds the start of the image
as is, then the packets. At its end, it can have up to 16 fill bytes of value `0xff`. The decoder
reads the packets from the end of the packed image back to its start.

A packet, from its first byte to its last byte:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | n | `u8` | The data. A fill packet: n is 1, the fill byte. A copy packet: n is count, the bytes to copy. |
| n | 2 | `u16` | count: the number of output bytes. |
| n + 2 | 1 | `u8` | The opcode: `0xb0` fills, `0xb2` copies. Bit 0 set: the last packet. |

In the supplied file, the packed image has 126,112 bytes and the unpacked image has 160,928 bytes.

### Data segment

The data segment starts at offset 113,856 (`0x1bcc0`) of the unpacked image. It continues to the
end of the image. In the tables below:

- An offset is from the start of the data segment.
- A pointer is a `u16` offset from the start of the data segment.
- A string is ASCII text with a 0 byte at its end.
- A color bank is 16 `u16` words, one for each color. Bits 8-11 are red, bits 4-7 green and
  bits 0-3 blue. The reader uses each 4-bit value v as the 6-bit DAC value v × 4.
- A 6-bit DAC value c gives the 8-bit value (c × 4) OR (c / 16). For example, v = 15 gives 243.
- The color blocks of a room are in
  [level-palette.md](level-palette.md#give-a-room-its-colors).

#### Data tables

| Offset | Hex | Size | Content | Used by |
| --- | --- | --- | --- | --- |
| 1888 | `0x760` | 234 | 26 music names, 9 bytes each. A name is a string of at most 8 characters ([music.md](music.md)). The reader makes them upper case. | extractor (`scenes.zon`) |
| 3387 | `0xd3b` | 32 | 16 score awards, `u16` each. Bits 4-7 of the flags of a rule select the award; 0 selects no award. | extractor (`extract/level.zig`) |
| 3419 | `0xd5b` | 14 | 7 pointers, one for each level, to a level record. The `u16` at offset 29 of the record is the scene that the level plays when it starts. A value of 76 or more: no scene. The reader ignores the rest of the record. | extractor (`scenes.zon`) |
| 3650 | `0xe42` | 8 | 4 pointers to the names of the sprite libraries. A name is a string of at most 11 characters. The reader makes them upper case. A name is the base name of `DATA/NAME.SPR` and `DATA/NAME.OFF`. | `actor_art`, `character_art`, `level_pack` |
| 3694 | `0xe6e` | 14 | 7 pointers, one for each level, to a library list ([Library list](#library-list)). | extractor (`extract/level.zig`) |
| 3753 | `0xea9` | 8 | 4 pointers, one for each sprite library, to a color bank. | `level_pack` |
| 3889 | `0xf31` | 32 | Actor color bank 1. | `level_pack` (colors `0x40`-`0x4f`) |
| 3921 | `0xf51` | 32 | Actor color bank 2, for a room whose third palette bank differs from that of the room where Conrad starts. | `level_pack` (colors `0x40`-`0x4f`) |
| 3953 | `0xf71` | 32 | Text color bank. | `level_pack` (colors `0xe0`-`0xef`), `continue_artwork`, `cinematic_text`, `scenes/ending` |
| 3985 | `0xf91` | 48 | Interface colors: 16 colors of 3 `u8` (red, green, blue). The 6 high bits of each byte are the DAC value. | `level_pack` (colors `0xf0`-`0xff`) |
| 4064 | `0xfe0` | 12 | 3 demo descriptors ([demo.md](demo.md)). | `demo` |
| 4076 | `0xfec` | 24 | 3 demo start positions ([demo.md](demo.md)). | `demo` |
| 4122 | `0x101a` | 304 | 76 scene records ([Scene record](#scene-record)). | extractor (`scenes.zon`) |
| 4426 | `0x114a` | 75 | The music cue of scenes 0-74: an index into the music names, or `0xff` for no music. | extractor (`scenes.zon`) |
| 4501 | `0x1195` | 62 | 31 pointers to film names. A name is a string of at most 11 characters ([vector-films.md](vector-films.md)). | extractor (`scenes.zon`) |
| 4756 | `0x1294` | 2 × (n + 1) | The final scene list: n `i16` scene numbers, then a negative value. n is at most 16. | extractor (`scenes.zon`) |
| 4781 | `0x12ad` | 147 | The level codes ([Level codes](#level-codes)). | `level_codes`, `level_pack` |
| 4928 | `0x1340` | 7 | The eighth code, which starts the final films ([Level codes](#level-codes)). | `level_codes`, `scenes/ending` |
| 5090 | `0x13e2` | 6 | The level label, which the inventory shows below the score. The reader keeps all 6 bytes. | `inventory_artwork` |
| 5097 | `0x13e9` | var | The world messages ([world-messages.md](world-messages.md)). | extractor (`extract/world_messages.zig`) |
| 8543 | `0x215f` | var | Continue label 1, a string: the title of the continue screen. | `continue_artwork` |
| 8573 | `0x217d` | var | Continue label 2, a string: the label of the time. | `continue_artwork` |
| 8581 | `0x2185` | var | Continue label 3, a string: the retry choice. | `continue_artwork` |
| 8590 | `0x218e` | var | Continue label 4, a string: the abort choice. | `continue_artwork` |
| 8596 | `0x2194` | var | Continue label 5, a string: the score label, which the final films use too. | `continue_artwork`, `scenes/ending` |
| 8998 | `0x2326` | var | The credits stream ([Credits stream](#credits-stream)). | extractor (`scenes.zon`) |

A continue label has at most 47 characters. The film names, music names and library names are
references to other files. They are not text that the game shows.

#### Code notice prefix

The level screen shows a code notice: a 6-byte prefix, then the code of the level
([Level codes](#level-codes)). The prefix is not in the data segment. It is in six bytes inside the
code part of the unpacked image:

| Image offset | Hex | Content |
| --- | --- | --- |
| 9252 | `0x2424` | Prefix byte 1, XOR `0x55`. |
| 9259 | `0x242b` | Prefix byte 2, XOR `0x55`. |
| 9267 | `0x2433` | Prefix byte 3, XOR `0x55`. |
| 9275 | `0x243b` | Prefix byte 4, XOR `0x55`. |
| 9283 | `0x2443` | Prefix byte 5, XOR `0x55`. |
| 9291 | `0x244b` | Prefix byte 6, as is. |

`level_pack` uses the prefix.

### Library list

A list of 2-byte entries, with the byte `0xff` at its end. It has at most 8 entries.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 1 | `u8` | A rule group. |
| 1 | 1 | `u8` | The sprite library (0-3) of the enemies of that group. |

### Scene record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | `0xffff`: the scene plays no film. Else bits 0-14: the index of the film name (0-30). Bit 15: a flag. |
| 2 | 1 | `u8` | The entry of the film to play. |
| 3 | 1 | `u8` | Unknown. The reader ignores it. |

One scene has the flag. The extractor copies it to `scenes.zon`. No code uses it.

### Level codes

The table holds 21 codes of 7 bytes: for each of the 7 levels, one code for each of the 3
difficulties. The levels are in this order: jungle, city, tower, earth_city, spaceport,
alien_surface, alien_base. The difficulties are in this order: easy, normal, expert. The eighth
code follows the table, at offset 4928.

To decode a code, XOR each of its bytes with `0x55`. The text of the code ends at its first 0
byte. Each of the 21 codes must contain a 0 byte, so it has at most 6 characters. The reader does
not check the eighth code for a 0 byte. A code can contain a space.

### Credits stream

The credits are a byte stream with `0xff` at its end. The reader copies it as is.

| Byte | Size | Content |
| --- | --- | --- |
| `0x00` | 1 | The end of a block. |
| `0x01` | 3 | A position: the column, then the row, in 8-pixel cells. |
| `0xfe` | 2 | A hold: the time in timer ticks. |
| `0xff` | 1 | The end of the stream. |
| Other | 1 or more | Text, up to the next `0x00`, `0x01`, `0xfe` or `0xff`. The character `\|` starts a new line. |

## Procedures

### Unpack the image

1. Read `FB.EXE`, or `DATA/FB.EXE` if `FB.EXE` is absent. Check its SHA-256.
2. Find the packed image and the stub from the MZ header. Read the unpacked size from the stub.
3. Make an output of the unpacked size, filled with 0. Copy the packed image to its start.
4. Set the read position R to the end of the packed image. Move R back over at most 16 `0xff`
   bytes.
5. Set the write position W to the end of the output.
6. Read the opcode at R − 1 and the count at R − 3. Move R back by 3 and W back by count.
7. For a fill packet, move R back by 1. Write count copies of the byte at R at W.
8. For a copy packet, move R back by count. Copy count bytes from R to W.
9. If bit 0 of the opcode is 0, do steps 6 to 9 again.
10. R must be equal to W. The bytes before R are the start of the image, as is.

### Find a level code

1. Take the input text. If it has 1 to 6 characters, compare it with each code that is not empty.
   Ignore the case of ASCII letters.
2. The first code that is equal gives the level and the difficulty.
3. If no code is equal and the input is not empty, compare it with the eighth code. Ignore the
   case of ASCII letters.
4. If the eighth code is equal, start the final films.

### Show the code notice

The level screen shows the prefix, then the 7 bytes of the code for the level and the difficulty.
The score page of the final films shows the eighth code.

## Checks

| Condition | Error |
| --- | --- |
| No `FB.EXE` and no `DATA/FB.EXE`. | `NotFound` |
| The file has more than 256 KiB. | `TooLarge` |
| The SHA-256 is not the one of the supplied release. | `UnrecognizedFloppyExecutable` |
| The packed image is empty, larger than the unpacked size, or the unpacked size is more than 1 MiB. | `InvalidPackedExecutable` |
| A packet goes past the start of the input or the output, has another opcode, or R is not W at the end. | `InvalidPackedExecutable` |
| A demo descriptor has a level of 7 or more. | `InvalidDemoLevel` |
| A demo file name has no 0 in 12 bytes. | `InvalidDemoFilename` |
| A demo start room is 64 or more. | `InvalidDemoRoom` |
| A continue label has no 0 in 48 bytes. | `InvalidContinueLabel` |
| A sprite library name has no 0 in 12 bytes. | `InvalidActorLibrary` |
| A library list has more than 8 entries, or a library of 4 or more. | `InvalidLibraryTable` |
| A film index is 31 or more, or a film name has no 0 in 12 bytes. | `InvalidSceneTable` |
| A music cue is not `0xff` and is 26 or more, or a music name has no 0 in 9 bytes. | `InvalidSceneTable` |
| The final scene list has more than 16 scenes, or a scene of 76 or more. | `InvalidEndingList` |
| An item of the credits stream starts at byte 4,094 or after. | `InvalidCredits` |
| One of the 21 level codes has no 0 byte. | `InvalidLevelCode` |

## Quirks

The music cue table has 75 entries, for scenes 0-74, and the film name table follows it. Scene 75
has a film but no cue. The reader gives it no music.

## What the extractor takes

The extractor (`src/extract/root.zig`) reads these values from the executable:

- the score awards and the library lists, for `LEVEL/characters.zon` and `LEVEL/behaviors/*.zon`;
- the scene records, music cues, film names, music names and level records, for `scenes.zon`;
- the final scene list and the credits stream, for `scenes.zon`;
- the world messages, for `messages.zon` ([world-messages.md](world-messages.md)).

[data-set.md](data-set.md) gives the files that it writes.

## Sources

- `src/shared/content/floppy_interface.zig`: the unpacker and the table reader.
- `src/shared/content/level_codes.zig`: the code match.
- `src/shared/content/level_pack.zig`, `continue_artwork.zig`, `inventory_artwork.zig`,
  `actor_art.zig`, `demo.zig`, `src/shared/scenes/ending.zig`: the users of the values.
- `src/extract/root.zig`, `src/extract/level.zig`, `src/extract/world_messages.zig`: the
  extractor.
- flashback-re `docs/floppy-gameplay-entry.md`: the EXEPACK unpack, the palettes, the level label
  and the scene, film and music tables.
- flashback-re `docs/floppy-item-aid.md`: the level code table, its XOR and the code notice.
- flashback-re `docs/current-work.md`: EXEPACK, with the start of the image kept as is.
- flashback-re `docs/floppy-demo.md`: the demo descriptors.
- flashback-re `docs/floppy-cartridge-puzzle.md`: the world message table.
