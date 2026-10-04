# flashbackz

A modern Zig reimplementation of the original DOS floppy edition of Flashback. The user
changed the reference from the CD release on 2026-10-04. The runtime now reads FAT12 `.ima`
images and extracted floppy directories, expands ABA installation archives, and uses the
original title artwork. CD image loading, SEQ movies and CD executable metadata imports
have been removed.

The supplied `Flashback.ima` is an incomplete installation disk: 13 files and 31 archived
resources. It contains the title artwork but lacks `INTRO1.CMD/POL`, `INTRO2.CMD/POL`, music
resources and essential gameplay files. The remaining floppy disks or a complete installed
copy are required. Normal startup reports the missing introduction explicitly.

The title preview supports navigation, Skill, Info and Quit. It has been exercised through
actual SDL keyboard events and presented frames. It is silent; title timing, fades, music and
the rotoscoped introduction are not implemented or certified pixel-perfect. Start, passwords,
gameplay and Continue imports remain disabled pending floppy qualification. Earlier CD
comparisons do not establish fidelity to this edition.

```sh
zig build --prefix /tmp/flashback/modern/out --cache-dir /tmp/flashback/modern/cache
/tmp/flashback/modern/out/bin/flashbackz-sdl --scene menu ../Flashback.ima
/tmp/flashback/modern/out/bin/flashbackz-agent --scene menu --frames 120 ../Flashback.ima
```

Images are opened read-only. The bounded FAT12 reader validates geometry, matching FAT copies,
cluster chains and file sizes. It imports into owned assets, limited to 32 MiB in total. ABA
archives validate extents, names, expansion sizes and compression checksums. No external
extractor or emulator is used by the game. Supplied content never enters version control.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. Foundation checks are `zig build test smoke
verify web web-check` with scratch prefix/cache as above; `web-check` also needs Node.js.
Windows is cross-built with `zig build -Dtarget=x86_64-windows-gnu`, using pinned SDL2 sources.
Without content, the template smoke fixture remains available for platform testing.

Independent scene, movement, terrain, inventory and rendering systems are retained for
requalification. The modern engine must be readable and extensible, independent of the DOS
program's architecture. Exact behavior, pixels, timing and audio are separate acceptance
requirements. Linux, Windows and WebAssembly share the simulation; network play is excluded.

Research and historical measurements live in `../flashback-re`; optional direct reconstruction
belongs in `../flashback-remaster`. See [PLAN.md](PLAN.md) and [DESIGN.md](DESIGN.md).
