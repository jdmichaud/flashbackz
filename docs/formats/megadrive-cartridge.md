# Mega Drive cartridge (`MEGADRIVE.MD`)

The user can give the cartridge image of the Mega Drive edition. The game then plays the eight
tunes of the cartridge during play, on emulated Mega Drive chips. The reader accepts one cartridge
only, and it reads only the tunes and the note table.

| Item | Value |
|---|---|
| File | A cartridge image that the user gives with `--megadrive FILE`, or that the standalone build gets with `-Dmegadrive=FILE`. The asset source keeps it under the name `MEGADRIVE.MD`. |
| Byte order | Big-endian |
| Reader | `src/shared/content/megadrive.zig` (`isCartridge`, `Tunes.read`); `src/shared/game.zig` (`loadTunes`); `src/native/cli.zig` (`importCartridge`) |
| Player | `src/shared/audio/megadrive_tunes.zig`, with the chips of `src/shared/audio/megadrive/` |
| Writer | None |

## Identification

The reader accepts only the cartridge `Flashback (Europe) (En,Fr)`, because the position of the
tunes changes with the edition. The command line, the standalone build and the game do these
checks:

1. The size of the file must be 2,097,152 bytes.
2. The SHA-256 digest of the file must be
   `ff8a315882db2bb01fdc876fb5cffb245ae6a999cde063c63ff5ea312e455c67`.

## Layout

The reader uses each address in the cartridge as a file offset. The hexadecimal offsets in
parentheses are the values in the code.

| Offset | Size | Type | Content |
|---|---|---|---|
| 1,457,324 (0x163cac) | 6 × sound effects | record | The sound effect table: one record for each sound effect of the cartridge, by sound effect number |
| 1,547,528 (0x179d08) | 510 | 255 × u16 | The note table |

The reader reads only the records of the sound effects 68 to 75, at the offsets 1,457,732 to
1,457,779. flashback-re `docs/megadrive-music.md` describes the other records.

A sound effect record:

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 4 | u32 | The address of the tune |
| 4 | 2 | u16 | The length. For a tune, it must be 0xffff. |

The note table holds a word for each note from 1 to 255, at 1,547,528 + 2 × (note − 1). The word
holds the block and the frequency number of the note. Its high byte goes to the YM2612 register
0xa4 + channel, and its low byte to 0xa0 + channel.

### The tune

