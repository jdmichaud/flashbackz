# Vector films (`*.CMD`, `*.POL`)

A film is a pair of files with the same base name. The CMD file holds the commands, and the POL
file holds the shapes, the vertices and the palettes. The reader turns one film entry into a list
of film frames: still pictures with hold times. The title menu, the levels, the ending and the
continue screen show these film frames.

| Item | Value |
| --- | --- |
| Files | `DATA/name.CMD` and `DATA/name.POL`. The supplied game has 29 pairs, all of them in ABA archives ([aba-archive.md](aba-archive.md)). The extractor copies them unchanged into the data set's `films/`, and the game plays them from there ([data-set.md](data-set.md)). |
| Byte order | Big-endian |
| Reader | `src/shared/content/vector_cinematic.zig` (`load`, `compile`), with `src/shared/content/cinematic_transform.zig`. The result type is `film.Frame` in `src/shared/vector_film.zig`. |
| Writer | None. The extractor copies the original files (`src/extract/root.zig`, `writeFilms`). |

## Layout of the CMD file

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | N, the number of entries in the entry table, 0 to 1024 |
| 2 | 2 × N | u16[N] | The entry table: the start of each entry, from the command base |
| 2 + 2 × N | to the end | bytes | The commands. Offset 2 + 2 × N is the command base. |

Entry 0 always starts at the command base: the reader ignores the first word of the entry table.
Entry e (1 to N − 1) starts at the command base plus word e of the table. When N is 0, the file
has one entry, entry 0, and the commands start at offset 2. The jump targets of the page loops
also count from the command base.

In the supplied files, 19 CMD files have no entry table. The other 10 have 2 to 20 entries, and
the first word of each table is 0.

### Commands

A command is one command byte, then its operands, if any. The documents name a command by its
byte, for example 0x10. In the command byte:

- Bit 7 set ends the film. The film ends at the first command byte with bit 7 set. A page loop
  can also end the film.
- Bits 2-6 are the opcode. The opcode is not a separate byte: it is the command byte divided by
  4. For example, the byte 0x04 is opcode 0x01, and its operand is the next byte.
- Bits 0-1 must be 0.

| Command byte | Opcode (bits 2-6) | Operands, in the bytes that follow | Action |
| --- | --- | --- | --- |
| 0x00 | 0x00 | None | Present the picture after 4 ticks, then start a new picture. |
| 0x04 | 0x01 | u8 mode | Set the background mode. A mode other than 0 starts a new background. |
| 0x08 | 0x02 | u8 n | Wait n × 4 ticks. |
| 0x0c | 0x03 | Shape operands | Draw a shape without scale or rotation. |
| 0x10 | 0x04 | u8 palette, u8 destination | Set 16 film colors from a POL palette. |
| 0x14 | 0x05 | None | The same as 0x00. |
| 0x18 | 0x06 | u16 text | Show the caption band and a caption. |
| 0x1c | 0x07 | None | Nothing. |
| 0x20 | 0x08 | 3 bytes | Nothing. The reader does not use the 3 bytes. |
| 0x24 | 0x09 | Page loop | Present the picture after 4 ticks, start a new picture, then do the page loop. |
| 0x28 | 0x0a | Shape operands | Draw a scaled shape. |
| 0x2c | 0x0b | Shape operands | Draw a rotated shape. |
| 0x30 | 0x0c | None | Present the shown picture again after 9 ticks (a hold). |
| 0x34 | 0x0d | u16 text, then u8 column and u8 row | Add a positioned text. The text 0xffff has no column and row bytes, and adds nothing. |
| 0x38 | 0x0e | Page loop | Do the page loop. |
| 0x80-0xff | | None | The film ends. The supplied files use 0xff. |

The reader refuses the command bytes 0x3c to 0x7c (the opcodes 0x0f to 0x1f).

### Shape operands (0x0c, 0x28, 0x2c)

The fields follow in this order. A field that is not there takes no bytes.

| Order | Size | Type | When | Content |
| --- | --- | --- | --- | --- |
| 1 | 2 | u16 | Always | The shape reference |
| 2 | 4 | i16, i16 | Reference bit 15 | x and y, added to the film origin (8, 50) |
| 3 | 2 | u16 | Scaled, or rotated with bit 14 | The scale word: the factor minus 512 |
| 4 | 2 | u8, u8 | Scaled or rotated | The pivot x and y |
| 5 | 2 | u16 | Rotated | The first angle, in degrees |
| 6 | 2 | u16 | Rotated with bit 13 | The second angle. Without it, the angle is 180. |
| 7 | 2 | u16 | Rotated with bit 12 | The third angle. Without it, the angle is 90. |

