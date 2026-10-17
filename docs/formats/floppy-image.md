# FAT12 floppy image (`*.IMG`, `*.IMA`)

A floppy image is a sector copy of one game disk, with a FAT12 file system. The hosts read the
files of the two images into one set of game files, then expand the archives in that set.

| Item | Value |
| --- | --- |
| Files | The two images that the user gives, one for each disk. The reader does not use the file name. |
| Byte order | Little-endian |
| Reader | `src/shared/floppy.zig` (`load`). The hosts call it from `src/native/cli.zig`. |
| Writer | None in flashbackz |

The supplied images have 1,474,560 bytes (disk 1) and 737,280 bytes (disk 2). The game files are
in `DATA/`.

## Layout

### Boot sector

The boot sector is sector 0. The reader uses only these fields:

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 11 | 2 | `u16` | Bytes in a sector. Must be 512. |
| 13 | 1 | `u8` | Sectors in a cluster: 1, 2, 4, 8, 16, 32 or 64. |
| 14 | 2 | `u16` | Reserved sectors before the first FAT. Must not be 0. |
| 16 | 1 | `u8` | Number of FATs. Must be 2. |
| 17 | 2 | `u16` | Entries in the root directory. Must not be 0. |
| 19 | 2 | `u16` | Sectors in the image. Must not be 0. |
| 21 | 1 | `u8` | Media byte. Byte 0 of the FAT must have the same value. |
| 22 | 2 | `u16` | Sectors in one FAT. Must not be 0. |
| 510 | 2 | `u16` | Boot signature, `0xaa55`. |

The reader ignores the other fields, for example the 32-bit sector count at 32.

### Areas

The areas follow one another in this order. "Reserved", "FAT sectors" and "root entries" are the
boot sector fields.

| Area | Start | Size |
| --- | --- | --- |
| Reserved sectors | 0 | reserved × 512 |
| FAT 1 | reserved × 512 | FAT sectors × 512 |
| FAT 2 | (reserved + FAT sectors) × 512 | FAT sectors × 512 |
| Root directory | (reserved + 2 × FAT sectors) × 512 | root entries × 32, up to the next multiple of 512 |
| Data | the end of the root directory | the rest of the image |

The cluster size is 512 × sectors in a cluster. The cluster count is the size of the data area
divided by the cluster size, rounded down. Cluster n (n ≥ 2) starts at data + (n − 2) × cluster
size.

### FAT entry

A FAT entry has 12 bits. Entry n starts at byte n + n / 2 of the FAT (integer division). Read the
`u16` at that byte: for an even n, the entry is bits 0-11; for an odd n, it is bits 4-15.

| Entry value | Content |
| --- | --- |
| `0x002` to cluster count + 1 | The next cluster of the chain. |
| `0xff8` to `0xfff` | The end of the chain. |
| Other values | Not allowed in a chain. |

Entries 0 and 1 hold no cluster: byte 0 of the FAT is the media byte, bytes 1 and 2 are `0xff`.

### Directory entry

A directory is a list of 32-byte entries. The root directory has a fixed place; a subdirectory is
a cluster chain, as a file is.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 8 | ASCII | Name, with spaces at the end. See the values of byte 0 below. |
| 8 | 3 | ASCII | Extension, with spaces at the end. |
| 11 | 1 | `u8` | Attributes. See the table below. |
| 12 | 8 | - | Ignored. |
| 20 | 2 | `u16` | High word of the first cluster (FAT32). Must be 0. |
| 22 | 4 | - | Ignored (time and date). |
| 26 | 2 | `u16` | First cluster. 0 for an empty file. |
| 28 | 4 | `u32` | File size in bytes. Must be 0 for a directory. |

| Byte 0 | Content |
| --- | --- |
| `0x00` | The end of the directory. The reader stops. |
| `0xe5` | A deleted entry. The reader skips it. |
| `.` (`0x2e`) | The `.` and `..` entries. The reader skips them. |

| Attribute bits | Content |
| --- | --- |
| `0x0f` (all four low bits) | A part of a long name. The reader skips the entry. |
| Bit 3 (`0x08`) | A volume label. The reader skips the entry. |
| Bit 4 (`0x10`) | A directory. |
| Bits 6 and 7 (`0xc0`) | Must be 0. |
| Bits 0, 1, 2 and 5 | Ignored. |

### Asset names

The reader makes the name of a file from its path: the directory names and the file name, with
`/` between them. A name is the name field without its end spaces, then `.` and the extension. A
name without an extension has no `.`. Example (synthetic): `DATA/FILE.DAT`.

Each name must be a valid asset name (`validateAssetName` in `src/shared/platform.zig`):

