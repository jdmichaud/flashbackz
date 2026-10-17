# Installation archive (`*.ABA`)

An ABA archive holds a set of game files, each stored as is or packed. Before the game reads its
files, the hosts expand each archive of the disks into ordinary files in the directory of the
archive.

| Item | Value |
| --- | --- |
| Files | `*.ABA`. The supplied disks have three archives in `DATA/`, with 216 files in total. |
| Byte order | Big-endian |
| Reader | `src/shared/content/archive.zig` (`expand`, `expandAll`). The hosts call it from `src/native/cli.zig`. |
| Writer | None in flashbackz |

## Layout

### Header

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The number of files, at most 4,096. |
| 2 | 2 | `u16` | The size of a record. Must be 30. |
| 4 | count × 30 | record | The records, one for each file. |

The file data comes after the records.

### Record

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 14 | ASCII | The file name, with a 0 byte at its end. The reader ignores the bytes after the 0. |
| 14 | 4 | `u32` | The offset of the file data from the start of the archive. |
| 18 | 4 | `u32` | The stored size: the number of bytes in the archive. |
| 22 | 4 | `u32` | The size of the file. |
| 26 | 4 | ASCII | The tag `D.M.`. |

When the stored size is equal to the size, the file data is the file. When the stored size is
less than the size, the file data is a [packed stream](packed-stream.md). Its trailer must give
the same size.

The file data of each record starts at or after the end of the file data of the record before it.
The file data of the first record starts at or after the end of the records. The file data of the
last record ends at the end of the archive. The reader accepts a gap between two files. In the
supplied archives, each file starts where the file before it ends.

An entry can hold a file of a packed format as stored data. For example, the supplied archives
keep the `.CT`, `.MBK` and `.BNQ` files as stored entries. The readers of those formats unpack
them.

## Procedures

### Expand one archive

1. Read the header. Check the record size and the number of files.
2. For each record, in order, read the name, the offset, the two sizes and the tag.
3. Make the path of the file: the directory of the archive, then the name.
4. If the stored size is equal to the size, copy the file data.
5. If not, decode the file data as a packed stream. The maximum size is the size of the record.
6. Add the file to the set of game files.
7. After the last record, the last file must end at the end of the archive.

### Expand the archives of the disks (hosts)

1. Read the files of the two disks into one set ([floppy-image.md](floppy-image.md)).
2. Find each file whose name ends with `.ABA`, in upper or lower case.
3. For each archive, its directory is its name up to and with the last `/`. A name without `/`
   has an empty directory.
4. Expand the archive into the same set.

The archives stay in the set. The hosts expand only the archives that were in the set before step
4. Thus an archive inside an archive stays as it is. A name that is already in the set must have
the same bytes (names compare without case).

## Checks

| Condition | Error |
| --- | --- |
| The archive has less than 4 bytes, or the records go past its end. | `TruncatedArchive` |
| The record size is not 30, or the number of files is more than 4,096. | `InvalidArchiveHeader` |
| The 14 name bytes contain no 0, or the name contains `/` or `\`. | `InvalidArchiveName` |
| The tag is not `D.M.`. | `InvalidArchiveTag` |
| The file data starts before the end of the file before it (or of the records). | `InvalidArchiveExtent` |
| The file data starts or ends after the end of the archive. | `InvalidArchiveExtent` |
| The stored size is more than the size. | `InvalidArchiveExtent` |
| The size is more than the free space of the set (32 MiB in total). | `TooLarge` |
| The packed stream has an error. | See [packed-stream.md](packed-stream.md). |
| The decoded size is not the size of the record. | `ArchiveSizeMismatch` |
| Bytes follow the last file. | `ArchiveTrailingBytes` |
| The path is not a valid asset name (an empty name gives this error too). | `InvalidName` |
| The set has a file with the same name and different bytes. | `ConflictingAsset` |
| The set has 4,096 files already. | `TooLarge` |

The hosts change each error, except `ConflictingAsset`, `OutOfMemory` and `Canceled`, into
`InvalidImage`. The message starts with "cannot open the disks' archives", then gives the reason
as for an image ([floppy-image.md](floppy-image.md#checks)).

The rules for a valid asset name are in [floppy-image.md](floppy-image.md#asset-names). A name can
contain `-`.

## Sources

- `src/shared/content/archive.zig`: the reader.
- `src/shared/asset_pack.zig`: the set of files, its limits and the rule for equal names.
- `src/native/cli.zig`: `Providers.importAssets`.
- flashback-re `docs/reference-environment.md`: the original installer reads the archives from the
  disks.
- flashback-re `docs/tool-issues.md`: an archive name can contain `-`.
