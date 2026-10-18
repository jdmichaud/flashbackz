# Object art banks (`LEVELn.MBK`)

An MBK file holds the art banks of a level: banks of 4-bit tiles that the composed object art uses.
Each art bank is a packed stream, or raw bytes. A composition is the recipe of one frame of object
art: a list of object-art parts, each a tile of an art bank at a position.
[object-art.md](object-art.md) gives how a composition selects a bank and reads its tiles.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.MBK` to `DATA/LEVEL5.MBK`. Levels `earth_city` and `spaceport` use `LEVEL4.MBK`. Levels `alien_surface` and `alien_base` use `LEVEL5.MBK`. |
| Byte order | Big-endian |
| Reader | `src/shared/content/art_bank.zig` (`Archive`). `character_art.zig` reads the file. |
| Writer | None. The files come with the game. |

## Layout

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 6 × n | entry × n | The directory. Byte 0 is also the bank count n, 1 to 255. |
| 6 × n | — | — | The bank data: the packed streams and the raw banks |

An entry:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | — | The high half of a u32 offset. The reader ignores it. In entry 0, byte 0 is n. |
| 2 | 2 | u16 | The offset in the file. For a packed bank, the end of its stream. For a raw bank, its start. |
| 4 | 2 | u16 | Bit 15: 1 for a raw bank. Bits 0-14: the size of the bank in units of 32 bytes. |

A size of 0 gives no bank. The pixels of a bank are 4-bit, two in each byte, with the high nibble
first. A tile of the object art starts at a multiple of 32 bytes in its bank
([object-art.md](object-art.md)).

A packed bank is a packed stream ([packed-stream.md](packed-stream.md)). The last byte of the stream
is at the offset minus 1. The decoder reads the stream from its end. Thus, other data can come
before the stream. A raw bank is the bytes from its offset, as many as its size.

A writer must obey these rules:

- Each offset must be at or after the end of the directory, and not after the end of the file.
- For a packed bank, the offset minus 6 × n must be a multiple of 4.
- The unpacked size in a stream must be the bank size.
- A bank must not be larger than 16,384 bytes. This is a limit of the reader: a part of the
  object art reads at most 8,672 bytes of its bank.
- The file must not be larger than 65,536 bytes.

In the supplied files, 131 of the 398 entries have a bank, and all the banks are packed.

## Procedures

### Read bank i

1. If i is n or more, there is no bank.
2. Read the offset, the u16 at byte 6 × i + 2.
3. Read the size word, the u16 at byte 6 × i + 4.
4. Multiply bits 0-14 of the size word by 32. If the result is 0, there is no bank.
5. If bit 15 of the size word is 1, copy the bank from the offset.
6. Else, give the bytes from 6 × n to the offset to the decoder of the packed stream.
7. Make sure that the decoder gives exactly the bank size.

## Checks

| Condition | Error |
| --- | --- |
| The file is empty, n is 0, or the directory is longer than the file. | `InvalidArtBankDirectory` |
| The bank index is n or more, or the bank size is 0. | `MissingArtBank` |
| The bank size is more than 16,384 bytes. | `ArtBankTooLarge` |
| The offset is before the end of the directory or after the end of the file. | `InvalidArtBankOffset` |
| A raw bank goes past the end of the file. | `TruncatedArtBank` |
| The unpacked size in the stream is more than the bank size. | `ExpandedContentTooLarge` |
| The unpacked size in the stream is less than the bank size. | `ArtBankSizeMismatch` |
| The decoder refuses the stream, for example a length that is not a multiple of 4. | The decoder error ([packed-stream.md](packed-stream.md)) |
| The file has more than 65,536 bytes. | `TooLarge` |

The level loader counts a `MissingArtBank` as a missing sprite and continues. The other errors
stop the level load.

## Quirks

- The directory has 32-bit offsets, but the original reads only their low 16 bits. Thus the
  first byte of the file can be the bank count.
- A packed stream ends at its offset. The streams before it stay outside of its checksum.

## Sources

- `src/shared/content/art_bank.zig`, `backward_stream.zig`, `character_art.zig`,
  `level.zig` (`files`)
- flashback-re `docs/object-artwork-map.md`
