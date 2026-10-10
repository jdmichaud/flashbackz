# flashbackz implementation plan


## Floppy edition pivot — user instruction, 2026-10-04

The reference is the complete English pair supplied on 2026-10-04:
`disk1.img` SHA-256 `3ff964a76e90f3c25489334db38bde021d0c7632f7fa2b90ba234312c1d1272f`
and `disk2.img` SHA-256 `ed9b9a5bef0b42d5c394d9b715f27b42edc388d17f243b12ae52f9d3c2e0f9b2`.
Disk 1 is identical to the now-removed `Flashback.ima`. The Italian images previously supplied
under these filenames were rejected by the user and are not the reference. Earlier completed
CD gates below are historical and do not certify the floppy edition. Code-wheel protection
is excluded by explicit user instruction (2026-10-04); it is not a fidelity gate. The English installer
completes successfully; original startup reaches the code-wheel protection prompt.
Windows compilation is deferred until Linux gameplay works, per the user’s 2026-10-04
priority update. Preserve portability while concentrating implementation and testing on Linux.
The user permits small documented pixel differences when that avoids excessive complexity;
readability takes precedence over frame-specific repairs for isolated pixels.
Browser/WebAssembly support is excluded by the user; native Linux is the current focus.

- [x] Remove the web host, browser assets and build/check targets. Gate: native builds and
  tests pass, and no browser target or host remains in the active implementation.
- [x] Inventory FAT12 files and ABA archives; identify missing installation media, record
  provenance and reproduce floppy startup on disposable copies.
- [x] Remove CD filesystem/track and SEQ playback from the modern game. Preserve historical
  research and shelved generic work; retain independent reusable systems for requalification.
- [x] Support direct IMA input and bounded ABA decompression, with malformed-input tests and
  independent extraction comparison. Support extracted floppy content through the same API.
- [x] Import both floppy images together through native command-line input; recover the
  installer's level expansion without a runtime dependency on DOS. Gate: all installed file
  bytes match the original installer's output, including all five generated level maps.
  - 2026-10-09: the hosts take both images on the command line, and the game decodes rooms
    from the compact level files without an installation. flashback-re `compare_install.py`
    rebuilds the installation from the images through this import: all 232 installed files
    other than FB.CFG (the user's configuration and a date) are identical, the five generated
    level maps included. The agent host plays levels of both disks from the images.
- [x] Reproduce title, vector introduction and original scene order. Gate: exact original
  presented-frame comparisons, palette changes, timing and input behavior. Small documented
  pixel differences may be accepted to avoid excessive renderer complexity (user decision).
  - 2026-10-09, flashback-re `capture_cinematics.py` and `vector_cinematic_probe.zig`: LOGOS
    153/153 and INTRO1 260/260 presented frames match the original exactly, INTRO2 362/380
    (the rest differ on polygon edges, at most 33 pixels).
  - Timing, same capture: each film's length is within 33 ms of the original's (12.2, 18.7 and
    26.2 s), and presents fall in the same 50/66.7 ms rhythm of a 70 Hz clock against a
    59.94 Hz display, but the beat slips by one display refresh at times (up to four in
    INTRO2): the original's clock measures 69.94 Hz over 44 s of plain presents, the model
    uses 70.09 Hz. Open: whether to calibrate to the emulator's beat (DOSBox's refresh is not
    real VGA's 70 Hz), and the input comparison.
  - User decision 2026-10-09: keep the current timing (no calibration to the emulator's beat).
  - [x] Film input as the original (flashback-re engine-presentation 6.1a): a fresh press of
    Backspace or Tab skips a film (films play with the key latch on, so a key held when a film
    opens does not skip it); P pauses the pictures while the music plays on; Escape, Enter,
    Space and Shift do not skip (Enter, Space and Shift still turn interactive pages). With the
    joystick option its inventory button skips too. Gate: agent runs of the introduction and an
    in-game film with each key.
    - 2026-10-09, agent: on LOGOS, Tab or Backspace starts INTRO1 and a second press reaches the
      menu without INTRO2; Escape, Enter, Space and Shift change nothing; Tab held across LOGOS's
      end does not skip INTRO1; P stops the picture and P again resumes it 300 frames later at
      the frame it would have shown. On the jungle's opening film: Tab or Backspace ends it,
      the other keys and a held Tab do not; an 80-frame pause ends it 80 frames later; an Escape
      tapped during it leaves the same state and picture as no key.
- [x] Import Flashback MIDI/PRF/INS music into named parts, instruments and scheduled events;
  verify malformed inputs, profile bindings, loops and note adjustments without game fixtures.
  - `content/music.zig` imports profiles, instruments and tracks into an immutable score; its
    synthetic tests cover truncated and impossible profiles, invalid drums, adjustment
    wrapping, zero-velocity releases, order and loop alignment.
- [x] Compare the music driver's timed register output against the original, then connect
  startup/menu sound to the existing chip and native PCM queue. Preserve scene stop/skip order.
  - 2026-10-09, flashback-re `capture_music.py` and `compare_music.py` on the current code:
    the logo, introduction and menu cues agree with the original in every musical tick,
    register and value (257, 12,550 and 3,901 writes). Startup and menu music play through the
    chip and the native PCM queue (agent `--pcm` recordings; earlier SDL device captures).
- [x] **Latest user priority: finish the casings, then complete gameplay sound throughout.**
  Include forest ambience, movement, switches, weapons and every other original effect; bind
  cues to original animation/interaction timing through one shared sound system. Do not stop
  at gunfire. Keep missing world behavior and full movement coverage explicitly tracked.
  - Since 2026-10-09 casings are characters run from their tables, and every effect is the
    engine's sound request at the moment a rule fires (animation entry sounds and
    `play_sound`), mixed by the shared effects player. Every recorded request of the
    captures matches by update, id and attenuation (engine regression); the mixer's output
    timing is not compared yet.
  - 2026-10-09: the mixer's output matches the original block for block (flashback-re
    `compare_mix_blocks.py`: 271/271 blocks at the jungle start, 940/940 in a city fight with
    all four voices busy, attenuated effects included). A request is heard within about two
    11.6 ms blocks of the original's time; the host's buffering adds to that.
- [x] Recover floppy music/effects sequencing and integrate AdLib plus PCM. Gate: exact event
  timing and sound comparisons against the pinned original execution profile.
  - 2026-10-09: effect requests match per update in every capture, the mixed effect blocks
    match exactly, and nine music cues match in every tick, register and value: logo,
    introduction, menu, RECHAGE3 and the five level openings (REVEIL3, CHUTE, VOYAGE, CAPTURE,
    TELEPORT; flashback-re floppy-music.md). Other film cues use the same player and were not
    captured one by one.
