# World messages (in `FB.EXE`)

The world messages are the dialogue pages that the rule operation `show_message` shows during
play. They are a table in the data segment of `FB.EXE`. The extractor decodes the table and
writes `messages.zon`.

| Item | Value |
| --- | --- |
| Files | `FB.EXE`, unpacked ([executable.md](executable.md)). The table starts at offset 5,097 (`0x13e9`) of the data segment. |
| Byte order | Little-endian |
| Reader | `src/extract/world_messages.zig` (`load`, `decode`) |
| Writer | None for the table. `writeMessages` in `src/extract/root.zig` writes `messages.zon` from it. |

The supplied executable has 45 messages.

## Layout

### Directory

The table starts with a directory of message offsets. An offset is from the start of the table.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The offset of message 0. It is also the size of the directory, in bytes. |
| 2 × i | 2 | `u16` | The offset of message i. |

The number of messages is the offset of message 0 divided by 2. The table has no end of its own:
the reader takes the bytes from the start of the table to the end of the image.

### Message text

A message is a byte string. It holds pages, and a page holds lines.

| Bytes | Content |
| --- | --- |
| `0xff`, then a `u16` ink | At the start of a line only: the ink of this line and of the lines after it. |
| `0x0a` | The end of a line. |
| `0x0b` | The end of a line and of its page. |
| `0x00` | The end of a line, of its page and of the message. |
| Other bytes | The characters of the line. |

The ink at the start of a message is `0xe8`. An ink stays until the next `0xff`, also on the pages
after it. A `0xff` byte inside a line is a character.

The limits are:

- at most 256 messages;
- at most 64 pages in a message;
- at most 32 lines in a page;
- at most 256 bytes in a line, without the ink and the end byte.

### Example

This table (synthetic) holds one message with two pages:

```
02 00   41 0a   42 0b   ff eb ec 43 00
```

| Page | Line | Text | Ink |
| --- | --- | --- | --- |
| 1 | 1 | `A` | `0xe8` |
| 1 | 2 | `B` | `0xe8` |
| 2 | 1 | `C` | `0xeb` |

## Procedures

### Read the directory

1. Read the `u16` F at offset 0 of the table. Check it.
2. For each message i from 0 to F / 2 − 1, read the `u16` at 2 × i. Check it.
3. Read the message at that offset.

### Read a message

1. Set the ink to `0xe8`.
2. At the start of a line, if the byte is `0xff`, set the ink to the byte after it. Skip 3 bytes.
3. Read the bytes up to the next `0x00`, `0x0a` or `0x0b`. These bytes are the text of the line.
4. Keep the line with the ink.
5. At `0x0a`, go to step 2.
6. At `0x0b`, close the page. Then go to step 2.
7. At `0x00`, close the page. The message ends.

### Write `messages.zon`

The extractor writes the messages in their order, with the comment `// message N` before each.
A message is a list of pages, and a page is a list of lines. A line is
`.{ .text = "...", .ink = N }`, with the ink in decimal. The text uses Zig string escapes for `"`,
`\` and the bytes outside `0x20`-`0x7e`. [data-set.md](data-set.md) gives the file.

## Checks

| Condition | Error |
| --- | --- |
| The reader cannot unpack `FB.EXE`. | See [executable.md](executable.md#checks). |
| The table has less than 2 bytes. | `TruncatedMessageDirectory` |
| F is less than 2, is odd, is more than the table size, or is more than 512. | `InvalidMessageDirectory` |
| A message offset is less than F, or not less than the table size. | `InvalidMessageOffset` |
| A `0xff` has fewer than 2 bytes after it. | `TruncatedMessageInk` |
| A message has no `0x00` before the end of the table. | `UnterminatedWorldMessage` |
| A page has more than 32 lines, or a line has more than 256 bytes. | `MessageTooLarge` |
| A message has more than 64 pages. | `MessageTooLarge` |

## Quirks

The ink is a `u16`, but the reader keeps only its low byte. The text renderer of the original also
uses only the low byte.

## Sources

- `src/extract/world_messages.zig`: the reader and its synthetic test.
- `src/extract/root.zig`: `writeMessages`.
- `src/shared/content/floppy_interface.zig`: `loadImage` and the start of the data segment.
- flashback-re `docs/floppy-cartridge-puzzle.md`: the table offset, the line, page and ink bytes,
  and the default ink.
- flashback-re `docs/current-work.md`: the 45 messages.