| Reference bits | Content |
| --- | --- |
| 0-10 | The shape number in the POL shape table |
| 11 | Must be 0 |
| 12-14 | Rotated shape: the flags of the fields 7, 6 and 3. Placed and scaled shapes: must be 0. |
| 15 | The x and y words follow |

A rotated shape without bit 14 has the factor 512. The pivot is in shape coordinates, before the
placement.

### Page loop operands (0x24, 0x38)

The reader accepts three forms. A target is an i16 from the command base. A negative target is
the end of the film.

| Form | Bytes | Effect |
| --- | --- | --- |
| A | 0xff | No loop. |
| B | 0x00, i16 target < 0 | The film ends here. |
| C | 0x80, i16 target, 0x00, i16 fallback ≥ 0, 0xff | After a confirmation, go to the target. Without one, go to the fallback. |

A confirmation is a fresh press of Return, Space or Shift. With the joystick option, the pad
buttons A, B and X also confirm (`src/shared/scenes/story.zig`). flashback-re
`docs/floppy-cinematic-input.md` gives 0x80 as the mask of these keys. Only LOG, MAP and MISSIONS
use form C in the supplied files.

### Text operands (0x18, 0x34)

[cinematic-text.md](cinematic-text.md) gives the strings and the layout of the texts.

| Command | Field | Content |
| --- | --- | --- |
| 0x18 | u16 | The string number of the caption. 0xffff shows the band without a caption. |
| 0x34 | u16, bits 0-11 | The string number |
| 0x34 | u16, bits 12-15 | The text color: 0xd0 plus this value |
| 0x34 | u8 column, u8 row | The place, in units of 8 pixels from the film origin (8, 50) |

## Layout of the POL file

### Header

All offsets in the POL file count from the start of the file.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | Ignored. It is 0 in the supplied files. |
| 2 | 2 | u16 | The offset of the shape table |
| 4 | 2 | u16 | Ignored. It is 0 in the supplied files. |
| 6 | 2 | u16 | The offset of the palettes |
| 8 | 2 | u16 | Ignored. It is 0 in the supplied files. |
| 10 | 2 | u16 | The offset of the vertex table |
| 12 | 2 | u16 | Ignored. It is 0 in the supplied files. |
| 14 | 2 | u16 | The shape base |
| 16 | 2 | u16 | Ignored. It is 0 in the supplied files. |
| 18 | 2 | u16 | The vertex base |

The file does not give the number of shapes, vertex records or palettes. The supplied files have
the blocks in this order: header, shape table (offset 20), palettes, shape records, vertex table,
vertex records. The reader does not need this order.

### Tables

| Table | Entry | Content |
| --- | --- | --- |
| Shape table | u16 for each shape | The offset of the shape record from the shape base |
| Vertex table | u16 for each vertex record | The offset of the vertex record from the vertex base |
| Palettes | 32 bytes for each palette | 16 colors, one u16 for each color |

### Shape record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | u16 | The number of primitives, 0 to 1024 |
| 2 | | Primitive[] | The primitives, one after the other |

A primitive has these fields, in this order:

| Order | Size | Type | When | Content |
| --- | --- | --- | --- | --- |
| 1 | 2 | u16 | Always | The vertex reference: bits 0-13 the vertex record number, bit 14 see-through, bit 15 an offset follows |
| 2 | 4 | i16, i16 | Bit 15 | The x and y offset, added to the first point of the vertex record |
| 3 | 1 | u8 | Always | The color, 0x00 to 0x0f |

### Vertex record

Bit 7 of the kind byte selects a polygon or an ellipse.

| Offset | Size | Type | Content (polygon, kind bit 7 is 0) |
| --- | --- | --- | --- |
| 0 | 1 | u8 | The kind: the number of steps, 0 to 63 |
| 1 | 2 | i16 | x of the first point |
| 3 | 2 | i16 | y of the first point |
| 5 | 2 × kind | (i8, i8)[kind] | The steps: dx and dy from the point before |

| Offset | Size | Type | Content (ellipse, kind bit 7 is 1) |
| --- | --- | --- | --- |
| 0 | 1 | u8 | The kind. The reader ignores bits 0-6. |
| 1 | 2 | i16 | x of the center |
| 3 | 2 | i16 | y of the center |
| 5 | 2 | i16 | The x radius, 0 or more |
| 7 | 2 | i16 | The y radius, 0 or more |

A polygon of one point is a pixel, and a polygon of two points is a line.

### Palette color

