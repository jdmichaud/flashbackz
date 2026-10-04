# flashbackz

A modern Zig reimplementation of the original DOS floppy edition of Flashback. The user
changed the reference from the CD release on 2026-10-04. The runtime now reads FAT12 `.ima`
images and extracted floppy directories, expands ABA installation archives, and uses the
original title artwork. CD image loading, SEQ movies and CD executable metadata imports
have been removed.

The supplied `disk1.img` and `disk2.img` form the complete English floppy set. The original
installer completes successfully, and the original introduction and English menu run. Disk 1
is identical to the now-removed `Flashback.ima`. Both native hosts accept the two image paths
together, or extracted directories. Compact room artwork is decoded directly; all 193 rooms
match the original installer’s pictures and palette selections.

Code-wheel protection is excluded by the user's instruction. Modern Start will proceed
directly to the game opening sequence.

Normal launch now plays the original vector logo and both introduction chapters, then opens
the title menu. Tab skips the logo or introduction. Menu navigation, Skill, Info and Quit work.
The logo and first introduction chapter match every captured original frame. The second
chapter has small edge differences in 18 of 380 frames (at most 33 pixels per frame), retained
under the user's preference for readability over pixel-specific fixes.

AdLib music now plays through the logo, introduction and menu. Original musical ticks and
register writes agree across 16,709 observations; native SDL output has been captured. Digital
sound effects, exact presentation/audio synchronization, menu fades/blinking, passwords and
Continue are still unfinished. Start plays the wake-up animation with music and enters the
jungle. Turning, walking and the existing movement/inventory development slice are available;
The holocube and floor plate animate; Shift collects the cube, plays its pickup movie, and
adds it to inventory for selection. Tab opens inventory; Return uses the selected holocube
and plays its recording with text and music. One press plays once, including when Return is
held through completion. Other actors/interactions and complete floppy behavior qualification
remain unfinished. The pickup matches all 35 original frames; recording has documented
remaining differences in 11 of 377 frames. The startup error `FloppyCinematicsNotYetImplemented` has been removed
from normal launch. `--scene menu` remains an optional development shortcut.

Current priority is completing Conrad movement. Walk/run blends, running turns, running
jumps, wall stops, automatic running ledge grabs and running rolls are ready for testing; see [movement names and controls](docs/movement-testing.md).

```sh
zig build --prefix /tmp/flashback/modern/out --cache-dir /tmp/flashback/modern/cache
/tmp/flashback/modern/out/bin/flashbackz-sdl ../disk1.img ../disk2.img
/tmp/flashback/modern/out/bin/flashbackz-agent --scene menu --frames 120 ../disk1.img ../disk2.img
```

Images are opened read-only. The bounded FAT12 reader validates geometry, matching FAT copies,
cluster chains and file sizes. It imports into owned assets, limited to 32 MiB in total. ABA
archives validate extents, names, expansion sizes and compression checksums. No external
extractor or emulator is used by the game. Supplied content never enters version control.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. Foundation checks are `zig build test smoke
verify` with scratch prefix/cache as above. Browser support is excluded.
Windows builds are deferred until Linux gameplay is working; portable host boundaries remain.
When that phase resumes, `zig build -Dtarget=x86_64-windows-gnu` uses pinned SDL2 sources.
Without content, the template smoke fixture remains available for platform testing.

Independent scene, movement, terrain, inventory and rendering systems are retained for
requalification. The modern engine must be readable and extensible, independent of the DOS
program's architecture. Behavior, visual fidelity, timing and audio have separate acceptance
checks; small documented pixel differences are permitted when they simplify the code. Native
SDL and the headless host share the simulation. Networking and browser support are excluded.

Research and historical measurements live in `../flashback-re`; optional direct reconstruction
belongs in `../flashback-remaster`. See [PLAN.md](PLAN.md) and [DESIGN.md](DESIGN.md).

The generic OPL2/OPL3 synthesizer is reused from vpoolz with its synthetic reference tests and
LGPL notice. Flashback's original-derived music importer and sample-clock player feed the native PCM queue.
