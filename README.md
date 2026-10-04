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
effects now play for forest ambience, movement, the floor switch and weapon effects, with
animated ejected casings. Other actor/mechanism cues, exact presentation/audio synchronization,
menu fades/blinking and passwords are still unfinished. Continue now displays the original
floppy screen; retry restarts the level opening, and Abort plays game over before returning
to the title. Checkpoint restoration and complete defeat-flow timing remain unfinished. Start plays the wake-up animation with music and enters the
jungle. Turning, walking and the existing movement/inventory development slice are available;
The holocube and floor plate animate; Shift collects the cube, plays its pickup movie, and
adds it to inventory for selection. Tab opens inventory; Return uses the selected holocube
and plays its recording with text and music. One press plays once, including when Return is
held through completion. Other actors/interactions and complete floppy behavior qualification
remain unfinished. The pickup matches all 35 original frames; recording has documented
remaining differences in 11 of 377 frames. The startup error `FloppyCinematicsNotYetImplemented` has been removed
from normal launch. `--scene menu` remains an optional development shortcut.

Current priority is completing Conrad movement. Walk/run blends, running turns, running
jumps, wall stops, automatic running ledge grabs, running rolls and weapon-drawn
movement (including quick draws after climbing/landing and armed roll recovery) are ready for testing; see [movement names and controls](docs/movement-testing.md).

Escape opens Game Options and pauses the world. Up/Down selects a row; Left/Right changes
its value. Escape or an action key applies settings and resumes; select Abort Game to return
to the title. The added Volume row adjusts music and effects from 0–100% in 10% steps.
Settings persist during the current application session. Free memory is displayed in MB.
Manual Zoom doubles a cropped view and switches off on a room change. Automatic combat
zoom and the joystick option are not connected yet.

Loose credits can now be collected with Shift and added to the existing purse, with the
original pickup movie. Stones can now be picked up with Shift and selected in inventory. Return while standing
throws the selected stone; its data supplies the flight, rebounds and landing sound.
Electrical hazards now respond to their switches and pressure plates, and contact plays
disintegration before Continue. Jungle gunmen now share idle, walking, turning,
awareness and aiming/firing animation. The stone-sensitive variant approaches loose stones;
the other variant ignores them. Conrad's shots now damage and defeat gunmen, with directional
knockdowns and score awards. Enemy bullets now hurt Conrad, with posture-sensitive knockdowns, recovery,
brief blinking protection, and Continue on defeat. Gunmen can crouch and fire low in
response to Conrad's posture. Ground robots now deploy, pursue, strike and can be destroyed with low shots, including
their overload/explosion sequence and sounds. Ceiling laser guns now use their original pressure-plate/detector connections, firing
profiles, effects and damage. Doors now use shared opening/closing tracks and change
collision at the authored animation steps. Pressure plates, switches and credential locks
route through imported circuits. Ordinary keys can be collected with Shift, selected with
Tab/arrow keys, and used with Return at a matching lock. Successful use consumes the key.
Ordinary lifts now carry Conrad and board stones through their original contact behavior.
With the gun holstered, Shift+Up/Down requests a ride. Turning, crouching, drawing,
shooting and holstering work while travelling. The jungle pressure-called lift now stays
down while its plate is pressed, then returns automatically. Cinematic lifts,
story-issued cards, other enemy families and the remaining mechanisms are
still being implemented.

DEMO plays the three original recorded input streams through normal gameplay, in the
original jungle / alien surface / tower order. Escape or Tab returns to the title; select
DEMO again for the next recording, followed by the introduction. It is now a regression
driver, not a claim that the depicted gameplay is complete: missing switch/door and enemy
behavior still changes the route. Original state and full-frame comparisons record these
failures in `../flashback-re/docs/floppy-demo.md`.

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