| Bits | Content |
| --- | --- |
| 0-3 | Blue, 0 to 15 |
| 4-7 | Green, 0 to 15 |
| 8-11 | Red, 0 to 15 |
| 12-15 | Not a component |

To get the 8-bit components of a color:

1. When the full word is 0, each 6-bit value is 0. Else each 6-bit value v is 4 × c + 3, where
   c is the component.
2. Each 8-bit component is (v << 2) | (v >> 4).

## The film frame

A film frame is 256 × 224 pixels. The viewport starts at (8, 50), and it is 240 pixels wide and 128
rows high. Index 0xc0 fills the viewport, then the primitives clip to it. The texts do not clip to
the viewport. The caption band covers the rows 178 to 202 on the full width, in index 0xc0.

## The film colors

A film frame has 256 colors. At the start of a film, all of them are black.

| Index | Content |
| --- | --- |
| 0x00-0xbf | Black. The area outside the viewport uses index 0x00. |
| 0xc0-0xcf | Command 0x10 with destination 1: the background colors. Index 0xc0 also fills the viewport and the caption band. |
| 0xd0-0xdf | Command 0x10 with destination 0: the foreground colors and the text colors of the positioned texts. |
| 0xe0-0xef | The text color bank of the executable ([executable.md](executable.md#data-tables)), set at the first text command that has a string. |
| 0xf0-0xff | Black |

Command 0x10 reads palette b at the palette offset plus 32 × b. It sets 16 colors from 0xd0 for
destination 0, or from 0xc0 for destination 1. The colors of a film frame are a copy of the film
colors at its present.

## Procedures

### Read one entry

1. Read N. Refuse N above 1024. Refuse an entry number of N or more, or an entry other than 0
   when N is 0.
2. Find the start of the entry (see the CMD layout).
3. Set the start state. The new picture, the saved background and the shown picture are empty.
   All film colors are black. The background mode and the wait sum are 0, and no caption shows.
4. Add film frame 0. It is empty and black. Its hold is the time before the first present. The
   ending plays the films of its list in replay mode: each picture shows for the time of its own
   present, then again every 2 ticks while the film waits ([Time](#time)). The replay mode does
   not present film frame 0.
5. Do the commands from the start of the entry. Stop at a command byte with bit 7 set, or when a
   page loop ends the film. Refuse more than 100,000 commands.
6. Add the wait sum to the hold of the last film frame.

The new picture is the list of primitives and texts that the next present shows. The shown
picture is the list of the last present.

### Present

A present has its own time: 4 ticks for 0x00, 0x14 and 0x24, and 9 ticks for 0x30.

1. Add the wait sum and the time of the present to the hold of the last film frame.
2. Set the wait sum to 0.
3. Add a film frame: a copy of the new picture, the film colors, the caption and the caption band.
4. Keep the new picture as the shown picture.

So the hold of a film frame is the time from its present to the next present.

### Start a new picture

The commands 0x00, 0x14 and 0x24 start a new picture after the present. Command 0x04 with a
mode other than 0 also starts it.

- In background mode 0, the new picture becomes a copy of the saved background.
- In another mode, the new picture becomes empty, and the caption and the caption band go
  away.

Command 0x30 is different. Before its present, the new picture becomes a copy of the shown
picture. The commands after it draw on top of that picture.

### Draw a shape

1. Find the shape record: the shape base plus the shape table word of the shape number.
2. For each primitive, read the vertex reference, the offset and the color. Refuse a color above
   0x0f. The color index is the color plus 0xd0 in background mode 0, and the color plus 0xc0 in
   another mode.
3. Find the vertex record: the vertex base plus the vertex table word of the record number. Read
   the kind and the first point, and add the offset of the primitive to the first point.
4. For a polygon, add each step to the point. A step with dy 0 adds no point when the step after
   it also has dy 0. Each point that the polygon keeps goes through the projection (rotation,
   then scale), then the placement.
5. For an ellipse, find the center and the radii (see the ellipse procedure below). Then add the
   placement to the center.
6. The primitive is see-through when bit 14 of its vertex reference is set and its color index is
   above 0xc7. Only an ellipse or a polygon of 3 points or more can be see-through. A see-through
   primitive sets bit 3 of each pixel under it (pixel | 0x08). Another primitive sets each pixel to
   its color index.
7. Add the primitive to the new picture.
8. After the last primitive, in a background mode other than 0, copy the new picture to the saved
   background.

The placement is the film origin (8, 50), plus the x and y words of the shape operands. The
additions wrap around at 16 bits.

### Captions and texts

- Command 0x18 turns the caption band on and sets the caption: the lines of the string, or no lines
  for 0xffff. The band and the caption stay on the film frames after it, until a picture starts in a
  background mode other than 0. The next 0x18 replaces them.
- Command 0x34 adds a text to the new picture for each line of its string. These texts are
  part of the picture, as the primitives are.
- The film player is the code that plays a film (`src/shared/scenes/vector_player.zig`). It draws
  the primitives and texts of a film frame in their sequence, then the band, then the caption.

### Projection

A scaled shape uses the scale. A rotated shape uses the rotation, then the scale. A placed shape
has no projection.

The scale has a factor f in units of 1/512: f = (scale word + 512) as an i16, with wrap around.
The anchor o is the first point that the scale changes in this shape command. For each axis:

```text
R(d)  = (d × f × 128 + 32768) >> 16
p'    = pivot − R(pivot − o) + R(p − o)
```

The arithmetic is i32 with wrap around, and `>>` is an arithmetic shift (toward minus infinity).
The factor 512 keeps each point.

The rotation uses the three angles a (first), b (second) and c (third), and a Q8 table: 256 is
1.0. S is the sine table and C the cosine table.

```text
xx = ((C(a) × C(b)) >> 8) − ((((C(c) × S(a)) >> 8) × S(b)) >> 8)
xy = ((S(a) × C(b)) >> 8) + ((((C(c) × C(a)) >> 8) × S(b)) >> 8)
yx = (S(c) × S(a)) >> 8
yy = (−S(c) × C(a)) >> 8

dx = pivot.x − p.x
dy = pivot.y − p.y
p'.x = pivot.x + ((dx × xx + dy × xy) >> 8)
p'.y = pivot.y + ((dx × yx + dy × yy) >> 8)
```

The arithmetic is i32, and the results are cut to 16 bits. The angles 0, 180 and 90 give the
identity, because the matrix has −256 on its diagonal and acts on pivot − p.

The Q8 table rule, for whole degrees 0 to 359:

- S(d) is the integer part (toward 0) of 256 × sin(d degrees). The exact points have these
  values: S(0) = S(180) = 0, S(30) = S(150) = 127, S(90) = 256, S(210) = −128, S(270) = −256 and
  S(330) = −127.
- C(d) is S((d + 90) mod 360), but C(300) is 128.

### Ellipse in a scaled or rotated shape

1. In a rotated shape, rotate the center, but keep only the new y. The center keeps its own x.
2. Scale three points: the center, the top point (x, y − ry) and the left point (x − rx, y).
3. The new center is the scaled center. The new rx is center.x − left.x, and the new ry is
   center.y − top.y. Refuse a negative radius.

The rotation does not change the radii.

### Time

The holds, the waits and the presents count timer ticks ([README.md](README.md#terms)). The film
player shows each film frame for its hold, then waits for the next display refresh (about 59.94
Hz). The film ends after the hold of its last film frame.

In replay mode (`src/shared/scenes/ending.zig`), the credits type one step at each present. For
the replay mode, a film frame also keeps:

- the time of its own present (4 or 9 ticks);
- the number of 2-tick presents of the waits after it: 2 × n + 1 for each wait of n;
- the kind of its present: picture (0x00, 0x14), page (0x24) or hold (0x30);
- whether a new background (0x04 with a mode other than 0) came before it.

### Page loop

The reader resolves form C at import. "Here" is the offset of the command byte, and the targets
count from the command base.

1. Target ≥ 0, target at or before here, fallback after here (a release loop): go on at the
   fallback.
2. Target < 0, fallback after here: mark the last film frame "a confirmation ends the film". Go on
   at the fallback.
3. Fallback at or before here, and target < 0 or after here: the last film frame closes an input
   loop.
   Go on at the target, or end the film when the target is negative.
4. Refuse all other cases.

For case 3, the fallback must be a command that the reader did before. The loop starts at the film
frame that the first present after the fallback added. When no present came after the fallback, the
loop has only the last film frame. The loop time is W + H − F:

- W is the wait sum.
- H is the hold of the film frame before the loop start. H is 0 when no present came after the
  fallback.
- F is the wait sum at the fallback.

The reader refuses a negative loop time.

The film player does these steps at the end of a film frame:

1. When the film frame has the mark and a confirmation came, the film ends.
2. When the film frame closes a loop without a confirmation, the film player goes to the loop
   start after the loop time.
3. Else the film player goes to the next film frame after the hold.

A loop of one film frame with a loop time of 0 waits for a confirmation without a time limit.

## Film entries and scene records

The code names five films directly. All of them use entry 0.

| Film | Code | Use |
| --- | --- | --- |
| LOGOS | `src/shared/scenes/front_end.zig` | The first film of the title |
| INTRO1, INTRO2 | `src/shared/scenes/front_end.zig` | The introduction. The title stops with an error when one of their 4 files is not there. |
| OVER | `src/shared/scenes/front_end.zig` | The game over film, after Abort |
| SCORE | `src/shared/content/continue_artwork.zig` | The last film frame is the still picture of the continue screen. Its colors 0xe0-0xef are the text colors of the executable. |

The other films come from the 76 scene records of the executable
([executable.md](executable.md#scene-record)). A scene record gives the index of a film name (0 to
30) and an entry, or no film. The film name is the base name of the CMD and POL files. A
separate table gives the music of each scene ([music.md](music.md)). The extractor copies these
tables to `scenes.zon` in the data set ([data-set.md](data-set.md)), and
`src/shared/scenes/level.zig` and `src/shared/scenes/ending.zig` read that file.

At each start, `src/shared/content_check.zig` imports each film entry that a scene names, and it
stops the start when the reader refuses one. A film can have more entries than the scenes use.

## Checks

| Error | The reader refuses |
| --- | --- |
| `NotFound` | A CMD or POL file that is not there |
| `NoSpaceLeft` | A path `DATA/name.CMD` or `DATA/name.POL` longer than 64 bytes |
| `TooLarge` | A CMD or POL file above 65,536 bytes |
| `TruncatedCinematic` | A read past the end of the CMD or POL file, also for the step after a horizontal step |
| `InvalidCinematicEntry` | N above 1024, or an entry number of N or more (1 or more when N is 0) |
| `UnsupportedCinematicCommandFlags` | A command byte with bit 0 or 1 set |
| `UnsupportedCinematicCommand` | The command bytes 0x3c to 0x7c (the opcodes 0x0f to 0x1f) |
| `UnsupportedCinematicShapeFlags` | Reference bit 11, or bits 12-14 in a placed or scaled shape |
| `UnsupportedCinematicAngle` | An angle of 360 or more |
| `InvalidCinematicPalette` | A palette destination other than 0 and 1 |
| `InvalidCinematicInk` | A primitive color above 0x0f |
| `UnsupportedCinematicPolygon` | A polygon kind of 64 to 127 |
| `InvalidCinematicEllipse` | A negative radius, before or after the scale |
| `UnsupportedCinematicInteraction` | A page loop that is not form A, B or C, a case-4 loop, a loop back to a command that the reader did not do, or a negative loop time |
| `CinematicTooLarge` | More than 1,024 primitives in a shape, 10,000 film frames, 1,000,000 primitives in all the picture copies, about 2,000,000 points in all, or 100,000 commands without an end |
| `Overflow` | A hold above the u32 range |
| `CinematicTextRequired` | A text command with a string in `compile`, which has no files for the text |

The text commands can also give the errors of [cinematic-text.md](cinematic-text.md). The film
player refuses a film without film frames (`EmptyFilm`) and an input loop without time
(`UnboundedFilmInputLoop`), in `film.View.validate`. The renderer refuses a point beyond ±4096 in a
polygon of 3 points or more (`UnsupportedVectorExtent`, `src/shared/render/indexed_shapes.zig`).

## Quirks

- Entry 0 starts at the command base, whatever the first word of the entry table holds.
- A horizontal step that another horizontal step follows adds no point. This changes the result
  of a scaled or rotated polygon.
- The first point of the shape command anchors the scale, together with the pivot.
- In a rotated shape, an ellipse center takes only the rotated y, and the radii do not turn.
- The Q8 table is not symmetric on its exact points: S(30) is 127, but C(300) is 128.
- A see-through polygon of one or two points uses its color index.
- The caption shows its bottom pixel row only on every second present after command 0x18. A hold
  (0x30) copies the shown page to the other page, so its film frame shows the same row as the film
  frame before it. The two display pages of the original cause this (`film.Frame.caption_tail`).

## Sources

- Code: `src/shared/content/vector_cinematic.zig`, `src/shared/content/cinematic_transform.zig`,
  `src/shared/vector_film.zig`, `src/shared/scenes/vector_player.zig`,
  `src/shared/scenes/front_end.zig`, `src/shared/content/continue_artwork.zig`,
  `src/shared/content/floppy_interface.zig` (`scenes`), `src/shared/content_check.zig`.
- Research in flashback-re: `docs/rules/engine-ending-zoom.md` (3.3 to 3.6),
  `docs/floppy-cinematic-input.md`, `docs/rules/engine-music.md` (2.1, 2.4),
  `docs/rules/engine-presentation.md` (7.2), `docs/floppy-hazard-defeat.md`.
