# flashbackz

A reimplementation in Zig of Flashback (Delphine Software, 1992), played from the original DOS
floppy disks on Linux and Windows.

## Start the game

The game's files are not included: you need your own English floppy edition, `disk1.img` and
`disk2.img`.

```sh
flashbackz disk1.img disk2.img
```

One thing missing from the DOS version is the ambient short musical cue from the Megadrive version. If you provide your
own flashback ROM to the built, you can have the best of both world: The DOS gameplay and the megadrive music.

```sh
flashbackz --megadrive flashback.md disk1.img disk2.img
```

`flashbackz --help` lists the other options.

## Build the game

You need Zig 0.17.0, and on Linux SDL2 and pkg-config (Debian: `libsdl2-dev pkg-config`).

```sh
zig build                                # zig-out/bin/flashbackz
zig build test
zig build -Dtarget=x86_64-windows-gnu    # zig-out/bin/flashbackz.exe, SDL2 built in
```

You can build a standalone executable which will contain the DOS disk and the megadrive ROM for better portability.
This generates a second executable, `flashbackz-standalone`, which then
starts with no argument.

```sh
zig build -Ddisk1=disk1.img -Ddisk2=disk2.img -Dmegadrive=flashback.md
```

## License

MIT (`LICENSE`), except three parts under their own licences (`LICENSE-THIRD-PARTY`): the OPL
synthesiser (LGPL-2.1, from DOSBox), the YM2612 (BSD-3-Clause, from ymfm) and the command-line
parser (MIT, from zig-utils). Flashback itself belongs to its publishers and is not part of this
repository.
