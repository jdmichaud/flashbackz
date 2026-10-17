# Cinematic text (`ENGCINE.BIN`, `ENGCINE.TXT`)

ENGCINE.TXT holds the English strings of the vector films, and ENGCINE.BIN holds the offset of each
string. The film reader puts the strings on the frames as captions and positioned texts, with the
font `FB_TXT.FNT`.

| Item | Value |
| --- | --- |
| Files | `DATA/ENGCINE.BIN` and `DATA/ENGCINE.TXT`. In the supplied game, they have 234 and 4,723 bytes: 117 strings. |
| Byte order | Big-endian |
| Reader | `src/shared/content/cinematic_text.zig` (`load`, `parseStrings`, `Text.layout`), which `src/shared/content/vector_cinematic.zig` calls |
| Writer | None. The files come from the original game. |

## Layout of ENGCINE.BIN

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 × S | u16 × S | The offset in ENGCINE.TXT of each string. Word i gives string i. |

The file size is even and from 2 to 8,192 bytes, so S is 1 to 4,096. The reader accepts the
offsets in any sequence, and two words can give the same offset.

## Layout of ENGCINE.TXT

A string starts at its offset and stops before the next 0x0a byte. The 0x0a byte is not part of
the string. The byte 0x7c (`|`) divides a string into lines. The reader gives each other byte to
the font as a character code ([font.md](font.md)).

A synthetic example: an ENGCINE.BIN of `00 00 00 08` and an ENGCINE.TXT of `AB|CDEF` 0x0a `XYZ`
0x0a give two strings. String 0 has the lines `AB` and `CDEF`, and string 1 is `XYZ`.

In the supplied file, the strings follow one after the other in the sequence of ENGCINE.BIN. A
string has 1 to 7 lines, and a line has at most 30 characters.

## Procedures

### Read the strings

1. Read ENGCINE.BIN and ENGCINE.TXT.
2. Refuse an empty ENGCINE.BIN, or one with an odd size.
3. For each word i, refuse an offset at or after the end of ENGCINE.TXT.
4. Find the first 0x0a at or after the offset. Refuse the file when there is none.
5. String i is the bytes from the offset to that 0x0a.

The reader also reads `DATA/FB_TXT.FNT` and the text color bank of the executable
([executable.md](executable.md#data-tables)). The bank gives the film colors 0xe0-0xef. A film reads
these files at its first caption or positioned text that has a string, and not before.

### Put a string on a frame

1. Divide the string into lines at each `|`. Refuse more than 28 lines, or a line of more than
   255 characters.
2. Find W, the length of the longest line. For a caption, W is 30 when the longest line is
   shorter.
3. Put line k (from 0) of length L at x = x0 + ((W − L) & ~1) × 4 and y = y0 + 8 × k.

So each line moves right by half of W − L, rounded down to a whole character of 8 pixels.

| Text | Command | String number | x0 | y0 | Foreground ink |
| --- | --- | --- | --- | --- | --- |
| Caption | 0x18 | The full u16 | 8 | 179 | 0xef |
| Positioned text | 0x34 | Bits 0-11 of the u16 | 8 + 8 × column | 50 + 8 × row | 0xd0 + bits 12-15 |

In the two commands, the u16 0xffff gives no string. [vector-films.md](vector-films.md) gives
the commands, the caption band, and how long a caption stays.

### Glyph inks

Each character is 8 pixels wide. The pixel inks of a glyph give these film color indexes:

| Glyph ink | Index |
| --- | --- |
| 0x0 | None: the pixel stays as it is |
| 0x2 | 0xe2, the shadow |
| 0xf | The foreground ink of the text |
| Other | 0xe0 + the glyph ink |

The texts do not clip to the film viewport. The replay mode of `src/shared/scenes/ending.zig`
does not show the captions and the positioned texts.

## Checks

| Error | The reader refuses |
| --- | --- |
| `TooLarge` | An ENGCINE.BIN above 8,192 bytes, an ENGCINE.TXT above 65,536 bytes, or an FB_TXT.FNT above 16,384 bytes |
| `InvalidCinematicStrings` | An empty ENGCINE.BIN, or one with an odd size |
| `InvalidCinematicTextOffset` | An offset at or after the end of ENGCINE.TXT |
| `UnterminatedCinematicText` | A string without a 0x0a after it |
| `InvalidCinematicText` | A string number of S or more, in a film command |
| `CinematicTextTooLarge` | A string of more than 28 lines, or a line of more than 255 characters |
| `MissingGlyph` | A character that the font does not have, when the player draws it |
| The errors of [font.md](font.md) and [executable.md](executable.md) | An FB_TXT.FNT or an FB.EXE that its reader refuses |

## Quirks

- When W − L is odd, the line is 4 pixels to the left of its exact center.
- A caption puts its lines at the center of 30 characters, also when all its lines are shorter.
- The caption command uses all 16 bits as the string number. The positioned text command uses
  bits 0-11, and its bits 12-15 select the ink.

## Sources

- Code: `src/shared/content/cinematic_text.zig`, `src/shared/content/vector_cinematic.zig`
  (`Builder.caption`, `Builder.positionedText`), `src/shared/vector_film.zig` (`drawText`),
  `src/shared/render/text.zig`.
- Research in flashback-re: `docs/floppy-holocube-recording.md` (Text and frame evidence),
  `docs/rules/engine-ending-zoom.md` (3.3 and 3.6).
