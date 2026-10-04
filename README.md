# flashbackz

A modern Zig reimplementation of the original DOS floppy edition of Flashback. The user
changed the reference from the CD release on 2026-10-04. The runtime now reads FAT12 `.ima`
images and extracted floppy directories, expands ABA installation archives, and uses the
original title artwork. CD image loading, SEQ movies and CD executable metadata imports
have been removed.

The supplied `disk1.img` and `disk2.img` form the complete English floppy set. The original
installer completes successfully, and the original introduction and English menu run. Disk 1
is identical to the now-removed `Flashback.ima`. Both native hosts accept the two image paths
together, or extracted directories. Converting the installer’s level files is still pending.

Code-wheel protection is excluded by the user's instruction. Modern Start will proceed
directly to the game opening sequence.

Normal launch now plays the original vector logo and both introduction chapters, then opens
the title menu. Tab skips the logo or introduction. Menu navigation, Skill, Info and Quit work.
The logo and first introduction chapter match every captured original frame. The second
chapter has small edge differences in 18 of 380 frames (at most 33 pixels per frame), retained
under the user's preference for readability over pixel-specific fixes.

Sound, exact presentation timing, menu fades/blinking, gameplay entry, passwords and Continue
are still unfinished. The startup error `FloppyCinematicsNotYetImplemented` has been removed
from normal launch. `--scene menu` remains an optional development shortcut.

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
LGPL notice. It is ready for Flashback's music layer, which is not connected yet.