- [x] Import compact LEV/BNQ/SGD room descriptions directly into owned artwork for gameplay.
  Gate: all decoded room pixels and palette selectors match the original installer’s five
  MAP outputs. Preserve compact content boundaries; reproducing the installer’s compression
  choices is unnecessary for runtime artwork.
- [x] **Superseded 2026-10-09 by behavior as data (below):** the items that implemented or
  qualified one hand-written family or mechanism. Every character now runs from its extracted
  behavior table, and the engine regression checks all of them against each capture. They were:
  the jungle holocube; the Conrad movement pass; demo playback through the shared simulation;
  collectibles, credits and stones; the leftward visibility continuation; the carried force
  field; fuse repair; identity card and employment; interactive film pages; mission terminals;
  the courier, android, reactor and escort assignments; the bar and forger; city police and
  rescued civilians; shared enemy families (robots and ceiling guns included); energy
  generators; the item-aid NPCs; trading; world messages; keys, cards and locks; the
  systematic mechanism import; relay and pressure outputs; pressure plates; and requalifying
  the gameplay imports.
- [x] Persist master volume across application restarts. Load before startup audio and save
  applied changes through the shared storage interface; check a native close/relaunch.
- [x] Game Options: pause/resume, original settings and abort flow, host free memory in MB,
  plus user-requested master volume (0–100%). Gate: native menu input, pause behavior and
  both music/effect output levels are verified; original-only settings retain measured semantics.
  - The level scene opens it on Esc after the update's walk and abandons to the continue
    screen, as the original does.
  - 2026-10-09: the pause is part of the zoom captures, which open the dialog during play and
    match the original on every update. Agent host, keyboard input, recorded output
    (`--pcm`): 50% volume halves every sample of title music, film music and level effects
    (it is saved and restored); Sound FX off silences the effects that follow, Music off the
    title music after abandoning; Abort leads to the continue screen and the title. Zoom is
    compared with the original (zoom captures). The Joystick row keeps its value; there is no
    joystick input yet (next item). Earlier native SDL/XTEST runs covered the dialog itself.
- [x] Joystick input: the original reads a joystick when the Joystick option is on. Gate: a
  host joystick or gamepad drives Conrad as the keys do, under that option.
  - 2026-10-09: the level reads SDL controller events (stick, buttons, D-pad). Agent host:
    gamepad runs reach the same position and state hash as the equivalent keyboard runs, and
    do nothing with the option off. Not tried with a physical gamepad.
- [x] Extend the existing native development scene shortcut to named levels so later-level
  mechanisms can be checked in the actual executable without remapping original assets.
