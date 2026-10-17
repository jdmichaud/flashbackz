# Music (`.PRF`, `.MID`, `.INS`)

A music cue has three kinds of file. The profile (`.PRF`) names a MIDI file and up to 16
instruments, and gives the tick length. The MIDI file holds the notes, and an instrument file
(`.INS`) holds the OPL2 values of one instrument. The title menu, the films and the end sequence
play the cues on an emulated OPL2 chip.

| Item | Value |
|---|---|
| Files | `<cue>.PRF`; the MIDI file that the profile names (the game's files use `.MID`); `<instrument>.INS`. The game's files are in the ABA archives (see [aba-archive.md](aba-archive.md)). |
| Byte order | `.PRF` and `.INS`: little-endian. MIDI file: big-endian. |
| Reader | `src/shared/content/music.zig` (`load`, `Profile.parse`, `decode`, `instrument`), into the types of `src/shared/content/score.zig` |
| Player | `src/shared/audio/music_player.zig` |
| Writer | None |

## File names

The reader starts from the name of a cue. The title menu uses the cues `PRESENT3`, `INTROL3`,
`GAMEOVE3` and `OPTION3`. A film and the end sequence use the `music` name of their film in
`scenes.zon` (see [data-set.md](data-set.md)).

1. The profile is `<cue>.PRF`. The reader does not shorten the cue name.
2. The MIDI file has the name at offset 550 of the profile. This name contains the extension.
3. An instrument file has the first 8 characters of the instrument name, then `.INS`. DOS keeps
   only 8 characters of a file name. Some instrument names in the game's profiles have 9
   characters.
4. For each file, the reader makes the path `DATA/<name>` and changes it to capitals.
5. When the asset source does not have that file, the reader reads `<name>` at the root.

A name can contain only letters, digits, `_`, `.` and `-`.

## Profile (`.PRF`)

The size of a profile is 752 or 753 bytes. The game's profiles have 753 bytes, but one has 752.

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 480 | 16 × 30 bytes | The instrument names of the slots 0 to 15. Each name ends with a 0 byte. An empty name gives an empty slot. |
| 480 | 32 | 16 × u16 | The pitch additions |
| 512 | 32 | 16 × u16 | The velocity additions |
| 544 | 2 | u16 | `interval`: the timer interrupts in one tick, 1 to 1000 |
| 546 | 2 | – | Unknown. The reader ignores it. |
| 548 | 2 | u16 | `bar_ticks`: the ticks in one bar, not 0 |
| 550 | 20 | bytes | The name of the MIDI file. It ends with a 0 byte. |
| 570 | 2 | u16 | The program switch. 0 is off. |
| 572 | 32 | 16 × u16 | The program of each instrument slot |
| 604 | 128 | – | Unknown. The reader ignores it. |
| 732 | 16 | 16 × u8 | One byte for each part. 0: the part repeats. Not 0: the part plays one time. |
| 748 | 4 | i32 | `limit`. Positive: the cue stops. Negative: the cue starts again. 0: no limit. |
| 752 | 0 or 1 | – | Unknown. The reader ignores it. |

### The slot of a part

Each MIDI track is a part. A part plays the instrument of its current slot (`binding` in the code).
At the start of the track, the slot is the index of the part.

- When the program switch is 0, the reader ignores the program changes.
- When the program switch is not 0, a program change to program p changes the slot of the part.
  The new slot is the first slot i with p in the word at 572 + 2 × i. When no slot has p, the slot
  does not change.

### The additions

The reader adds bits 7-0 of an addition word to the pitch and to the velocity of each note.

- When the program switch is 0, the part index selects the words: 480 + 2 × part and 512 + 2 ×
  part.
- When the program switch is not 0, the current slot of the part selects the words.
- The pitch is (pitch + addition) mod 256. The velocity is (velocity + addition) mod 256, with a
  limit of 127.

## MIDI file

The MIDI file is a Standard MIDI File of format 0 or 1. This section gives the part of the
standard that the reader uses.

The header chunk:

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 4 | tag | `MThd` |
| 4 | 4 | u32 | The chunk size: 6 |
| 8 | 2 | u16 | The format: 0 or 1 |
| 10 | 2 | u16 | The number of tracks: 1 to 16 |
| 12 | 2 | u16 | The division. The reader ignores it. |

One track chunk follows for each track. No other chunk can come between them, and no data can
come after the last track.

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 4 | tag | `MTrk` |
| 4 | 4 | u32 | The size of the events |
| 8 | size | events | The events |

An event is a delta time, then the event. The delta time is a variable-length quantity of 1 to 4
bytes. The tick of an event is 1 plus the sum of the delta times up to and with the event.

The event codes:

| Status | Data bytes | What the reader does |
|---|---|---|
| 0x80-0x8f (note off) | pitch, velocity | Releases the note: the pitch with its addition |
| 0x90-0x9f (note on) | pitch, velocity | Velocity 0: releases the note. Else plays the note, with the additions, on the instrument of the part's slot. |
| 0xa0-0xaf | 2 | Ignores the event |
| 0xb0-0xbf | 2 | Ignores the event |
| 0xc0-0xcf (program change) | program | Changes the slot of the part (see above). Gives no event. |
| 0xd0-0xdf | 1 | Ignores the event |
| 0xe0-0xef (pitch bend) | low 7 bits, high 7 bits | Bends the part's notes by the 14-bit value |
| 0xf0, 0xf7 (SysEx) | a length, then data | Ignores the event |
| 0xff (meta) | a type, a length, then data | Type 0x2f, end of track: the length must be 0. Ignores the other types. |
| 0xf1-0xf6, 0xf8-0xfe | – | Refuses the file |

- The reader ignores the MIDI channel in bits 3-0 of the status. The part selects the instrument.
- A data byte (below 0x80) in the place of a status byte repeats the last status from 0x80 to
  0xef: the running status. A meta event or a SysEx event does not cancel the running status.
- The end of track event must be the last event of the chunk.
- The tempo meta events and the division do not change the speed. The `interval` of the profile
  sets it.

### Repeat of a part

When the byte at 732 + part is 0, the part repeats. The length of the part is the sum of all its
delta times. The period is the first multiple of `bar_ticks` above the length. Example
(synthetic): with `bar_ticks` 16, a length of 40 gives a period of 48, and a length of 48 gives 64.

## Instrument (`.INS`)

The size of an instrument file is 80 bytes.

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 1 | u8 | The percussion mode. 0: a melodic instrument. Not 0: a drum. |
| 1 | 1 | u8 | For a drum: 6 bass drum, 7 snare drum, 8 tom-tom, 9 cymbal, 10 hi-hat. Else ignored. |
| 2 | 26 | operator | The modulator |
| 28 | 26 | operator | The carrier |
| 54 | 20 | – | Unknown. The reader ignores it. |
| 74 | 2 | u16 | The modulator waveform |
| 76 | 2 | u16 | The carrier waveform |
| 78 | 2 | – | Unknown. The reader ignores it. |

An operator record has 13 words (u16):

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 2 | u16 | Key scale level |
| 2 | 2 | u16 | Frequency multiple |
| 4 | 2 | u16 | Feedback. The reader ignores it in the carrier. |
| 6 | 2 | u16 | Attack rate |
| 8 | 2 | u16 | Sustain level |
| 10 | 2 | u16 | Sustain: not 0 keeps the note at the sustain level |
| 12 | 2 | u16 | Decay rate |
| 14 | 2 | u16 | Release rate |
| 16 | 2 | u16 | Total level (the attenuation, 0 to 63) |
| 18 | 2 | u16 | Tremolo: not 0 is on |
| 20 | 2 | u16 | Vibrato: not 0 is on |
| 22 | 2 | u16 | Key scale rate: not 0 is on |
| 24 | 2 | u16 | Connection: 0 makes the two operators sound in parallel. The reader ignores it in the carrier. |

### The OPL2 registers

The player writes an operator to the registers of its operator offset (`op`). The table gives the
bits of each register and the operator field (by its offset) that sets them.

| Register | Bits | Value |
|---|---|---|
| 0x20 + op | 7 | 1 when the tremolo (18) is not 0 |
| | 6 | 1 when the vibrato (20) is not 0 |
| | 5 | 1 when the sustain (10) is not 0 |
| | 4 | 1 when the key scale rate (22) is not 0 |
| | 3-0 | Bits 3-0 of the multiple (2) |
| 0x40 + op | 7-6 | Bits 1-0 of the key scale level (0) |
| | 5-0 | Bits 5-0 of the total level (16), changed by the volume (see below) |
| 0x60 + op | 7-4 | Bits 3-0 of the attack rate (6) |
| | 3-0 | Bits 3-0 of the decay rate (12) |
| 0x80 + op | 7-4 | Bits 3-0 of the sustain level (8) |
| | 3-0 | Bits 3-0 of the release rate (14) |
| 0xc0 + channel | 7-1 | Bits 6-0 of the modulator's feedback (4). A feedback from 0 to 7 uses bits 3-1. |
| | 0 | 1 when the modulator's connection (24) is 0 |
| 0x0e + op | 1-0 | Bits 1-0 of the waveform word. See the quirks. |

The channels and their operator offsets:

| Channel | Use | Modulator `op` | Carrier `op` |
|---|---|---|---|
| 0 to 5 | Melodic notes | 0x00, 0x01, 0x02, 0x08, 0x09, 0x0a | 0x03, 0x04, 0x05, 0x0b, 0x0c, 0x0d |
| 6 | Bass drum | 0x10 | 0x13 |
| 7 | Snare drum | – | 0x14 |
| 8 | Tom-tom | – | 0x12 |
| 9 | Cymbal | – | 0x15 |
| 10 | Hi-hat | – | 0x11 |

- For a melodic instrument and the bass drum, the player writes the modulator, register 0xc0 and the
  carrier.
- For the other drums, the player writes only the carrier record, to the one operator of the drum.

### The volume of a note

The player calculates the total level of an operator for each note:

1. volume = ⌊velocity × master / 64⌋. The master volume is 0 to 63. It is 48 at the start, and the
   keypad + and − keys change it.
2. level = 63 − ⌊(2 × (63 − total level) × volume + 127) / 254⌋.

The player always uses this level for the carrier. It uses it for the modulator only when the
modulator's connection is 0. Else the modulator keeps its total level. For register 0xc0 the reader
tests the whole connection word, but for the volume it tests only the low byte (offset 26 of the
file).

### The frequency of a note

For a pitch p, the F-number is entry p mod 12 of this table, and the block is ⌊p / 12⌋.

| Note | C | C# | D | D# | E | F | F# | G | G# | A | A# | B |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F-number | 343 | 364 | 385 | 408 | 433 | 459 | 486 | 515 | 546 | 579 | 614 | 650 |

- A note first writes the registers of its instrument.
- Then a melodic note writes 0 to register 0xb0 + channel (key off). Then it writes bits 7-0 of
  the F-number to register 0xa0 + channel. Then it writes the block in bits 4-2, bits 9-8 of the
  F-number and the key-on bit 0x20 to register 0xb0 + channel.
- Then a drum clears its bit in register 0xbd (key off). Then it writes the frequency to chip
  channel 6 (bass drum), 7 (snare drum, hi-hat) or 8 (tom-tom, cymbal). Then it sets its bit in
  register 0xbd: bit 4 bass drum, bit 3 snare drum, bit 2 tom-tom, bit 1 cymbal, bit 0 hi-hat.
  Bit 5 of that register sets the rhythm mode, and each drum write sets it.
- The player does not limit the block to 3 bits. A pitch of 96 or more gives a block above 7.

## Playback

The music timer runs at 1,193,182 / 532 Hz. A tick is `interval` periods of the timer. Thus an event
at tick t starts at output frame ⌊t × 532 × `interval` × rate / 1,193,182⌋. Example: an
`interval` of 7 gives a tick of about 3.1 ms.

At each tick, the player does these steps:

1. It adds 1 to the local tick. The local tick counts from the start, or from the last restart.
2. For a negative `limit` −L: when the local tick is L + 2, the chip stops all sounds. Every part
   starts again, and the local tick becomes 0.
3. For a positive `limit` L: when the local tick is more than L + 1, no more events play. The notes
   that sound continue.
4. A repeated part starts again when the local tick is more than the start of its period plus
   the period.
5. It plays the events of the tick, part after part, in the order of the tracks.

- A melodic note takes the free channel with the lowest number from 0 to 5. A drum takes the
  channel of its drum. When that channel is busy, the note does not play.
- A note on an empty instrument slot does not play.
- A release stops the first note of the same part with the same pitch.

## Checks

| Condition | Error |
|---|---|
| A name is empty | `error.EmptyMusicName` |
| A name contains a character that is not a letter, a digit, `_`, `.` or `-` | `error.InvalidMusicName` |
| A name field of the profile has no 0 byte | `error.UnterminatedMusicName` |
| The path is longer than 64 bytes | `error.NoSpaceLeft` |
| A file is not in `DATA/` and not at the root | `error.NotFound` |
| A profile is larger than 753 bytes, a MIDI file larger than 1,048,576, an instrument larger than 80 | `error.TooLarge` |
| A profile is not 752 or 753 bytes | `error.InvalidMusicProfileSize` |
| `interval` is 0 or more than 1000, `bar_ticks` is 0, or `limit` is −2,147,483,648 | `error.InvalidMusicTiming` |
| An instrument is not 80 bytes | `error.InvalidInstrumentSize` |
| Byte 0 of an instrument is not 0, and byte 1 is not 6 to 10 | `error.InvalidPercussionInstrument` |
| A chunk does not start with `MThd` or `MTrk` where the reader expects it | `error.InvalidMidiChunk` |
| The header size is not 6, or the format is more than 1 | `error.InvalidMidiHeader` |
| The number of tracks is 0 or more than 16 | `error.TooManyMusicParts` |
| Data follows the last track | `error.TrailingMidiData` |
| A chunk or an event goes past the end of its data | `error.TruncatedMidi` |
| A variable-length quantity has more than 4 bytes | `error.InvalidMidiVlq` |
| A data byte comes before the first status of a track, or a status is 0xf1-0xf6 or 0xf8-0xfe | `error.InvalidMidiStatus` |
| A data byte is 0x80 or more | `error.InvalidMidiData` |
| A track has no end of track event, the event has data, or bytes follow it | `error.InvalidMidiEnd` |
| A tick is more than 10,000,000, or a part gives 100,000 events or more | `error.MusicTooLarge` |

## Quirks

- The player writes a waveform to register 0x0e + op, not 0xe0 + op. At its reset, it turns the
  waveform select on and then off. Thus every operator keeps the sine wave.
- For the operators 0x12 to 0x15, the address 0x0e + op is 0x20 to 0x23. That write sets the
  multiple of the operators 0x00 to 0x03 and clears their other bits, until their next note.
- The velocity addition wraps at 8 bits before the limit of 127.
- A pitch bend reads its 14-bit value as a sign (bit 13) and a size (bits 12-0). The value 8192
  does nothing.
- A pitch bend adds (size × 25) / 8192, with the sign, to the F-number of the part's notes. The
  product wraps to a signed 16-bit value before the division, so the change is −4 to +3 steps. The
  bend writes a block one lower than the block of the note.
- A note that finds no free channel does not play. The player does not take the channel of a note
  that sounds.

## Sources

- `src/shared/content/music.zig`
- `src/shared/content/score.zig`
- `src/shared/audio/music_player.zig`
- `src/shared/audio/soundtrack.zig`
- `src/shared/scenes/front_end.zig` (the cue names of the title menu)
- flashback-re `docs/floppy-music.md`
