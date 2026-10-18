# Sound effects bank (`GLOBAL.FIB`)

`GLOBAL.FIB` holds the digital sound effects of the levels. Each sound effect is a short mono sound
in a 4-bit delta code. The level screen plays the sound effects through a mixer with four voices.

| Item | Value |
|---|---|
| File | `DATA/GLOBAL.FIB`, a file of the first disk image (see [floppy-image.md](floppy-image.md)) |
| Byte order | Little-endian |
| Reader | `src/shared/content/sound_effects.zig` (`decode`), called by `src/shared/content/level_pack.zig` (`load`) |
| Player | `src/shared/audio/effects.zig` (`Mixer`, `Player`) |
| Writer | None |

## Layout

The file has a count, a directory and the encoded sound effects.

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 2 | u16 | `count`: the number of sound effects, 1 to 256 |
| 2 | 6 × `count` | record | The directory: one record for each sound effect |
| 2 + 6 × `count` | rest of file | u8 | The encoded sound effects |

A directory record:

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 4 | u32 | `offset`: the start of the encoded sound effect, from the start of the file |
| 4 | 2 | u16 | `length`: the size of the encoded sound effect. 0 gives an empty sound effect. |

The index of a record is the id of its sound effect: the first record is sound effect 0. The reader
ignores the `offset` of an empty sound effect. The reader does not examine the order of the extents,
and two extents can overlap.

The game's file has 66 records. Six of them are empty.

An encoded sound effect of `length` n:

| Offset | Size | Type | Content |
|---|---|---|---|
| 0 | 1 | i8 | The first amplitude |
| 1 | n − 1 | u8 | Two 4-bit delta codes in each byte: bits 7-4 first, then bits 3-0 |

The delta codes:

| Code | 0x0 | 0x1 | 0x2 | 0x3 | 0x4 | 0x5 | 0x6 | 0x7 |
|---|---|---|---|---|---|---|---|---|
| Delta | −34 | −21 | −13 | −8 | −5 | −3 | −2 | −1 |

| Code | 0x8 | 0x9 | 0xa | 0xb | 0xc | 0xd | 0xe | 0xf |
|---|---|---|---|---|---|---|---|---|
| Delta | 0 | 1 | 2 | 3 | 5 | 8 | 13 | 21 |

## Decode a sound effect

1. Read the first byte as a signed amplitude `a`. Write `a` two times.
2. For each next byte, add the delta of bits 7-4 to `a`. Write `a`.
3. Add the delta of bits 3-0 to `a`. Write `a`.

Each addition wraps at 8 bits: 127 + 1 gives −128. Thus n encoded bytes give 2 × n samples.

Example (synthetic): the bytes `0x7f 0xff 0x08` give the samples 127, 127, −108, −87, −121, −121.

## Playback

The samples are signed 8-bit mono PCM. The mixer plays them at 1,000,000 / 166 Hz (about
6,024 Hz), the rate of the original's Sound Blaster output.

- A request gives a sound effect id and an attenuation from 0 to 3. Each attenuation step is an
  arithmetic shift of the samples right by 2 bits.
- An id at or above `count`, or an empty sound effect, plays nothing.
- When a voice plays the same sound effect, that voice starts again from the first sample. Else the
  first free voice takes the sound effect. When the four voices are busy, the mixer ignores the
  request.
- The mixer makes blocks of 70 samples. The busy voice with the lowest number writes its samples.
  The other voices add their samples, with 8-bit wrap.
- When the first voice has fewer than 70 samples for a block, its last sample fills the rest of the
  block.
- The output gives each block sample to the two stereo channels, multiplied by 256, without
  interpolation.

With the Mega Drive cartridge, the ids 68 to 75 do not go to the mixer: they start the cartridge's
tunes (see [megadrive-cartridge.md](megadrive-cartridge.md)).

## Checks

| Condition | Error |
|---|---|
| The file is not there | `error.NotFound` |
| The file is larger than 4,194,304 bytes | `error.TooLarge` |
| The file is shorter than 2 bytes | `error.InvalidSoundArchive` |
| `count` is 0 or more than 256, or the directory goes past the end of the file | `error.InvalidSoundArchive` |
| A non-empty sound effect starts before the end of the directory or past the end of the file | `error.InvalidSoundExtent` |
| A non-empty sound effect ends past the end of the file | `error.InvalidSoundExtent` |
| The decoded sound effects hold more than 4,194,304 samples in total | `error.SoundArchiveTooLarge` |

## Quirks

- In the first block of a sound effect, the voice cannot use the last 2 samples of the sound effect.
  Thus a sound effect of 72 samples or fewer plays without its last 2 samples.
- After each block, a voice with 4 samples or fewer left stops. These samples do not play.
- The voices add with 8-bit wrap, not with a limit. A loud mix changes sign.

## Sources

- `src/shared/content/sound_effects.zig`
- `src/shared/content/level_pack.zig`
- `src/shared/audio/effects.zig`
- flashback-re `docs/gameplay-sound.md` and `docs/inventory-menu-map.md`