- [x] Title-menu level codes: match the supplied edition’s codes, select their level and
  difficulty, play the appropriate entry sequence and let the user test all seven levels.
  Invalid codes return safely to the title; retry restarts the selected level.
  - 2026-10-09, agent host with keyboard input at the title: all 21 codes (seven levels, three
    difficulties, read from the user's FB.EXE) start their level at their difficulty, the
    eighth starts the ending, an invalid code stays on the title, and Continue after a defeat
    (spaceport, Conrad idle; the original also loses health there) restarts the level at the
    same difficulty.
- [x] Original temporary level-code display: import the level/difficulty codes and show
  the startup notice until its timer expires or a contact hint replaces it.
- [x] **Behavior as data (user decision, 2026-10-08).** Replace hand-coded
  behavior families with declarative behavior tables run by one engine (see DESIGN.md 3-4).
  - [x] Vocabulary survey: every condition and effect used across all levels and difficulties,
    with counts, recovered meaning and our name; measure the evaluation order (animation
    completion, reacting transitions, signal timing, authored order).
    - flashback-re `docs/rule-vocabulary.md`, `docs/rules/` (codes, engine-update, -level).
  - [x] Extractor: disks to a ZON data set outside Git (characters, behavior tables, text),
    plus a committed naming overlay. Gate: deterministic output, synthetic tests, all seven
    levels extract, and every unnamed condition or effect is reported.
    - `flashbackz-extract`: 1,097 characters and 418 behaviors; no unknown operations. The
      overlay names Conrad and the city ambush; other behaviors keep systematic names.
  - [x] Behavior engine: tables load into the content pack and run with the stated evaluation
    order. Gate: the android ambush (civilian, gunman, defensive fields) runs from tables and
    matches its 260-update capture and the whole-world replay.
    - `src/shared/behavior/`: the whole vocabulary is implemented. flashback-re
      `tools/engine_regression.py`: all 40 retained captures (9,116 updates) match the original
      for every character; one documented copy-protection exclusion.
  - [x] Complete the vocabulary for the remaining unmapped families: every original
    condition and effect is implemented, so the engine runs every character of every level.
  - [x] Revised 2026-10-08: since the engine runs whole levels, the families are replaced
    together rather than one at a time. Presentation research: the original's character
    drawing (0x2539, draw lists, edge rooms), HUD, labels, world messages, inventory screen,
    scene and sound requests, and input processing, recorded in flashback-re.
    - flashback-re `docs/rules/engine-presentation.md`.
  - [x] Table-driven level scene: every level runs on the behavior engine (Conrad included) and
    is presented from the engine's state and requests. Gate: the native game reproduces the
    original frames of the retained captures with recorded video, and its per-update character
    state matches the engine regression.
    - `src/shared/scenes/level.zig`: playfield, HUD, labels, password, world messages, inventory,
      options, films from the scene table, continue from checkpoints, shake, demos and new games.
      flashback-re `engine_regression.py`: 9,116 updates (every character, inventory links
      included), 788 gameplay frames and 234 message frames match. Films play with their
      music (flashback-re `docs/rules/engine-music.md`: no music during play).
  - [x] Remove the hand-coded families, their importers and their tests once the scene
    replaces them. Golden traces are re-recorded and each difference is explained.
    - 2026-10-09: 129 files (about 29,000 lines) removed. The golden traces recorded the
      removed scene's output, so they are retired rather than re-recorded: the engine
      regression compares with the original itself, update by update and frame by frame.
- [x] **Systematic gap detection (user concern, 2026-10-08):** replace reliance on manual play
  with a family-agnostic world comparison.
  - The regression covers every capture, level and room; the ending, the introduction and the
    installation have their own comparisons (items below and above).
  - [x] Every character, every update: flashback-re `engine_regression.py` compares the whole
    world (state, position, room, cursor, health, counter, flags, sprite, inventory links)
    with every retained capture and the jungle demo, plus the recorded frames.
  - [x] Cover every level: capture the two other original demos (alien surface, tower) and a
    per-room sweep of all seven levels (enter each room through normal input), then add them
    to the regression. Gate: the regression reports every level and room against the original.
    - 2026-10-09: both demos and 213 of the 219 rooms (Conrad placed in each room through the
      capture tool's reported synthetic spawn; entering through normal input remains for
      routes) match: 262 captures, 37,250 updates, every character, sound request and recorded
      frame. Open: six rooms whose capture stops on a film the tool does not skip (city 28,
      earth city 3, 44, 50, 51, spaceport 58).
    - Later on 2026-10-09: all 219 rooms. Those six were cut short by the capture's time limit
      (the level's opening film); their sessions end in a defeat or a level exit, which the
      regression now respects. With the spaceport's own start, 269 captures and 38,086 updates
      match.
- [x] Held directions under the key latch (flashback-re engine-presentation 6.1a; 0x7d5c-0x7d9c):
  on the title menu, the Skill page, the options dialog, the continue screen and the inventory a
  held direction registers again only on the keyboard's repeat, no sooner than 20 film timer
  ticks after the press and then every 12. Gate: agent runs holding a direction.
  - 2026-10-09 (`a381a22`, `key_latch.zig`): Down held half a second with a repeat every
    frame moves the title menu's selection three times (ungated it moved 31); the continue
    screen's two choices are unaffected by repeats; the options dialog also stops taking
    repeated Enter and arrows as new presses.
- [x] The title menu's idle demo: after 2,400 film timer ticks on the main menu without Up or
  Down the original chooses Demo (flashback-re docs/title-menu.md). Gate: the original's delay
  measured, and an agent run.
  - 2026-10-09: measured 34.38 s from the menu's start to its Demo choice; flashbackz starts
    the demo 34.4 s after the menu appears and restarts the wait on Up or Down.
- [x] The title menu's pages frame for frame: the main menu with each item selected, Skill,
  Info and the password page while a code is typed, and their keys. Gate: the original's frames
  of each page (flashback-re capture) match flashbackz's.
  - 2026-10-09, flashback-re docs/title-menu.md: 33 of 33 steps identical after the Skill page's
    wrap and the code entry's blinking cursor (`7711cc1`).
- [x] At most two asset paths (user decision, 2026-10-09): the game's files are the two disks (or
  directories extracted from them); the hosts accept one or two paths instead of up to eight.
  Gate: tests, `--help`, a third path refused.
  - 2026-10-09: done; `flashbackz-sdl disk1.img disk2.img disk3.img` says "unexpected argument
    disk3.img".
- [x] Continuous effects play without gaps (user report, 2026-10-09: the fan in level 2's first
  room sounds weird). The effects queue kept at most 20 ms (882 frames at 44.1 kHz) ahead of a
  device that takes 1,024 frames a period, so SDL filled 142 frames of silence into every
  period: 670 gaps in 10.8 s of that room. Effects keep the same lead as music (50 ms), one
  value for both. Gate: the SDL host in that room, no gap in the effects output.
  - 2026-10-09: `f7f7d3d`; in that room the SDL output had 670 gaps of 142 frames in 10.8 s,
    and has none in 12.7 s after the change.
- [x] SDL bindings from SDL's own headers (user decision, 2026-10-09): build.zig translates SDL2's
  headers (`b.addTranslateC`: the system headers on Linux, the `sdl2` package's for Windows)
  into the module the SDL host imports, and the hand-written `src/sdl/sdl.zig` with its layout
  test goes. SDL2 stays. Gate: tests, the Windows cross-build, and the SDL host starting,
  presenting and playing sound as before.
  - 2026-10-09: `380f21e`; 195/195 tests, both Windows executables; old and new SDL hosts give
    the same title-menu screenshot, byte-identical audio and the same events from real keys.
  - [x] The key table and the tests name SDL's constants (`SDL_SCANCODE_ESCAPE`, ...) instead
    of copying their numbers. Gate: the same table, tests.
    - 2026-10-09: `1898004`; the same 93 (scancode, key) pairs in the same order; tests pass.
- [x] One program fewer (user decision, 2026-10-09): `--extract DIR` on the SDL and agent hosts
  writes the data set and exits (with `--names FILE`; playing options are refused with it), and
  the separate `flashbackz-extract` goes. The research regression extracts with the agent.
  Gate: the extracted files equal the old extractor's, both hosts' `--help`, the regression.
  - 2026-10-09: both hosts write the same 428 files as the old extractor; the engine regression
    passes with every data set re-extracted by `flashbackz-agent --extract`.
- [x] Command lines from one table (user decision, 2026-10-09): bring zig-utils' `clap.zig` (MIT,
  JD Michaud) into the native module, ported to Zig 0.17 with repeated options, a variable
  number of positional arguments, `--`, `--name=value`, errors returned instead of exiting,
  and help generated from the same description; the SDL host, the agent host and the
  extractor parse with it, so every option (`--data` included) appears in `--help`. Gate:
  synthetic parser tests, each program's `--help`, and the earlier agent runs unchanged.
  - 2026-10-09: `src/native/clap.zig`; the three programs' `--help` list every option (`--data`
    included, from the shared description); the agent session keeps its hashes, and reading
    an extracted data set through `--data` gives the same.
- [x] Escape skips films again (user decision, 2026-10-09): the Delphine Software logo, the
  introduction, the start and game-over films, in-game films and the ending's films end on
  Escape as on Backspace or Tab, although the original ignores Escape in films. A held Escape
  that reaches the title menu as a key repeat does not choose Quit. Gate: agent runs.
  - 2026-10-09 (`films: Escape skips them again`): Escape during the logo starts the
    introduction and a second reaches the menu; held into the menu with repeats it does not
    quit, a fresh press does; it ends the start film and the jungle's opening film without
    opening the options dialog.