- It has 1 to 128 bytes and at most 8 components, with one `/` between two components.
- A component has 1 to 64 characters from `A`-`Z`, `a`-`z`, `0`-`9`, `.`, `_` and `-`.
- A component does not start or end with `.`, and does not contain `..`.
- A component is not a Windows device name: `CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9` or
  `LPT1`-`LPT9`, with or without an extension.

The providers compare names without case (ASCII). A list of names gives the upper-case form of
each name (`canonicalAssetName`).

## Procedures

### Read an image

1. Check the image size and the boot sector fields.
2. Calculate the areas and the cluster count.
3. Check FAT 1: its size, its byte 0 and its bytes 1 and 2.
4. Compare FAT 2 with FAT 1, byte by byte.
5. Read the root directory, entry by entry, with an empty prefix.
6. For each entry that the reader does not skip, check the entry. Then make the name and check it.
7. For a file, read its chain and add the file to the set.
8. For a directory, read its chain. Then do steps 6 to 8 for its entries, with the prefix
   "directory name/".

### Read a chain

1. If the file size is 0, the first cluster must be 0. The file has no data.
2. Start at the first cluster.
3. Check the cluster: it must be from 2 to cluster count + 1, and less than `0xff0`.
4. Check that no chain of the image used the cluster before. Then mark it as used.
5. Append the bytes of the cluster.
6. Read the FAT entry of the cluster. If it is `0xff8` or more, stop.
7. For a file, the bytes of the chain must be fewer than the file size.
8. Go to the cluster that the entry gives, and do steps 3 to 8 again.
9. For a file, keep the first "file size" bytes. The chain must have exactly the number of
   clusters that the file size needs.

A loop in a chain gives `CrossLinkedCluster` (step 4), or `InvalidChainLength` (step 7) in a file.

### Open the disks (hosts)

1. Take 0, 1 or 2 asset paths from the command line. Refuse a third path.
2. For each path, open it as a directory. If it is not a directory, read it as an image of at most
   4 MiB.
3. Add the files of each disk to one set. A name on both disks must have the same bytes on both.
4. Expand each archive in the set ([aba-archive.md](aba-archive.md)).

Without a path, the standalone build reads its built-in images with the same procedure. The set
holds at most 4,096 files and 32 MiB. The image reader does not check that the files are the
game's files. The reader of `FB.EXE` checks the edition ([executable.md](executable.md)).

## Checks

| Condition | Error |
| --- | --- |
| The image has less than 512 bytes, or no `0xaa55` at 510. | `InvalidBootSector` |
| A boot sector field has a value that the layout does not allow. | `UnsupportedFloppyGeometry` |
| The image size is not sectors × 512. | `InvalidImageLength` |
| The data area starts at or after the end of the image. | `InvalidImageLength` |
| The cluster count is 0 or more than 4,084. | `UnsupportedFloppyGeometry` |
| FAT 1 has no room for the entries of all clusters. | `InvalidFat` |
| FAT byte 0 is not the media byte, or FAT bytes 1 and 2 are not `0xff`. | `InvalidFat` |
| A chain reads an entry past the end of the FAT. | `InvalidFat` |
| FAT 2 is not equal to FAT 1. | `FatCopiesDiffer` |
| The high cluster word is not 0, or attribute bit 6 or 7 is set. | `InvalidDirectory` |
| A directory has a size that is not 0. | `InvalidDirectory` |
| A name is not a valid asset name. | `InvalidName` |
| An empty file has a first cluster that is not 0. | `InvalidChain` |
| A chain has a cluster out of range (for example 0, 1 or `0xff7`). | `InvalidChain` |
| Two chains use the same cluster, or a chain has a loop. | `CrossLinkedCluster` |
| A chain has more or fewer clusters than the file size needs. | `InvalidChainLength` |
| A directory is more than 8 levels below the root. | `DirectoryTooDeep` |
| Two files have the same name (any case) and different bytes. | `ConflictingAsset` |
| The set has more than 4,096 files or 32 MiB. | `TooLarge` |

The hosts change each error, except `ConflictingAsset`, `OutOfMemory` and `Canceled`, into
`InvalidImage`. The message names the disk, then gives "not a floppy image of the game, nor a
directory from one". For `ConflictingAsset`, the message ends with "a file differs from the
other disk's (two editions?)".

## Sources

- `src/shared/floppy.zig`: the image reader.
- `src/shared/asset_pack.zig`: the set of files and its limits.
- `src/shared/platform.zig`: `validateName`, `validateAssetName`, `canonicalAssetName`.
- `src/native/cli.zig`: `Providers.importAssets`, `importPath` and `importImage`.
- FAT12 is a public standard. No research document of flashback-re describes this format.
