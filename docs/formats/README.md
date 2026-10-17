# File formats

These documents specify the files that flashbackz reads and writes. Each document gives the
layout of one format, the procedure to read it, and the data that the code refuses.

## The original's files

The user gives the original's files. The code reads them and never writes them.

Containers and the executable:

- [FAT12 floppy image](floppy-image.md): the two disks, `disk1.img` and `disk2.img`.
- [Installation archive](aba-archive.md) (`*.ABA`): most of the files in `DATA/`.
- [Packed stream](packed-stream.md): the compression of the archives, `CT`, `LEV`, `BNQ` and
  `MBK`.
- [Game executable](executable.md) (`FB.EXE`): the tables that the game and the extractor read.
- [World messages](world-messages.md): the dialogue texts in `FB.EXE`.
- [Demo file](demo.md): the recorded input of Conrad in the three demos.

Rooms and colors:

- [Room descriptions](lev-rooms.md) (`LEVELn.LEV`): the rooms of a level, made of tiles.
- [Tile banks](bnq-tiles.md) (`LEVELn.BNQ`): the 8 × 8 tiles of the rooms.
- [Background pieces](sgd-pieces.md) (`LEVEL1.SGD`): the larger pieces of the jungle rooms.
- [Installed room images](map-rooms.md) (`LEVELn.MAP`): the room images of a DOS installation.
- [Menu pictures](menu-bitmap.md) (`MENUn.MAP`, `INSTRU_E.MAP`).
- [Level palettes](level-palette.md) (`LEVELn.PAL`) and [menu palettes](menu-palette.md)
  (`MENUn.PAL`, `INSTRU_E.PAL`).

Level logic:

- [Collision grid](collision.md) (`LEVELn.CT`): the room links and the terrain cells.
- [Animations](animations.md) (`LEVELn.ANI`): the frames of each character state.
- [Placements](placements.md) (`LEVELn.PGE`): the characters and the items of a level.
- [Rule groups](rule-groups.md) (`LEVELn.OBJ`): the behavior rules, with the operation codes.
- [Labels](labels.md) (`LEVELn.TBN`): the names of the characters and the items.

Sprites, art and text:

- [Sprites](sprites.md) (`PERSO.SPR`, `PERSO.OFF` and the monster libraries).
- [Object art banks](mbk-banks.md) (`LEVELn.MBK`).
- [Object art](object-art.md) (`GLOBAL.SPC`, `LEVELn.RP`): frames made from bank parts.
- [Icons](icons.md) (`GLOBAL.ICN`).
- [Font](font.md) (`FB_TXT.FNT`).

Films and sound:

- [Vector films](vector-films.md) (`*.CMD`, `*.POL`).
- [Cinematic text](cinematic-text.md) (`ENGCINE.BIN`, `ENGCINE.TXT`).
- [Sound effects bank](sound-effects.md) (`GLOBAL.FIB`).
- [Music](music.md) (`*.PRF`, `*.MID`, `*.INS`).
- [Mega Drive cartridge](megadrive-cartridge.md): the tunes of the Mega Drive edition, if the
  user gives the cartridge.

## Our files

The extractor, the game and the hosts write these files.

- [Data set](data-set.md): the directory that the extractor writes, with `messages.zon`,
  `scenes.zon` and `report.txt`.
- [Characters](characters.md) (`<level>/characters.zon`) and
  [behavior tables](behaviors.md) (`<level>/behaviors/<name>.zon`).
- [Naming overlay](naming-overlay.md) (`src/extract/names.zon`): our names for behaviors and
  states.
- [Saves](save.md) (`QUICK`, `SAVE1` to `SAVE8`, `.INFO`) and [settings](settings.md)
  (`SETTINGS`).
- [SDL event log](sdl-event-log.md) (`--event-log`).
- [Agent host output](agent-output.md): the JSON lines of `flashbackz-agent`.

The atlas writes a standard PNG file with 8-bit RGB pixels (`src/atlas/png.zig`). No document
here repeats the PNG specification.

## Conventions

- The documents use Simplified Technical English (ASD-STE100).
- Offsets and sizes are in bytes and in decimal. Byte values, masks and codes are in
  hexadecimal (`0xff`).
- The types are `u8`, `i8`, `u16`, `i16`, `u32` and `i32`. Each document gives the byte order
  of its format once. A field in the other byte order has "(LE)" or "(BE)" after its type.
- Bit 0 is the least significant bit of a value.
- An offset in a table starts at the start of the file, or at the start of the record that the
  table shows.
- "The reader" is the code that reads the format. "The writer" is the code that writes it.
- A quirk is a behavior of the original that the code keeps on purpose.
- The documents contain no original content: the examples are synthetic.

## The structure of a document

1. The title: the name of the format and the file names, for example
   ``# Collision grid (`LEVELn.CT`)``.
2. A summary in one to three sentences: what the file holds and what uses it.
3. A table: the files, the byte order, the code that reads the format, and the code or program
   that writes it.
4. The layout: one table for each record, with the columns Offset, Size, Type and Content.
5. The procedures, as numbered steps, where the order is important.
6. The checks: what the reader refuses, and the error that it gives.
7. The quirks, if there are quirks.
8. The sources: the code, and the research documents in flashback-re.