- [x] The original's other keys (flashback-re engine-presentation 6.1, engine-music 9; key
  handlers 0x7b60-0x7c5c). P is a global toggle that only films read, so a P pressed during play
  holds the next film until P is pressed again; keypad + and - change the music volume one step
  per press (0..63 from 48, for notes started afterwards) for the session; S switches the sound
  effects on or off, as the options row does, during play only (not in films, the inventory,
  messages, the continue screen or the title); J turns the joystick option on at the next
  gameplay frame (not in a demo), K turns it off at once. The calibration dialog J shows for an
  analog joystick is left out: SDL controllers need none. Gate: agent runs.
  - 2026-10-09: on the Password page these keys are only characters of the code, as in the
    original (its code entry leaves the keyboard to the BIOS); a P in PICOLO had held the
    city's opening film on a black screen (fixed).
  - 2026-10-09, agent (`b9e68c2`): S toggles the effects in play and is refused during the
    opening film; J at the title turns the joystick on in the level, K off; P at the title
    holds DEBUT at its first picture until the next P, then it plays on as if just started;
    thirty keypad presses take the menu music's RMS from 1,603 to 134 (-) or 5,819 (+).
    Not reproduced: the continue screen draws scene 72 itself, so P does not hold it there.
- [x] The ending: scene 61's film list under END31, the final score screen (scene 73) and the
  return to the title. Gate: compared with an original capture of the ending.
  - 2026-10-09, flashback-re `tools/compare_ending.py` (engine-ending-zoom 12.5): the credits
    follow the original's replay-mode rules and their state is exact at all 3,996 list presents
    given the original's hold values; with the modern cadence they stay within a few characters
    and end on the same step. 4,479 of 4,799 film presents and all 142 score frames match; the
    rest differ on film polygon edges (next item). The agent host plays the ending from the
    title's eighth code and returns to the title; the level route (scene 61) was not played.
- [x] Film polygon edges: 320 of the ending's 4,799 presents and 18 of INTRO2's 380 frames differ
  from the original on polygon edges or one- and two-point shapes (at most 337 pixels; FIN,
  MEMO, ESPIONS, VOYAGE). Gate: the ending and introduction comparisons report every film
  frame identical, or each remaining difference is explained and accepted.
  - 2026-10-09, flashback-re shape captures (`capture_polygons.py`, `--shapes`,
    `compare_shapes.py`; engine-ending-zoom 3.5, 3.6): polygons, lines and scaled ellipses
    rasterize exactly; rotated ellipses keep their column (fixed) and a caption's bottom row
    follows the display page (fixed); a polygon cut by the top edge starts each side where the
    original does (fixed). Now: logo 153/153, INTRO1 260/260, INTRO2 378/380 (one stale-span
    pixel), ending 4,794/4,799, and every shape of VOYAGE and MEMO matches in normal mode.
    Open: five ending presents, four of them the first after a held picture (replay-mode page
    handling), and the stale-span pixel.
  - User decision 2026-10-09: accept and document these remaining differences. Recorded in
    flashback-re engine-ending-zoom 3.5 and 12.5.
- [x] The zoom view option (flashback-re engine-presentation 4.3), including the automatic
  combat zoom. Gate: original frames with the option on.
  - flashback-re `docs/rules/engine-ending-zoom.md`; all 816 frames of four zoom captures match.
- [x] Catch-up walks: when a frame is late the original repeats the walk without presenting.
  Decide with the user whether the modern cadence should reproduce it; record the decision.
  - User decision 2026-10-09: reproduce it. A late frame runs one more walk (input read
    again, countdowns not decremented, no scene check) before the next present, and the next
    frame waits three ticks instead of two (flashback-re engine-update 1.2 steps 11 and 19).
  - 2026-10-09: implemented (`scenes/level.zig`, `World.update`'s walk kinds). Time in modal
    screens and films does not count, as in the original (engine-update 1.3). The engine
    regression still matches all captures, and an agent run with steady pacing gives the same
    state and frame hashes as before. Agent `--stall`: a 20 ms stall is absorbed with no
    catch-up; a 1 s stall gives one catch-up walk, two stalls two, and a stall during a film
    none.

- [x] Errors that name the file (user request, 2026-10-09): when a disk, the save or data
  directory or the Mega Drive cartridge cannot be opened, the hosts say which path, what it was
  for and why in words ("cannot open the disk disk1.img: not found"), not an error name. Gate:
  tests; each host's message for a missing disk.
  - 2026-10-09: both hosts and --extract print "cannot open the disk disk1.img: not found".

- [x] A standalone build (user request, 2026-10-10): `zig build -Ddisk1=PATH -Ddisk2=PATH
  [-Dmegadrive=PATH]` checks the user's files and builds them into flashbackz-sdl, which then
  plays with no argument (the DOS edition, with the Mega Drive tunes when the cartridge is
  built in); paths on the command line still take precedence. Such an executable holds the
  original game: it is never committed nor distributed. Gate: a build with the files and one
  without; the bundled SDL game starts with no argument; a wrong file stops the build.
  - 2026-10-10: built-in files read when no path is given; the SDL game starts with none and
    plays the built-in cartridge's tune in level 2; wrong files stop the build.

- [x] The game's names (user request, 2026-10-10): the SDL game is `flashback` (never with
  files inside) and the standalone build is a second executable, `flashback-standalone`, built
  only with the -D options; each says its own name in its help and messages. Gate: both builds
  and their names; the standalone starts with no argument, `flashback` as before.
  - 2026-10-10: done; on Windows flashback.exe and flashback-standalone.exe.

- [x] A short README and a licence (user request, 2026-10-10): the README from scratch, with
  only what the repository is, how to start the game, how to build it and the licence; the
  repository's own code under MIT (user's choice), the third-party parts under theirs. Gate:
  each command in the README run as written.
  - 2026-10-10: done; every command run in a worktree beside the user's files.

- [x] Sound starts without `SDL_AUDIODRIVER=pipewire` (user report, 2026-10-10: on Ubuntu 24.04
  with SDL2 2.30.0 the audio start hangs; the variable works around it). Cause, found on the
  user's machine: Zig 0.17 gives every thread a 256 KiB alternate signal stack in thread-local
  storage (`std.options.signal_stack_size`), so glibc cannot start a thread whose stack is
  256 KiB, and SDL 2.30.0 waits forever for its PulseAudio hot-plug thread, created with such a
  stack. The SDL game turns the per-thread signal stack off; SDL keeps its own driver order.
  Gate: tests; on the user's machine the game starts with sound, without the variable.
  - 2026-10-10: on the user's machine, no variable: "audio pulseaudio", 221,184 frames played
    in 5 s, normal exit (it hung before).

- [x] The executables are `flashbackz` and `flashbackz-standalone` (user request, 2026-10-10,
  "add the z back"). Gate: both builds, their help and messages carry the names.

