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
menu fades/blinking are still unfinished. Original level codes now select the level and difficulty through the title menu. Continue now displays the original
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
Volume is saved when Game Options closes and restored on the next launch, including startup
music. Free memory is displayed in MB.
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
Tab/arrow keys, and used by holding Return through Conrad's hand press at a matching lock.
Successful use consumes the key. Select SHIELD and hold Return near an energy generator to
recharge it, with the original animation and music. Releasing Return before the press cancels.
The administrative-center BOSS now accepts the starting ID card and issues WORK PERMIT.
Hold Shift for his request, acknowledge the pages with Return, then select ID CARD and hold
Return beside him. The original exchange films play. Mission screens now show their briefings with Shift and
accept WORK PERMIT with Return. Return, Space or Shift advances film pages; Tab skips.
The first parcel assignment's conversations, grant, ambush, delivery, 100-credit payment and
next-terminal unlock are connected. Its prepared route matches the original; the remaining
assignment consumers and full street-route qualification are still incomplete.
The android assignment now issues REPLICANT PHOTO and reveals its informant. Hold Shift
beside him for the introduction or repeat reply; his first conversation reveals the policeman,
whose first/repeat conversations also work. Decorative bar patrons animate from the same
content family. The frightened civilian now flees when he sees Conrad, which activates the
ambush gunman; the gunman approaches, aims and is defeated by Conrad's shots, and the civilian
then relaxes and sits. Talking to him afterwards, the gunman's defensive field, the hostile
guard handoff, key, android fights and photo witnesses are still unfinished, so the full
assignment cannot yet be completed through normal play.
The reactor assignment now grants TIME and TERMINAL CARD after transport. Select the card
and hold Return at its matching terminal to complete the repair, receive 500 credits and
return. Inventory and Game Options pause the countdown. Expiry plays the reactor explosion
and reaches Continue. Prepared routes pass; the full maze and its enemies remain unfinished.
The escort follower now follows, turns and boards ordinary lifts through shared contact and
passenger rules. Stay ahead of him; use Shift+Up/Down on the lift. Arrival triggers the original
dialogue, 300-credit mission payment and return effect. Holster the gun to accept the return.
Prepared original/native checks pass; the complete unmodified escort route remains unqualified.
The city fuse can be collected with Shift. Select FUSE with Tab/arrows, close inventory,
then hold Return at the broken switch. Repair consumes the fuse and enables the linked lift;
hold Shift at the repaired switch to call it.
The magnetic cartridge can be collected, recharged at a generator and used in its lock to
activate the bridge. Its lock instruction uses the original paged message display; Return,
Space or Shift acknowledges a page while gameplay is paused. All links and support footprints
come from the supplied data.
The wounded man's help/conversation and teleporter exchange are now connected. Return his
teleporter to reveal the ID card; the card can be collected and used without being consumed.
The old man now offers the anti-G belt: hold Shift to talk, select CREDITS with Tab/arrows,
then press Return beside him to pay 500. The belt is granted automatically; enter the gap
to play the descent film and reach New Washington. Later city gameplay is still incomplete.
The bartender now reveals Jack. Hold Shift beside BARMAN, acknowledge the pages, then talk
to FORGER outside to open employment-office access. Select CREDITS and hold Return beside
the forger to pay 1,500 and receive PAPERS. The papers checkpoint itself remains unfinished.
Ian's memory machine is connected: after his invitation, wait for him to sit, move slightly
to his right until SEAT appears, and hold Shift. The memory film plays with music; afterward,
talk to Ian again for his next instructions. Select his FORCE FIELD with Tab/arrows, close
the inventory, then hold Return to deploy it. It also works while moving or holding the gun;
holding Return repeats deployment after recovery. The item is reusable.
Startup also shows the original temporary level code until its timer expires or a nearby
interaction hint replaces it.
Ordinary lifts now carry Conrad and board stones through their original contact behavior.
With the gun holstered, Shift+Up/Down requests a ride. Turning, crouching, drawing,
shooting and holstering work while travelling. The jungle pressure-called lift now stays
down while its plate is pressed, then returns automatically. Long lift transfers now play
the original LIFT films and music, then resume with their passengers at the destination.
Hidden lift templates, story-issued cards, other enemy families and the remaining mechanisms are
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

## Extracting the data set

`--extract DIR` (either host) converts the user's disks into the readable data set the game
runs on (DESIGN.md section 3). Per level it writes `characters.zon` and one
`behaviors/<name>.zon` per behavior, plus `messages.zon` and `scenes.zon`. Images and sound are
not extracted. Write it outside Git, into a new or empty directory:

```sh
/tmp/flashback/modern/out/bin/flashbackz-sdl --extract ~/flashback-data ../disk1.img ../disk2.img
```

Names come from the committed overlay `src/extract/names.zon`. Anything not named there keeps
a systematic name (`state_768`, `signal_20`, `link_0`). Each generated behavior shows its key
and its states' ordinals, which is what the overlay uses to name them. `report.txt` lists
dropped unreachable rules and anything the extractor could not name. The game builds the same
data set in memory from the disks at startup; `--data DIR` makes it read an extracted one
instead, an edited copy for example.

## Mega Drive tunes during play

`--megadrive FILE` names the user's cartridge of the Mega Drive edition, Flashback (Europe)
(En,Fr); other editions are refused. Its eight short tunes then play during play where that
edition plays them: 64 places over the seven levels, each once per visit of its room, the first
on entering the second room of level 2. The DOS edition asks for them as well but has no sound
for them. They play on an emulated YM2612 (sorz's chips, NTSC timing), mixed with the effects;
nothing of the cartridge is in the repository. Without the option the game is the DOS edition.

Both programs list their options with `--help`: the help is generated from the same description
the command line is parsed with (`src/native/clap.zig`).

For development checks, `--scene` also accepts `city`, `tower`, `earth_city`, `spaceport`,
`alien_surface` and `alien_base`, alongside `menu` and `jungle`. These shortcuts skip startup;
remaining gameplay and story behavior in those levels is still under implementation.

Images are opened read-only. The bounded FAT12 reader validates geometry, matching FAT copies,
cluster chains and file sizes. It imports into owned assets, limited to 32 MiB in total. ABA
archives validate extents, names, expansion sizes and compression checksums. No external
extractor or emulator is used by the game. Supplied content never enters version control.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. Foundation checks are `zig build test smoke
verify` with scratch prefix/cache as above. Browser support is excluded.
Windows: `zig build all -Dtarget=x86_64-windows-gnu -p OUT` cross-builds both hosts from Linux, with SDL2 built from its pinned sources and linked statically; the
executables need only Windows' own DLLs. Copy `flashbackz-sdl.exe` next to the disk images and
run `flashbackz-sdl.exe disk1.img disk2.img`.
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

A complete placement/family/connection audit is maintained in
[the research coverage report](../flashback-re/docs/content-coverage.md). Import registrations
identify implemented components and gaps; they are separate from behavior qualification.
