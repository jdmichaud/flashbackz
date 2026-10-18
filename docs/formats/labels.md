# Labels (`LEVELn.TBN`)

A label file holds the names of the characters of one level, for example the names of the items.
A placement gives the number of its label. The touch label and the inventory show the label.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.TBN`, `LEVEL2.TBN`, `LEVEL3.TBN`, `LEVEL4_1.TBN`, `LEVEL4_2.TBN`, `LEVEL5_1.TBN` and `LEVEL5_2.TBN`: one file for each level. |
| Byte order | Little-endian. |
| Reader | `string_table.copy` in `src/extract/string_table.zig`, used by `level.extract` in `src/extract/level.zig`. `extractAll` in `src/extract/root.zig` reads the file. The game does not read the file: it reads the labels from the data set. |
| Writer | None: the files come from the original game. |

## Layout

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | `end` | `u16[end / 2]` | The directory: the offset of each label, from the start of the file. |
| `end` | to the end of the file | bytes | The texts of the labels. |

`end` is the first word of the file. It is the offset of label 0 and also the size of the
directory. Thus the directory has `end / 2` entries, and label 0 starts just after the directory.

A label is a text of bytes that ends with a 0 byte. Two entries can give the same offset. In the
original files, label 0 is empty, the texts follow each other with no gap, and each text has at
most 16 bytes.

The touch label and the inventory draw a label with the game font ([font.md](font.md)). When a
level loads, the game refuses a label with a character that the font does not have
(`error.MissingGlyph`).

## Procedures

### Read label `n`

1. Read the first word, `end`. Make sure that it is even, at least 2, and not past the end of the
   file.
2. Make sure that `n` is less than `end / 2`.
3. Read the word at offset `2 * n`: the offset of the label. Make sure that it is at least `end`
   and less than the file size.
4. Read the bytes from the offset to the next 0 byte. Make sure that there is a 0 byte, and at
   most 256 bytes before it.

### Extract the labels of a level

1. Read `DATA/name.TBN`, where `name` is the file name of the level. The file must have at most
   16384 bytes.
2. For each placement, read the label of its label number (byte 30 of the record,
   [placements.md](placements.md)). If the label does not read, use an empty label and add a
   note to `report.txt`.
3. If the label is not empty, write it in the field `label` of the character.
4. If the label number is not 0, write it in the field `label_number`.
5. Make the name of the character. If the naming overlay names its behavior, start with that
   name. Else start with the label as a valid identifier, or with the name of the kind if the
   label is empty. Then add `_` and the index of the placement. Placement 0 is always `conrad`.

## Checks

| Condition | Error |
| --- | --- |
| The file has more than 16384 bytes. | `error.TooLarge` |
| The file has fewer than 2 bytes, or `end` is odd, less than 2, or past the end of the file. | `error.InvalidStringDirectory` |
| `n` is not less than `end / 2`. | `error.MissingString` |
| The offset of the label is less than `end`, or not less than the file size. | `error.InvalidStringOffset` |
| No 0 byte ends the label. | `error.UnterminatedString` |
| The label has more than 256 bytes. | `error.StringTooLong` |

An error of the file read, for example `error.TooLarge`, stops the extraction. For the errors of
a label, the extractor uses an empty label and writes the note `L: placement P: label N does not
read (ERROR)` ([data-set.md](data-set.md#reporttxt)). The report counts it as unexpected.

## Quirks

- The leftward sight scan of the original can read the label number in a placement record
  ([placements.md](placements.md)). Thus the data set keeps `label_number`, and the engine uses
  it only to rebuild bytes 30 and 31 of the record for this scan.

## Sources

- `src/extract/string_table.zig`, `src/extract/level.zig` (`extract`, `characterId` and
  `writeCharacters`) and `src/extract/root.zig`.
- `src/shared/scenes/level_screen.zig` (`drawLabel`), `src/shared/scenes/level.zig` (the inventory
  and `checkContent`) and `src/shared/behavior/original_memory.zig`.
- flashback-re: `docs/rules/engine-level.md` (section 5) and `docs/inventory-menu-map.md`.