A tune starts at the address of its sound effect record.

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 60 | 15 × u32 | The addresses of the instruments 1 to 15 |
| 60 | 2 | u16 | The number of rows, not 0 |
| 62 | 2 | u16 | The Mega Drive frames in one row, without the tempo ([Playback](#playback)) |
| 64 | 30 | 15 × i16 | The detune of the instruments 1 to 15 |
| 94 | 6 × rows | row | The rows |

The 35 bytes of each of the 15 instruments must be in the file, also for the instruments that the
rows do not use.

A row has one tune cell of 2 bytes for each of the 3 channels:

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 1 | u8 | Channel 1: the instrument, 1 to 15. 0 keeps the last instrument of the channel. |
| 1 | 1 | u8 | Channel 1: the note, 1 to 255, in the note table. 0 gives no note. |
| 2 | 2 | cell | Channel 2 |
| 4 | 2 | cell | Channel 3 |

### The instrument

An instrument has 35 bytes. Bytes 0 to 32 go to the YM2612 registers in this order. In the table,
`c` is the channel: 0, 1 or 2 for the channels 1, 2 and 3. The tune player adds `c` to each register
in the table but 0x22 and 0x28. The four bytes of an operator group go to the four registers in the
order of the register numbers.

| Offset | Size | Type | Content | Register |
|---|---|---|---|---|
| 0 | 1 | u8 | Feedback and algorithm | 0xb0 |
| 1 | 4 | u8 | Detune and multiple of the 4 operators | 0x30, 0x34, 0x38, 0x3c |
| 5 | 4 | u8 | Rate scale and attack rate | 0x50, 0x54, 0x58, 0x5c |
| 9 | 4 | u8 | Amplitude modulation and decay rate | 0x60, 0x64, 0x68, 0x6c |
| 13 | 4 | u8 | Sustain rate | 0x70, 0x74, 0x78, 0x7c |
| 17 | 4 | u8 | Sustain level and release rate | 0x80, 0x84, 0x88, 0x8c |
| 21 | 4 | u8 | Total level | 0x40, 0x44, 0x48, 0x4c |
| 25 | 4 | u8 | SSG-EG | 0x90, 0x94, 0x98, 0x9c |
| 29 | 1 | u8 | Stereo output and modulation sensitivity | 0xb4 |
| 30 | 1 | u8 | LFO, for all channels | 0x22 |
| 31 | 2 | u16 | The frequency. The tune player replaces it with the note's word. | 0xa4, then 0xa0 |
| 33 | 1 | u8 | The length of the note, in frames. 0: no release before the next note. | – |
| 34 | 1 | u8 | The key-on mask of the operators | 0x28, with `c` in the value |

## Read the tunes

1. Read the 255 words of the note table.
2. For each sound effect e from 68 to 75, read its record at 1,457,324 + 6 × e.
3. Refuse the cartridge when the length is not 0xffff.
4. At the address of the tune, read the number of rows and the frames in one row. Refuse a tune
   without rows.
5. Copy the rows.
6. For each instrument from 1 to 15, read its address, copy its 35 bytes and read its detune.

Tune k, from 0 to 7, is the sound effect 68 + k.

## Playback

A level asks for the sound effects 68 to 75 as for the other sound effects (see
[sound-effects.md](sound-effects.md)). With the cartridge and the MUSIC option on, such a request
starts tune id − 68 from its first row at the next frame. The new tune replaces the tune that plays.
The instrument of each channel stays from one tune to the next.

A Mega Drive frame is one vertical blank of an NTSC console: 896,040 cycles of the 53,693,175 Hz
master clock, about 59.92 frames each second. At each frame, the tune player does these steps:

1. When a tune plays and its wait is 0, it reads the next row. Else it decreases the wait by 1.
2. For each cell of the row, an instrument that is not 0 becomes the instrument of the channel.
3. When the cell has a note and the channel instrument is 1 to 15, the channel plays the note.
4. It sets the wait to the frames in one row plus the tempo. After the last row, the tune stops.
5. For each note, it writes `c` to 0x28 (key off). It writes the instrument's bytes 0 to 32 to
   their registers. Then it writes the bitwise OR of `c` and byte 34 to 0x28 (key on).
6. Bytes 31 and 32 hold the note's word from the note table plus the instrument's detune, with
   16-bit wrap.
7. The tune player keeps byte 33 of the instrument as the counter of the channel.
8. For a channel without a new note, a counter above 0 decreases by 1. At 0, the tune player writes
   `c` to 0x28 (key off).

The cartridge adds a tempo value to the frames of each row. On an NTSC console this value is 1,
and the tune player uses 1. Thus a row lasts the frames in one row plus 2 frames.

The chips get the writes of a frame from 148,000 master cycles after the vertical blank, one write
each 2,925 cycles. Each write is the register to port 0, then the value to port 1. The chips read
nothing else of the cartridge: the tunes use no DAC samples and no PSG.

## Checks

| Condition | Error |
|---|---|
| The `--megadrive` file is not there | `error.NotFound` |
| The size or the SHA-256 digest is not the accepted one | `error.UnsupportedCartridge` |
| The file in the asset source is larger than 2,097,152 bytes | `error.TooLarge` |
| The note table, a sound effect record, a tune header, the rows or an instrument go past the end of the file | `error.InvalidCartridge` |
| The length of a sound effect record from 68 to 75 is not 0xffff | `error.InvalidCartridge` |
| A tune has 0 rows | `error.InvalidCartridge` |

## Quirks

- After the counter of a channel gets to 0, the counter takes the value `c`. Thus channel 1 keys off
  one time, channel 2 at each frame and channel 3 at each second frame, until their next note.

## Sources

- `src/shared/content/megadrive.zig`
- `src/shared/audio/megadrive_tunes.zig`
- `src/shared/audio/effects.zig`
- `src/shared/game.zig`
- `src/native/cli.zig`, `src/native/bundle_check.zig`
- `src/shared/audio/megadrive/root.zig`, `synth.zig`
- flashback-re `docs/megadrive-music.md`