- [x] Each film plays once (user report, 2026-10-10: the jungle's opening plays twice). Since
  levels open with their scene (2026-10-09), the title menu's own DEBUT before the jungle (from
  2026-10-04: Start, a jungle password, Retry) repeats the level's opening. The title menu plays
  no level film. Gate: every way into a level opens its film once; no scene a behavior requests
  is also played by the title, game-over or ending screens.

- [x] Level atlas (user request, 2026-10-10: "Make it a proper tool in the repo"):
  `flashbackz-atlas` draws every level into one PNG, a row per level, its name in the game
  font on the left and its rooms on the right, placed by their links on black. The game's
  joins that cannot lie flat (links whose place is taken, transports between areas) carry
  matching lettered tags. The PNG holds the game's art: written where the user asks, never
  committed. Gate: `zig build atlas`; tests cover the layout, the packing and the PNG writer;
  the poster from the floppy images marks every join between its drawn areas.
  - 2026-10-10: 9 tests (layout, joins, ownership, packing, PNG round trip, font, glow). From
    the floppy images: every drawn piece is tagged to the rest (city 6 joins, tower 6, Earth
    1, alien base 1); the jungle, spaceport and alien surface lie flat.

- [x] Atlas: transit lines stand apart (user report, 2026-10-10: the city's subway stations are
  drawn side by side, "In reality they would not"). A ring of links whose pictures never
  continue, and without which its rooms lead into separate parts of the level, is a transit
  line: the layout does not follow it, so each station stays with its district, and its rides
  are tagged. Pieces tied by joins are packed near each other; no tag covers another. Gate:
  tests; on the poster the city's districts stand apart, each with its station, the four rides
  tagged; the tower's floors are unchanged.
  - 2026-10-10: 12 atlas tests. City: 6 pieces (four districts with their stations, the red
    district, Asia's station by the start area), rides B-E tagged around the loop; tower: one
    piece, its six wraps tagged as before.

- [x] Atlas: the city along its subway (user request, 2026-10-10: "make the subway station way
  below all the rest and spread far apart"; "we get rid of the letters"). A level with a transit
  line is drawn along it: its districts side by side on one ground, the start's first, the others
  in the order the line reaches them; its stations on one row below them all, each under the room
  it leads up to; no tags. Gate: tests; on the poster the city's four stations stand on one row
  in the line's order, each under its district's room, and the city has no letters; the other
  levels are unchanged.
  - 2026-10-10: 13 atlas tests. City: Asia, America, Africa and Europa's stations on one row,
    each under the room it leads up to, the districts on one ground in that order, the red
    district last; no tags. The other levels' maps are pixel-identical to the previous poster
    (only the city's glow tail differs, by at most 2 of 255). Poster 9120x11824.

- [x] Atlas: the city's districts close in (user request, 2026-10-10: "connect the america
  station to its room up and realign all the subway stations to it", "bring the four space
  closer together", "move the "red" zone below", "remove the letters in death tower level"). A
  station with no other room of its district near the spot right under its room stands there,
  touching it, and the line's row is its row. The districts close in, overlapping where their
  rooms stay apart, never across another station's way down to its room; the pieces off the line
  go below. Tags mark only the joins between pieces: the tower's floors that wrap around carry
  none. Gate: tests; on the poster America's station touches its room and the four stations
  share its row, the districts stand closer than before with no unlinked rooms touching, the red
  district is below; the tower has no letters, Earth and the alien base keep theirs.
  - 2026-10-10: 13 atlas tests. City: America's station touches its room and the four stations
    share its row; every other pair of rooms from different pieces is at least 128 px apart; the
    map is 4224 px wide (was 6656), the red district below, under Europa's district. The tower
    has no letters (its 12 tag spots are its only change), Earth and the alien base keep theirs,
    the other levels are pixel-identical. Poster 6688x12432.

- [x] Atlas: Earth's two parts aligned (user request, 2026-10-10: "realign the two part of earth
  and remove the A label"). Off a transit line, the area a transport leads to stands beside the
  room it leaves from, on that room's row with one empty cell between them, when it keeps an
  empty cell all around; the two become one piece, untagged. Gate: tests; on the poster Earth's
  taxi stand and the street it leads to share a row, the club's part to the right, and Earth has
  no letters; the other levels are unchanged.
  - 2026-10-10: 14 atlas tests. Earth: one piece, the taxi stand's room and the club's street
    on one row a cell apart, no letters; its map 5120 px wide. The other levels are
    pixel-identical (Earth's glow shifts by at most 1 of 255 at their edges). Poster 7584x12648.

- [x] Atlas: every map glows (user report, 2026-10-10: "Looking at the level 2 borders for
  example, I don't see any glow"). The glow borrowed each map's light at one strength, so dark
  maps barely glowed: just outside its rooms the city's light was 28 of 255 and the tower's 20,
  where the jungle's was 49. Each map's light is scaled so that just outside its rooms its
  brightest channel averages one level, the jungle's, in the map's own colors. Gate: tests; on
  the poster the city and the tower glow at their borders like the jungle.
  - 2026-10-10: 14 atlas tests (a dark map glows as brightly at its edges as a bright one).
    Every map's light averages 48 just outside its rooms (it was 20 to 49); the jungle's is
    within 2% of before; the maps themselves are unchanged.

## Gamepads and save anywhere — user decisions, 2026-10-10

Additions to the DOS edition. The user's pad is a 6-button Mega Drive controller that SDL2 lists
as "not a gamepad" (GUID 03001a0da30c00002400000011010000, 3 axes, 10 buttons); sorz met the
same and gives such joysticks a generic mapping (sorz `src/sdl/backend.zig`, reused with the
user's permission). Decisions: the first pad press turns the Joystick option on; fixed layouts
now, remapping later; eight save slots and a quick slot (F5/F9); a save from another version
is listed and refused; SAVE GAME in the pause dialog, LOAD GAME on the title menu ("having the
LOAD dialog in the in game menu is awkward").

- [x] **GS-1 — One input tracker** — In a level, every event reaches one tracker, whatever is
  open: play, the options dialog, the inventory, a message or a film (code review B3, D3). The
  fixed layouts turn keys and pad buttons into the game's eight actions (the input byte,
  unchanged) and pause; the options dialog and the inventory read actions, not keys; each pad
  holds its own buttons. As in the original (flashback-re engine-presentation 6.1, 6.4): a key
  released during a modal screen is armed again; the inventory closes with Tab or Backspace, its
  one bit; a key pressed during a film and held at its end counts only when pressed anew; with
  the Joystick option the pad works in the inventory. Escape stays a held level, as the
  original's (a press and release between two frames is lost there too; review B6 kept). The
  title, continue and ending screens move to actions with GS-3. Gate: tests; the agent sessions
  of keyboard play, options, inventory, pad, title and continue keep their hashes, except where
  these rules change them.
  - 2026-10-10: 253 tests. Eleven agent sessions (walk and run, options, options with keys held,
    inventory, pad, pad off, title, code entry, abort and retry twice, the city) keep their
    state and frame hashes. Changed as the original: Right released in the options dialog then
    held again walks (x 48 before, 96 now); Backspace closes the inventory; Right pressed during
    the opening film and held after it waits for a fresh press; with J, the pad's Y opens and
    closes the inventory and its D-pad walks after.
- [x] **GS-2 — Settings in one place** — Sound effects, music, volume, joystick and zoom are one
  value the game owns, read where they are used, saved as one record that replaces VOLUME; a
  record of another version is refused and the defaults apply. Gate: tests; a setting changed
  in the options is there after a restart.
  - 2026-10-10: 254 tests (round trip; another version, a volume past 100, a missing or unknown
    field and the old VOLUME record give the defaults). Agent: SOUND FX turned off in the options
    is off in the next run with the same save directory; the record reads `.{ .version = 1,
    .volume = 100, .sound_fx = false, ... }`. The eleven GS-1 sessions keep their hashes, each with
    its own save directory now that J's joystick lasts between runs.
- [ ] **GS-3 — Gamepads everywhere** — A joystick SDL has no gamepad mapping for opens with a
  generic one; the first pad press turns the Joystick option on; every screen answers the pad
  (D-pad or stick to move, A to confirm, B to go back, Start to pause); level codes are entered
  with it (up and down change the letter, left and right move); each pad holds its own buttons;
  a CONTROLS page lists each action's key and button. Gate: tests (SDL's virtual joystick, the
  agent's axis events); with the user's pad, the SDL game plays, pauses and takes a level code.
  - [x] 2026-10-10: 257 tests, among them SDL's virtual joystick of the user's pad (3 axes, 10
    buttons) opened as a gamepad, START its tenth button. Agent: the stick alone walks (the
    option turns on); START, the D-pad and B turn SOUND FX off and resume; B on ABORT GAME
    resumes; A abandons and A retries on the continue screen; the title's D-pad and A choose
    EXPERT and start; B on its main page does not quit; a code entered with the D-pad equals
    the one typed; START skips the opening film. The title, continue and ending screens keep
    their keyboard rules; pad presses reach them as actions. The eleven keyboard sessions keep
    their hashes (the pad one now walks: its D-pad turns the option on).
  - [x] With the user's pad in the SDL game: play, pause, a level code (user, 2026-10-10: "The
    gamepad works. The button mapping is not good though").
- [ ] **GS-3a — Pad buttons remapped** (user decision, 2026-10-10: "Remapping now"). The
  platform names each pad's model (SDL's GUID) and whether it has the generic mapping; the
  settings keep, per model, the pad button for ACTION, GUN, USE, ITEMS and PAUSE, and the game
  applies them to the pad's button events before any screen sees them. On the CONTROLS page the
  D-pad picks a row and the pad button pressed there becomes its action's (the one it had swaps
  places); DEFAULT restores the layout, BACK leaves. Generic pads show their buttons by number.
  The settings record's version becomes 2. Gate: tests; the agent binds ACTION to another button
  and that button acts; with the user's pad, its layout chosen in the game is there after a
  restart.
  - [x] 2026-10-10: 259 tests (layouts stand buttons for the fixed ones and swap; models kept,
    forgotten at the fixed layout or when full; record v2 round trip; the CONTROLS rows; the
    virtual pad's model, generic, START its tenth button). Agent: ACTION bound to LB on the
    CONTROLS page, LB with right runs as A did, A then gives nothing; the record keeps the
    layout under the agent pad's model; DEFAULT empties it. Keyboard and pad sessions keep
    their state hashes.
  - [ ] With the user's pad: a layout chosen in the game, there after a restart.
- [ ] **GS-3b — A held pad button counts once on modal screens** (user report, 2026-10-10:
  talking to someone with the pad "autofire[s] the dialog very quickly"). The pads' bits were
  never released by modal screens, so a held button turned a message page at every poll. In
  the original's latch the joystick's presses register like the keys' (flashback-re
  engine-presentation 6.2, 6.4): a pad bit held when a modal screen latches the keys, or that
  turned a page, counts again only once released; when the screen ends, a pad button still held
  counts again at once, as the original polls the joystick. Gate: tests; the agent turns one
  page per pad press; keyboard and pad sessions keep their hashes otherwise.
  - [x] 2026-10-10: 262 tests (under the latch a held pad button counts once, again once
    released, and at once when the screen ends). Keyboard and pad sessions keep their hashes.
    No world message is near enough to a level's start for an agent session.
  - [ ] With the user's pad: one page per press when talking to someone.
- [x] **GS-3c — The pad's buttons act as their keys on the menus** (user report, 2026-10-10:
  GUN "will exit the menu and have Conrad draw his gun which is inconsistent with the other
  buttons"). On every menu page A, B and X act as Shift, Space and Return: they choose; START acts
  as Escape: back, never abandoning the game, and on the title's main page it chooses. When a
  modal screen ends, a pad button still held counts again only once released, as a key (this
  replaces GS-3b's "counts again at once"). Gate: tests; the agent's B chooses on the dialog and
  the slots' page and START goes back; after the dialog closes on a held button Conrad does not
  act; keyboard sessions keep their hashes.
  - 2026-10-10: 268 tests. Agent: the options dialog closed with B held until well after ends
    in the same state as closed with START (Conrad does not draw his gun); B on the slots' page
    saves into the quick slot. Keyboard sessions keep their hashes against the build before.
- [x] **GS-4 — The save** — A save holds the level, difficulty, score, random generator, what is
  carried between levels, the world (every character, the terrain, contacts, mailboxes, the
  save terminal's checkpoint) and the level's play state; art, sound and pictures are reloaded
  and redrawn. It is taken only while the pause dialog is open. A readable record with a version
  and the data set's fingerprint; another version's save is refused. Gate: the agent plays,
  saves and plays on, then loads and replays the same input: every character identical on every
  update after.
  - 2026-10-10: 262 tests (a synthetic world saved, read back and run on with varying controls
    and catch-up walks stays identical for 20 updates; another version, data set, a broken
    record or a world of another size is refused). Agent: the state after a load equals the
    state at the save; walk for walk after them, with no input, 286 jungle walks and 432 city
    walks (252 distinct states) are identical. With input, the agent presses keys by host frame
    and the loaded level's clock starts at the load, so the same frames meet other walks; the
    walk-for-walk comparison is therefore made without input. A save is 218 KB of ZON.
- [ ] **GS-5 — Save screens** — SAVE GAME in the pause dialog; LOAD GAME on the title menu; eight
  slots, each with its level, play time, date and a picture of the moment; overwriting asks;
  another version's save is shown, not loaded; F5 saves to the quick slot and F9 loads it during
  play. Gate: in the SDL game, a save made in play loads from the title and plays on.

## Code review, 2026-10-10 — `docs/review-2026-10-10.md`

The review the user asked for (2026-10-10), on commit `a9b6b26`. Each finding here is a
checkbox; fixing one adds its own plan item first, as usual. Order: B4 with D4 (the user asked
about the placeholder), B1, B2 with D2, B7, D1, then the rest. Common-sense calls (no user
decision needed): the MUSIC option controls the Mega Drive tunes (D2); the animations' per-frame
movement and sounds move into the data set, as DESIGN 4 already says (D5); content is checked at
load and fails loudly there, devices are adapted to (D6).

- [x] **B4 and D4 — No placeholder game** (user, 2026-10-10: "What is this placeholder??? It's
  like a game. Sounds like one from the 80s."). The template's smoke program (a bouncing ball, a
  click at each bounce, F2/F3 saving it, TITLE.TXT) and the template code nothing uses leave the
  product. Without its game files the game stops with a message naming what is missing and how
  to give it, in both hosts; `zig build smoke` checks that path. Gate: tests; the SDL game and
  the agent without disks print the message and exit with an error status; with disks the
  keyboard sessions keep their hashes.
  - 2026-10-10: both hosts without files print "the game's files are missing: give both floppy
    images (disk1.img disk2.img) or a directory extracted from them" and exit 2; `zig build
    smoke` checks that. Also gone: the mouse, relative mode and its Ctrl+F10 chord, text input,
    the input-recording samples. Kept: the storage's listing and deletion (the atomic-save
    fault tests use them), the vendored sorz chips (DESIGN 6), the settings' Difficulty (the
    save record needs an exhaustive one). About 835 lines fewer; keyboard sessions keep their
    hashes; 28/28 build steps.
- [ ] **B1** Using any of the city's four map terminals ends the game. High.
- [ ] **B2** An audio device granting another format ends the game or overruns a buffer. High on
  Windows. With D2.
- [x] **B3** A key released in the options dialog or the inventory is ignored when pressed again.
  Fixed by GS-1.
- [x] **B4** Missing or partial game files start the template's placeholder game instead of
  failing. With D4. Done: "No placeholder game" above.
- [ ] **B5** A catch-up frame drops the first walk's world message and its zoom hits (if the
  original keeps them).
- [x] **B6** Escape in a level reacts to auto-repeat and a quick tap is lost. Kept: the original
  polls Escape the same way (GS-1).
- [ ] **B7** The data-set loader accepts data the engine cannot run.
- [ ] **B8** The agent without `--saves` uses and creates the user's real save directory.
- [ ] **B9** Command-line options silently ignored, and standalone `--extract`.
- [ ] **B10** Sprite decode errors are swallowed.
- [ ] **B11** The continue screen ends the game when 128 key events are queued.
- [ ] **B12** The Mega Drive cartridge reader is not overflow-safe; its checksum check can be
  bypassed.
- [ ] **B13** The extractor's robustness on an unexpected edition.
- [ ] **B14** Smaller confirmed defects (the review's list).
- [ ] **D1** The engine models the original's memory layout in places. Decided (user,
  2026-10-10: "My rules was that we produce a modern maintainable code base. Make things
  coherent, easy to read and modify. Use your common sense."): each quirk becomes a named game
  rule where it holds; what truly depends on how the original laid out its data stays exact in
  one small, explained module.
- [ ] **D2** One audio device, five owners, no mixer. With B2.
- [x] **D3** Input state updated in one path only; settings in hand-synchronised copies. Fixed by
  GS-1 and GS-2.
- [x] **D4** The template's placeholder (the bouncing ball) and unused template code are still in
  the product. With B4. Done: "No placeholder game" above.
- [ ] **D5** Module boundaries leak in both directions.
- [ ] **D6** Every runtime error is fatal, and validation is deferred to first use.
- [ ] **D7** Smaller design issues (the review's list).
- [ ] **R1-R5** Readability: unnamed magic numbers, behavior tables' readability, dead code, tests
  missing or not testing their name, style.
- [ ] **P1-P3** Performance: the documented build is Debug, audio latency, minor waste.
- [ ] **Documentation**: the wrong or stale claims of the review's section 5, in DESIGN.md,
  README.md, docs and code comments. The user granted (2026-10-10) correcting DESIGN.md's
  statements of fact so they describe what exists; changes to its rules still need approval.

## Mega Drive music during play — user decision, 2026-10-09

An addition to the DOS edition: the tunes the Mega Drive edition plays during play, sounding
like the Mega Drive ("make it sound like the megadrive"). sorz's sound chips are reused (user
permission, 2026-10-09); improvements found here go back to sor's agent. The cartridge is read
at run time from the user's file; without it the game is the DOS edition, unchanged. Research:
flashback-re MD1–MD3.

- [x] **MD-A — Mega Drive sound chips** — sorz's YM2612 (its port of ymfm, with ymfm's BSD
  notice), PSG, DAC player, model 1 output and resampling, as a module of their own.
  Gate: their tests pass here.
  - 2026-10-09: src/shared/audio/megadrive, from sorz 6d634ee; 228/228 tests.
- [x] **MD-B — The cartridge as an input** — An option naming the user's cartridge, read at run
  time and validated; nothing of it committed. Gate: tests; without the option the agent
  session keeps its hashes.
  - 2026-10-09: `--megadrive FILE`; only Flashback (Europe) (En,Fr) is accepted (SHA-256); the
    reference session keeps d6536a1e9184b41f / c029ec16ed8214c5 with and without it.
- [x] **MD-C — The tunes' player** — Plays the cartridge's tunes 68–75 (its 3-channel FM
  tracker) through the chips. Gate: its writes equal the cartridge's for every tune
  (flashback-re MD2).
  - 2026-10-09: `audio/megadrive_tunes.zig`; flashback-re `md_tune_model.py check --probe`:
    identical writes for all eight tunes. The chips play them in MD-D.
- [ ] **MD-D — Music during play** — The tunes start, stop and fade where the cartridge plays them
  (flashback-re MD3), with the effects and the films' music. Gate: a played route in the SDL
  build where each tune starts where the cartridge starts it.
  - [x] 2026-10-09, `925476f`: with `--megadrive`, effects 68-75 play the tunes on the chips,
    mixed with the effects; a film stops them. The engine asks for every request the original
    makes (68-77 at the original's updates in all engine-regression captures). SDL build:
    tune 68 starts on entering level 2's room 17, where the DOS original asks for it.
  - [ ] The cartridge's own placements (flashback-re MD3), and the other tunes heard in play.

## Historical CD implementation/research milestones

The sibling flashback-re plan owns research. Exact fidelity and maintainability are independent
gates. All runtime work uses the original as the reference; no approximate acceptance stage.

- [x] **00 — Independent architecture review** — Depends: reference survey.
  - Design scene lifecycles, actor state, movement/collision, inventory, world behaviors, content,
    rendering and audio for readability and extensibility; original code boundaries are no guide
    to modern module/API boundaries (user clarification, 2026-10-03).
  - Gate: a concrete design explains ownership and extension points, demonstrates adding a room
    and actor behavior, and avoids translated machine state or legacy instruction dispatch in
    the engine. Review this independently of all fidelity comparisons.

- [x] **01 — Platform foundation and initial architecture** — Depends: 00.
  - Adapt the template's Zig skeleton and establish typed game/content boundaries, with no
    multiplayer. Write the initial design from measured Flashback requirements.
  - Gate: standalone synthetic build, tests, smoke, no-SDL headless verification and browser
    checks pass; placeholder output is explicitly labeled; toolchain versions are recorded.
- [x] **02 — Content sources and compatibility parsers** — Depends: 01, research 06.
  - Superseded by the floppy edition (2026-10-04 pivot): both images import through FAT12 and the
    installation archives, rooms decode from the compact level files, and the extracted data
    set is typed; the installation is reproduced byte for byte (installer item above).
  - Read the user's original CD or extracted directory into named, validated content; keep
    source layout and legacy scripting semantics at the compatibility boundary.
  - Gate: synthetic malformed-input cases pass; decoders agree with independent original
    observations; game code consumes typed content rather than executable addresses.
- [x] **02a — Direct disc-image argument** — Depends: 01.
  - Both native hosts accept an ISO or supplied MODE1/2352 BIN image in the existing positional
    asset argument, reading files directly through the same asset contract as a directory.
  - Gate: synthetic image and malformed-input tests pass; all original files read from the
    image match the inventory, and Linux/Windows hosts build without extraction dependencies.
- [x] **03 — Exact first playable room** — Depends: 02, research 05 and 07.
  - Superseded by the floppy edition: every room of every level is compared with the original
    (269 captures, systematic gap detection above), with frames, sounds and the mixer's blocks.
  - Scene flow, input, Conrad, collision, animation, inventory, drawing and sound through the
    shared simulation and the SDL/agent hosts.
  - Gate: exact state/events/timing/frame/audio comparisons pass, and the SDL build is played
    using real input; implementation review confirms readable game concepts and bounded work.
- [x] **03a — Interactive scene integration for development** — Depends: verified movement/rendering slices.
  - Add an explicit jungle development entry to both native hosts, using shared content,
    session, input and presentation with direct disc access. Keep unfinished mechanics visible.
  - Gate: actual SDL input drives the shared controller, headless held-input replay agrees,
    and an original frame checkpoint matches through the native application. This does not
    close the complete first-room gate, cinematics, audio or scheduler acceptance.
- [x] **03b — Normal executable launch and game entry** — User priority, 2026-10-04.
  - Load the original startup presentation, make the title menu interactive, and connect Start
    through the original introductory/wake-up sequence to the shared jungle scene.
  - Gate: direct ISO/BIN launch, movie completion/skipping, menu input and Start work in the
    actual SDL executable; frames and movie data are checked against the supplied original.
    Broader gameplay, password/demo coverage and audio completeness remain separately tracked.
- [ ] **04 — Whole local game** — Depends: 03, research 08 and 09.
  - Status 2026-10-09: every level, room and difficulty runs and is compared; the ending, the
    score and the codes work; catch-up walks and the film differences are decided (2026-10-09).
    Waiting on the user playing the game through.
  - User decision 2026-10-09: the user plays the game through and reports what they find; this
    item stays open until then.
  - All levels, difficulties, enemy and puzzle behaviors, menus, demos, cinematics, languages,
    sound modes, checkpoints/passwords and configuration.
  - Gate: exact behavior coverage is complete and the user can play the game through.
  - Audio acceptance uses AdLib FM plus game-supplied PCM; MT-32 emulation is not required
    (user decision, 2026-10-03). Reuse only generic chip code after review, with its tests and
    attribution; Flashback's audio engine is independently designed and verified.
- [ ] **05 — Target acceptance** — Depends: 04.
  - Status 2026-10-09: Linux builds and runs (SDL and agent hosts); Windows cross-builds (below);
    browser support is excluded by the user (2026-10-04). Waits on item 04.
  - User decision 2026-10-09: cross-build Windows now (Linux gameplay works).
  - [x] Windows cross-build of both hosts (`zig build all -Dtarget=x86_64-windows-gnu`), with
    SDL2 from source; fix what fails. Gate: a successful build, recorded with its toolchain.
    - 2026-10-09, Zig 0.17.0 on Linux, flashbackz `6647a46`, SDL 2.32.10 from the pinned
      package: the SDL host, the agent host and the extractor build unchanged (54 s); they
      import only Windows system DLLs and the universal C runtime. Under Wine the agent host
      gives the Linux build's hashes for the smoke run and for a 2,600-frame session played
      from both floppy images. The SDL host was not run (no Windows machine; the user accepts
      Linux runtime checks plus the cross-build).
  - Linux, Windows and browser packaging, inputs, audio, storage, lifecycle and long sessions.
  - Gate: Linux runtime acceptance and a successful Windows cross-build suffice for Windows
    (user decision, 2026-10-03); browser acceptance still includes actual browser execution.
- [x] **S1 — Standalone builds and tests** — Depends: none.
  - Gate, repeated at each phase: clean checkout builds and tests without game files, research
    tools or sibling repositories; no proprietary content enters version control.
  - 2026-10-09 at `b6f3350`: a fresh clone in /tmp with empty Zig caches passes `zig build
    test` and builds the SDL, agent and extractor programs; no game file types are tracked.
