# File formats

These documents specify the files that flashbackz reads and writes. Each document gives the
layout of one format, the procedure to read it, and the data that the code refuses.

## Terms

A term with a special meaning has its definition here, or in the first document that uses it, in
the order of the lists below.

- **Host**: a program that runs the game on a machine. It gives the game the original's files, the
  input, a clock, the screen, the sound and the storage. The storage keeps the saves and the
  settings. The SDL host (`flashbackz`) is the program that a player uses. The agent host
  (`flashbackz-agent`) has no window: it plays scripted input on a controlled clock, for tests.
- **Extractor**: the code that reads the placements, the rules and the labels of the original,
  and tables of its executable. It writes the data set. A host runs it in memory when the game
  starts, or writes the data set into a directory with `--extract`.
- **Atlas**: `flashbackz-atlas`, a tool that draws all the rooms of all the levels into one PNG
  map.
- **flashback-re**: the research repository beside flashbackz. Its documents record the studies
  and the measurements of the original.
- **State**: one step of the behavior of a character. A state shows an animation, then its rules
  select the next state.
- **Rule**: a choice of a state: up to two conditions and, when they hold, an effect, changes to
  the character, a movement and the next state.
- **Condition**, **effect**, **operation**: a condition is a test, for example of a key or of the
  terrain. An effect is an action, for example a sound or a terrain change. Both are operations: the
  original keeps an operation as a code and an argument, and the data set gives it a name.
- **Demo**: a recorded game. The title menu plays the next of the three demos when the player
  chooses DEMO, or when the player waits.
- **Update**: one step of play, in which the characters act one time, in their order
  ([behaviors.md](behaviors.md#how-the-engine-runs-the-tables)). The code and the agent host call
  an update a walk.
- **Host frame**: one pass of the loop of a host. In each host frame, the host calls the game one
  time. The game then runs the updates that are due, and draws the screen.
- **Tick**: a timer tick, one period of the PC timer of the original: 17,024 counts of the
  1,193,182 Hz clock, about 70.09 each second. In [music.md](music.md), a tick is a music tick, a
  different unit.
- **Scene**: a numbered request for a film and its music ([executable.md](executable.md)). The
  parts of the program (the title menu, a level, the continue screen, the ending) are screens.
  The option `--scene` and the lines of the agent host keep the name `scene` of the code.

Some words have several kinds:

- **Frame**: an animation frame ([animations.md](animations.md)), a film frame, a host frame, an
  output frame (one sample for each audio channel) or a Mega Drive frame.
- **Cell**: a terrain cell, one square of the terrain grid of a room: 16 pixels wide, empty or
  solid ([collision.md](collision.md)). A LEV room has grid cells, and a Mega Drive tune has tune
  cells.
- **Bank**: a tile bank (BNQ), an art bank (MBK), a PAL bank or a color bank (16 colors).
- **Slot**: a palette slot, a save slot, a contact slot or an instrument slot.
- **Part**: an object-art part or a music part (a MIDI track).

A document gives the kind of these words at their first use. In that document, the word then has
only that kind. Without a kind, a frame is an animation frame, and a cell is a terrain cell.

Some words have one meaning:

- **Effect**: the effect of a rule. A sound is a sound effect.
- **Ink**: the 4-bit value of a pixel of a glyph ([font.md](font.md)). The color of a line of
  text is its text color.

The documents use the terms of these standards without a definition: FAT12, the MZ executable
and EXEPACK, VGA (its planes and its 6-bit DAC), the Standard MIDI File, the OPL2 FM chip, the
YM2612 FM chip, the NTSC vertical blank, Sound Blaster PCM, SDL, JSON Lines, ZON (Zig object
notation), Wyhash, SHA-256 and PNG.

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

The game does not operate on the original file directly. It converts them (by default on the
fly) to a set of files with more modern format that can be customized for modding.

The extractor, the game and the hosts write these files.

- [Data set](data-set.md): the directory that the extractor writes, with `messages.zon`,
  `scenes.zon`, `report.txt`, and the films in their original formats in `films/`.
- [Characters](characters.md) (`<level>/characters.zon`) and
  [behavior tables](behaviors.md) (`<level>/behaviors/<name>.zon`).
- [Naming overlay](naming-overlay.md) (`src/extract/names.zon`): our names for behaviors and
  states.
- [Saves](save.md) (`QUICK`, `SAVE1` to `SAVE8`, `.INFO`) and [settings](settings.md)
  (`settings.zon`).
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
- `tools/check_format_docs.py` checks the links, the line widths, the modal verbs, the retired
  names, and that each agreed term has its definition before its first use.

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
