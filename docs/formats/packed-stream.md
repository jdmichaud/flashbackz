# Packed stream (backward bitstream)

A packed stream holds data in a compressed form: literal bytes and copies of earlier output. The
decoder reads the stream from its end to its start, and it writes the output from its last byte to
its first byte. Five file formats use it.

| Item | Value |
| --- | --- |
| Files | Parts of other files. See [The formats that use it](#the-formats-that-use-it). |
| Byte order | Big-endian |
| Reader | `src/shared/content/backward_stream.zig` (`decode`) |
| Writer | None in flashbackz |

## The formats that use it

| Format | Input that the caller gives | Maximum size | Size check |
| --- | --- | --- | --- |
| [ABA archive](aba-archive.md) entry with a stored size less than its size | The stored bytes of the entry | The size of the entry | `ArchiveSizeMismatch` |
| [`LEVELn.CT`](collision.md) | The whole file | 7,424 | `InvalidCollisionLayout` |
| [`LEVELn.LEV`](lev-rooms.md) room | From byte 256 to the end offset of the room | 16,384 | None |
| [`LEVELn.BNQ`](bnq-tiles.md) packed bank | From the end of the directory to the offset of the bank | The size of the bank (at most 32,768) | `ArtBankSizeMismatch` |
| [`LEVELn.MBK`](mbk-banks.md) packed bank | From the end of the directory to the offset of the bank | The size of the bank (at most 16,384) | `ArtBankSizeMismatch` |

The size check column gives the error when the output size is not the size that the caller
expects. Each input must have a length that is a multiple of 4.

## Layout

A stream is a list of `u32` words. Its length is a multiple of 4 and at least 12. The last 12
bytes are the trailer:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 4 | `u32` | The first bit word. |
| 4 | 4 | `u32` | The checksum. |
| 8 | 4 | `u32` | The size of the output, in bytes. |

The bit words come before the trailer. The decoder reads them one by one, from the trailer back
to the start. It stops when the output is full. The bytes before the last word that it reads are
not a part of the stream, and the decoder ignores them. Thus a file can hold several streams, one
after the other: the caller gives the end of a stream.

### Commands

The prefix bits and the fields are in read order.

| Prefix | Fields | Operation |
| --- | --- | --- |
| `00` | n: 3 bits | Write n + 1 literal bytes (1 to 8). |
| `01` | d: 8 bits | Copy 2 bytes from distance d. |
| `100` | d: 9 bits | Copy 3 bytes from distance d. |
| `101` | d: 10 bits | Copy 4 bytes from distance d. |
| `110` | n: 8 bits, then d: 12 bits | Copy n + 1 bytes (1 to 256) from distance d. |
| `111` | n: 8 bits | Write n + 9 literal bytes (9 to 264). |

A literal byte is an 8-bit field. A copy reads the byte that is d bytes after the output byte that
it writes. The decoder wrote that byte before. A distance less than the length repeats bytes: a
copy from distance 1 repeats the last byte that the decoder wrote.

## Procedures

### Read bits

The decoder keeps a 32-bit word W, a checksum C and a read position P. The highest set bit of W
is a sentinel. When only the sentinel is left, the next read drops it and loads a new word.

1. At the start, set W to the first bit word and C to the checksum XOR the first bit word.
2. Set P to the start of the trailer.
3. To read one bit, set b to bit 0 of W. Then shift W right by 1.
4. If W is now 0, move P back by 4 and read the `u32` R at P.
5. Set C to C XOR R. Set b to bit 0 of R. Set W to `0x80000000` OR (R shifted right by 1).
6. To read a field of n bits, read n bits. For each bit, set the value to value × 2 + b.

The first bit of a field is its most significant bit.

### Decode

1. Read the trailer. Make an output of "size" bytes. Set the count of bytes to write, N, to size.
2. While N is not 0, read a command.
3. For each literal byte, set N to N − 1. Then read 8 bits into output byte N.
4. For each byte of a copy, set N to N − 1. Then copy output byte N + d to output byte N.
5. When N is 0, C must be 0.

C is then the XOR of the checksum, the first bit word and each word that the decoder read.

### Example

This 12-byte stream (synthetic) decodes to the 4 bytes `41 41 41 41`:

```
03 00 30 40   03 00 30 40   00 00 00 04
```

The first bit word is `0x03003040`, the checksum is the same value, and the size is 4. The bits
give the command `00` with n = 0, the literal byte `0x41`, then the command `100` with d = 1. The
copy writes 3 more bytes. The word that is left holds only the sentinel. C is 0.

## Checks

| Condition | Error |
| --- | --- |
| The input has less than 12 bytes, or its length is not a multiple of 4. | `InvalidBitstreamLength` |
| The size in the trailer is more than the maximum that the caller gives. | `ExpandedContentTooLarge` |
| The decoder must read a word before the start of the input. | `TruncatedBitstream` |
| A command writes more bytes than N. | `ExpandedContentOverflow` |
| A copy has distance 0, or reads a byte that the decoder did not write. | `InvalidBackReference` |
| C is not 0 at the end. | `InvalidBitstreamChecksum` |

The reader refuses these streams, and it never writes past the output. Research
(flashback-re `docs/collision-port-map.md`) says that the original does not check these writes.

## Sources

- `src/shared/content/backward_stream.zig`: the decoder and its synthetic tests.
- The callers: `archive.zig`, `collision.zig`, `floppy_rooms.zig` and `art_bank.zig` in
  `src/shared/content/`.
- flashback-re `docs/collision-port-map.md`: the commands, the bit order and the checksum.
- flashback-re `docs/object-artwork-map.md`: the MBK banks, with earlier streams before a stream.
- flashback-re `docs/floppy-gameplay-entry.md`: the LEV rooms and the BNQ banks.
