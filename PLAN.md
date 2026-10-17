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
    Space and Shift do not skip (Enter, Space and Shift still turn interactive pages). Escape
    skips again since 2026-10-09 (the user's decision, below). With the
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
  field; fuse repair; identity card and employment; interactive film pages (the city's map
  terminals were not covered; review B1 fixed them, 2026-10-10); mission terminals;
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
    original (its code entry leaves the keyboard to the BIOS); a P typed in a code had held
    the city's opening film on a black screen (fixed).
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

- [x] **Volume steps that sound even** (user report, 2026-10-10: "Even at 20% it's very loud.
  We should decrease the volume."). The VOLUME option scaled the samples linearly: 20% took only
  14 dB off, and the top half of the range hardly changed what is heard. Each step of 10% now
  takes 4 dB off: 100% plays as before, 50% is -20 dB, 20% is -32 dB, 0% is silent. The levels
  at 100% were measured first: music and effects peak at -12 dBFS. Gate: tests of the curve; the
  agent's audio at 100% is unchanged and at 20% is 32 dB down.
  - 2026-10-10: done. With the user: whether 100% is still too loud as a default.

## Code review, 2026-10-10 — `docs/review-2026-10-10.md`

The review the user asked for (2026-10-10), on commit `a9b6b26`. Each finding here is a
checkbox; fixing one adds its own plan item first, as usual. Order: B4 with D4 (the user asked
about the placeholder), B1, B2 with D2, B7, D1, then the rest. Common-sense calls (no user
decision needed): the MUSIC option controls the Mega Drive tunes (D2); content is checked at
load and fails loudly there, devices are adapted to (D6). Revised 2026-10-10: the animations stay
read from the original files, as DESIGN 2's diagram has them (D5): the engine reads past an
animation's last frame into the file's next bytes, so a data-set copy would carry that layout.

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
- [x] **B1** Using any of the city's four map terminals ends the game. High. The film importer
  takes the map's shape: a confirmation ends the film between its pictures, else it goes on. A
  loop's last picture shows until the loop presents its first again, for the waits and presents
  the loop back passes, not for the time after a confirmation. Importing every film at load is
  D6's. Gate: unit tests for each page-loop shape and a loop's timing; with Conrad at a map
  terminal, the agent plays the map until a confirmation ends it, then play goes on; every film
  the data set names imports; the keyboard sessions keep their hashes.
  - 2026-10-10: done. A frame carries `confirm_ends` and a loop's last picture `loop_ticks`. The
    map now blinks 4 ticks on, 4 off (its marker-off picture showed one host frame in four);
    the log's loop (LOG 0) takes 12 ticks, not 8; MISSIONS 5's is unchanged. All films import;
    the map plays until a confirmation, then Conrad walks on. 28/28 build steps.
- [x] **Agent sessions in the repository.** The scripted agent sessions that show a change keeps
  play as it was lived only in /tmp; they move to `tools/agent_sessions.sh`, with the accepted
  output beside it. Four sessions that LOAD GAME on the title or B choosing on menus changed
  under them reach what their comments name again, and the agent reports the title's page.
  Gate: the script's output reproduces; each session ends where its comment says.
  - 2026-10-10: done; 23 sessions. The menu sessions now start an expert game, open LOAD GAME
    and the code page; B on ABORT GAME abandons, as A does.
- [x] **Agent traces in the repository.** The per-walk traces of a long session on each level,
  which showed D1, D5, D7, R1 and R2 change no play, move from /tmp to
  `tools/agent_traces.sh`, with the accepted output (a hash per level) beside it. Gate: its
  output equals the baseline taken after D1.
- [x] **B2 and D2 — One audio output.** B2: an audio device granting another format ends the
  game or overruns a buffer (high on Windows). D2: five owners of the device, no mixer. The game
  owns one output: it opens the device once for 44,100 Hz stereo, which the host converts (SDL
  may no longer change the format), and mixes the sources of the moment (the title's, a film's or
  the ending's music; a level's effects and Mega Drive tunes) into one short queue. A source that
  stops takes its queue with it; a new music replaces what was queued. A device that fails
  leaves the game silent. The MUSIC option controls the Mega Drive tunes, SOUND FX the effects.
  The contract says that opening closes a device already open. Gate: tests (the output opens at
  the first sound, keeps its lead, cuts a stopped source, goes on silent without a device; MUSIC
  and SOUND FX start and stop the tunes and the effects); the agent's queued audio is the build
  before's for the title, the startup, films and levels, but for the queue's timing at scene
  changes; the SDL game plays sound.
  - 2026-10-10: done; 263 tests. The title and startup audio are identical; films and levels
    identical but for one or two frames of queue timing at scene changes. The level's sound
    still starts at its first effect, which keeps the effects' block phase. SDL's disk driver
    wrote 6 s of the branding music. Not run on a 5.1 or mono Windows device.
- [x] **B3** A key released in the options dialog or the inventory is ignored when pressed again.
  Fixed by GS-1.
- [x] **B4** Missing or partial game files start the template's placeholder game instead of
  failing. With D4. Done: "No placeholder game" above.
- [x] **B5** A catch-up frame drops the first walk's world message and its zoom hits (if the
  original keeps them). It does: the original clears its message only once shown, and a catch-up
  walk re-runs only the walk before the frame's one draw (flashback-re engine-update 1, steps
  11 and 13); the hit counters are presentation state. A catch-up walk keeps both. Gate: a
  world test, failing before; the keyboard sessions keep their hashes.
  - 2026-10-10: done; 268 tests.
- [x] **B6** Escape in a level reacts to auto-repeat and a quick tap is lost. Kept: the original
  polls Escape the same way (GS-1).
- [x] **B7** The data-set loader accepts data the engine cannot run. It refuses, saying why: more
  than 256 characters (the original's table, now one named limit), a first character that is
  not the player, an unknown or misspelt character field, a flag that is not true or false, a
  footprint wider than 16 columns, a number (argument, placement number, position, a rule's
  movement) beyond 4,096 either way (the data stays within -146 and 240) and a chance below 1,
  and a credit with no text. A level checks at load that its states' animations are in its
  files and that the font has its messages' and labels' characters; the ending, that it has a
  film and the font its credits. Gate: a unit test per refusal; every level and the ending load
  with the real data; the keyboard sessions keep their hashes.
  - 2026-10-10: done; 265 tests. All seven levels and the ending (12 films) load. The films'
    import at load and the whole data set checked at startup are D6's.
- [x] **B8** The agent without `--saves` uses and creates the user's real save directory. It
  saves in memory unless `--saves` is given. Gate: without `--saves` the agent creates no save
  directory, and a settings record in the user's directory changes nothing.
  - 2026-10-10: done.
- [x] **B9** Command-line options silently ignored, and standalone `--extract`. `--megadrive`
  and `--data` without disks already stop with the missing-files message (B4). `--extract`
  reads the built-in disks of the standalone build, says that it needs the disks otherwise, and
  names the data set directory or the names file it cannot open. Gate: each case by hand.
  - 2026-10-10: done; the standalone build's extraction equals the agent's from the disks.
- [x] **B10** Sprite decode errors are swallowed. Only absences are tolerated: a sprite or an
  art bank that none of the level's files holds (the tower's 48 composed sprites) is left out,
  and its count logged; a file that does not decode fails the load. Unused animation entries
  stay skipped (each level has a few invalid ones; B7 checks the states'). Gate: every level
  loads; a truncated PERSO.SPR fails; the keyboard sessions keep their hashes.
  - 2026-10-10: done.
- [x] **B11** The continue screen ends the game when 128 key events are queued. A full queue
  applies its oldest event early instead: the screen polls held keys, so the order and the final
  state stay. Gate: a test of a 401-event burst; the keyboard sessions keep their hashes.
  - 2026-10-10: done; 269 tests.
- [x] **B12** The Mega Drive cartridge reader is not overflow-safe; its checksum check can be
  bypassed. The game checks the cartridge however the files give it, the reader widens its
  addresses and refuses a tune without rows. Gate: an all-0xFF cartridge is refused in a Debug
  test; a bogus MEGADRIVE.MD in an asset directory is refused, the real one plays.
  - 2026-10-10: done; 270 tests.
- [x] **B13** The extractor's robustness on an unexpected edition. A placement's start state
  that no rule names becomes a waiting state, reported; the parameter check cannot overflow; a
  truncated credits stream and an icon file shorter than its count are errors; the report's
  notes on data not understood (unknown operations, unexpected arguments, those start states)
  are logged when the game extracts at startup. Gate: tests; the real extraction is unchanged.
  - 2026-10-10: done; 272 tests.
- [x] **B14** Smaller confirmed defects (the review's list). Fixed: the ending's state hash
  (every scene now has one, by construction); a `--stall` beyond an hour is refused and the
  agent's audio clock cannot overflow; a closed stderr no longer stops the SDL game; the SDL
  backend's overflow queue, which could drop a key-up and could no longer fill, is gone; a
  music profile's limit at either end of its range. Kept, as the original does: the opening
  film plays again on Retry without a checkpoint (the level load sets its request and the
  restart block keeps it, flashback-re engine-update 1.1); letters to a character deactivated
  before it runs stay allocated (engine-update, message delivery). Kept, two formats: MBK and
  BNQ mark raw banks differently, each as its original routine reads it; both decoders now say
  so. Gate: the keyboard sessions keep their hashes; each fix checked by hand.
  - 2026-10-10: done.
- [x] **D1** The engine models the original's memory layout in places. Decided (user,
  2026-10-10: "My rules was that we produce a modern maintainable code base. Make things
  coherent, easy to read and modify. Use your common sense."): each quirk becomes a named game
  rule where it holds; what truly depends on how the original laid out its data stays exact in
  one small, explained module. The four places (reads past the grid and the terrain writers'
  addresses, the leftward sight scan's placement records, wake list and mailboxes, the boarding
  test on a record's address) move unchanged into `behavior/original_memory.zig`; DESIGN 3 and
  PLAN 00 record the exception. Gate: tests; per-walk traces of long sessions on all seven
  levels identical before and after; the keyboard sessions keep their hashes.
  - 2026-10-10: done; 267 tests; 7,783 walks traced identical. The quirks that are arithmetic,
    not layout (a tier's zero-extended row, a span's y read as unsigned), stay as named rules
    where they apply.
- [x] **D2** One audio device, five owners, no mixer. With B2: "One audio output" above.
- [x] **D3** Input state updated in one path only; settings in hand-synchronised copies. Fixed by
  GS-1 and GS-2.
- [x] **D4** The template's placeholder (the bouncing ball) and unused template code are still in
  the product. With B4. Done: "No placeholder game" above.
- [x] **D5** Module boundaries leak in both directions. The animation reader moves from the
  engine to `content/` (the animations stay read from the original files, see above); the
  extractor-only parsers (placements, rule tables, string tables, world messages) move to
  `src/extract`; `content/` stops importing the engine, the scenes and audio (the level pack
  keeps the decoded collision bytes, the menus' artwork adapters go to their scenes, the score
  type to `content/`); `World` gets a hand-off API (`handOver`, `restartFrom`,
  `continueAfterDefeat`, `redrawView`). Gate: tests; per-walk traces of all seven levels and
  the keyboard sessions unchanged.
  - 2026-10-10: done; 272 tests.
- [x] **D6** Every runtime error is fatal, and validation is deferred to first use. As decided,
  content fails loudly at load and devices are adapted to. Done earlier: the level's data,
  animations and glyphs at level load and the ending's at its start (B7), the audio device (B2),
  the continue screen's queue (B11). Now the game imports every film the scenes name when it
  starts, so a film it cannot play stops it there, named. Each level's data stays checked when
  the level loads: parsing all seven at startup took a second in Debug. An error left during play
  is a bug and still ends the game. Gate: a data set naming a missing film stops the game at
  startup; startup costs 0.2 s more in Debug, 30 ms in ReleaseFast; the sessions keep their
  hashes.
  - 2026-10-10: done.
- [x] **D7** Smaller design issues (the review's list). Films keep one clock (the player's
  cadence; `Playback` is the frame and the end). Without pkg-config only the SDL executables'
  build fails, so the agent builds. Contacts collect the characters meeting in a cell in a fixed
  buffer: an update no longer allocates. The five tier formulas are named once in `grid.zig`, with
  a test of where they differ; the three neighbour helpers become the grid's one; the two "waits
  for" scans share the hit-side match and say how they differ. Kept, as the original: Conrad is
  character 0 for some rules and the player kind for others (`World` says which; the loader
  checks character 0). Gate: tests; traces of all seven levels and the sessions unchanged; the
  agent builds without pkg-config and the game's build then fails, saying why.
  - 2026-10-10: done; 274 tests.
- [x] **R1** Unnamed numbers. The timer's rate and tick, and the VGA's frame, are named once in
  `step_clock.zig`, whose `jungle` cadence becomes `level`; kinds compare by name through
  `Kind.matches` (the low byte, as the original), with kind 11 named `overlay` and the unnamed
  kinds 5, 9 and 12 explained; the fall scene, the protection after a hit and `Room.nowhere` are
  named; the instrument file's fields, the profile's timing fields and the executable's data
  segment are named. Gate: audio, traces and sessions unchanged.
- [x] **R2** Behavior tables' readability: state names, signs of the terrain arguments. The eight
  terrain checks that took the original's backward offset (`ledge_above_*`, `floor_edge_*`,
  `grab_edge_ahead`, `wall_beyond_gap`, `wall_starts`, `wall_ends`) now take cells ahead, like
  the others: the extractor writes them negated and the engine reads them so. The extraction
  report counts the states the overlay names (56 of 4,555); naming more is overlay work, not
  code. Gate: traces of all seven levels and the sessions unchanged.
- [x] **R3** Dead code: the title's unused notice page, `Player.interactive`,
  `Screen.writeRgba`, `contacts.Registration`, the unreachable Retry to the title, and
  `unused_parameters` (accepted, no longer kept). `placement` stays, documented: it is the
  character's identity when comparing with the original. Gate: as R1.
- [x] **R4** Tests missing, and tests that don't test their name. Added: `World.update`'s first
  tests (a message reaches a later recipient in the same update and an earlier one in the next,
  an awaited message ends the animation; a catch-up walk keeps the message, B5), the interactive
  pages (B1), the output and the options' sounds (B2). Fixed: the string table's alias test
  reads the alias; the startup test's name says what it checks; the OPL reference test embeds
  its data instead of reading it from the working directory. Kept elsewhere: scene transitions
  need the original's files, which tests may not have; `tools/agent_sessions.sh` covers them
  against the user's disks. The YM2612 differential test needs a hook in the vendored sorz code
  (DESIGN 6 keeps it unaltered): it belongs in sorz. The MBK raw-bank test asserts the format
  the original's loader reads (B14). Gate: tests.
- [x] **R5** Style: no inline `@import` (vendored sorz code excepted), `presence.zig`'s imports
  at the top, one meaning per alias (`score`, `music_player`), the film's duration named as such
  in `Game`. Gate: as R1.
- [x] **P1** The documented build is Debug. Kept (user, 2026-10-10: "Default build is debug."):
  the default build stays Debug, and `--release` keeps Zig's own default.
- [x] **P2** Audio latency. SDL's period halves to 512 frames (11.6 ms) and the queue's lead
  drops from 50 to 35 ms (a period, a 60 Hz frame and a margin): a sound is heard within about
  47 ms, not 73 (the original: about 12). The trade-off is now explained in
  `audio/output.zig`. Gate: tests; in a Debug build with SDL's real-time disk driver, the
  queue never runs dry during the title's music and films (11.5 s) nor the city's opening film
  (15 s).
- [x] **P3** Minor waste. Fixed: a frame converts its colors through a 256-entry table; a level
  frame with nothing drawn over its picture no longer copies it; a level reads its icons once
  and decodes its first room once; the ending draws its pictures without a throwaway RGBA frame
  (and its 229 KB stack buffers). Kept: the per-pixel foreground flags (3.6 MB a level, the
  simplest for the drawing loop), the executable unpacked at each use (about 1 ms, at a screen
  change), the input queues popping from the front (a few events a frame), the font decoded
  for the inventory as well (3 KB). Gate: tests; the sessions' frame hashes and the traces
  unchanged.
- [x] **Documentation**: the wrong or stale claims of the review's section 5, in DESIGN.md,
  README.md, docs and code comments. The user granted (2026-10-10) correcting DESIGN.md's
  statements of fact so they describe what exists; changes to its rules still need approval.
  Done: DESIGN's facts (the Windows cross-build, characters by index, synchronous reads,
  what fails loudly and where, the vocabulary's real syntax, the catch-up walk's exception),
  `docs/process.md` (no addresses in comments, as AGENTS.md says), the build's and README's
  claims (the accepted cartridge, the standalone build's condition, typos; the build lines are
  the user's), and the code comments listed. The file name rules become as portable as they
  claim (no Windows device names, no trailing dot). Kept: the vendored sorz files' comments,
  unaltered as DESIGN 6 wants; AGENTS.md's `signal(gunman)` example is the user's text.
  Gate: tests; the sessions unchanged.

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

## Source documentation — user request, 2026-10-17

- [x] **DOC-1 — Comments at the hinges and in the hard code** (user, 2026-10-17: "document the
  source code better", "the main nexus of the code, where things get hinged together", "the code
  that is hard to grasp", "Use Simplified Technical English"). Find the places where the parts
  join (hosts, game, scenes, world) and the code that is hardest to follow. Add short comments
  there in Simplified Technical English (ASD-STE100). Comments only: the code does not change.
  Gate: zigfmt clean; tests pass; the agent sessions and traces unchanged.
  - 2026-10-17, `87f2a55`..`667b7de`: 74 files. The hinges: the module map (shared/root.zig),
    `Game` (update steps, scene changes, event order, load), the hosts' loops, the providers,
    the level scene's play frame, the world's update order, the audio output. The hard code:
    the clocks and cadences, the draw order, the sight scans and contacts, the music player,
    the file formats (rooms, sprites, films, archives, rule records). Wrong or stale comments
    fixed on the way. With comments removed, every file equals its earlier version; zigfmt
    clean; 276/276 tests; smoke and verify; the agent sessions and traces unchanged.
  - Found while documenting, not fixed (code, outside DOC-1; each needs its own item):
    - The SDL version report: build.zig's warning says the pin is checked at run time, but
      nothing compares it; the host prints the recorded release as "pinned";
      `VersionCheck.matches` and `pinned_zig_version` are unused.
    - The SDL backend drops key events until the first focus-gained event.
    - `World.skipToAwaitedRule` compares unsigned where the original compares signed bytes
      (animations of 128 frames or more), and its count cast panics above 255 frames.
    - `Contacts.cellKey`: an x below about -264 gives a negative column that passes the bound
      test; the cast then panics in a Debug build.
    - `original_memory.recordByte`: byte 17 of a record is reachable but not modeled.
    - `save.fingerprint` hashes only the first 1024 files, in load order, before the sort.
    - A stored zoom ON never applies at level start, and the options dialog then shows OFF.
    - A pad's B (GUN) on ABORT GAME abandons the game; only START is kept from it.
    - `library_colors` relies on `SpriteLibrary` matching the executable's library order,
      unchecked.
    - The music player's bend also writes to drum voices (ignored registers, and key-on bits
      on channels 7 and 8); not checked against the original.
- [x] **DOC-2 — A specification for each file format** (user, 2026-10-17: "For each different
  format we need a technical specification document written in STE"). One document for each
  format that the game, the extractor or the atlas reads or writes, in `docs/formats/`, with
  an index: the original's files (disk images, archives, rooms, sprites, films, sound, the
  executable's tables) and ours (the data set, the naming overlay, saves, settings, the logs).
  Files that only work together (SPR and OFF) share one document. Docs only: the code does not
  change. No original content: no bytes, texts or level codes from the files; synthetic
  examples only. Gate: every fact checked against the code that reads or writes the format;
  the index lists every file that the code opens.
  - 2026-10-17, `6f27a57`: 36 documents and the index. Each one checked twice against its
    reader and writer (a writer, then another agent), every change reviewed against the code.
    FB.EXE unpacked by `executable.md` alone gives the documented sizes. A count of the
    executable's codes, labels, messages and credits in the documents finds none; it found a
    level code in an old PLAN note (removed, `bfbb2a3`; commit `e3ff092`'s message still holds
    it). Links, anchors, line widths and modal verbs checked by script. `DESIGN.md` facts fixed
    (`a27cadb`).
  - Found while specifying, not fixed (code; each needs its own item):
    - Panics: `flashbackz-agent --save F:SLOT` with a slot of 12 characters or more (the `.INFO`
      name buffer, reproduced; the record stays without its INFO); a settings record with 8 pad
      models and long button names (2,149 bytes for a 2,048-byte buffer); a data-set start room
      of 64 or more (`level_pack` indexes 64 rooms); a frame dx of -128 on a character that
      faces right (`playFrame`, `skipToAwaitedRule` negate an `i8`; no such frame in the files).
    - `save.restoreWorld` and `restoreTerrain` check the lengths of lists, not their values: an
      edited save can index out of range.
    - The music player does not limit the block to 3 bits: a pitch of 96 or more sets key-on in
      0xb0, so the release does not stop the note. Not checked against the original.
    - The extractor: `labelOf` turns every label error into an empty label without a note; an
      operation that takes its kind from the first condition gets kind 0 in another slot,
      without a note; behavior file names can collide (the second overwrites the first);
      `names.parse` does not refuse duplicate keys, link or number names; an overlay name for
      message 1-4 or 12 would break the hits or `acknowledged`.
    - The data-set reader ignores unknown fields in behavior roots, states and struct
      arguments, but refuses them elsewhere; it loads `.zon` files at any depth under
      `behaviors/`, and two with one file name bind characters to the first.
    - The hosts: a missing `--names` file shows "extraction failed: FileNotFound", not the
      prepared message; a failed in-memory extraction is logged at info level, which release
      builds hide.
    - The agent: `--trace` writes at most one line a host frame, not one a walk as its help
      says; a failed `--load` resets the walk count; trace lines do not escape SLOT; the level
      `stateHash` uses the machine's byte order, the other scenes little-endian.
    - The tools: `agent_sessions.sh` takes the hashes from the first line of the merged output,
      so a log line empties them; `agent_traces.sh` uses `set -e` without `pipefail`.
    - Wrong comments or names: scene 75 has no film (`floppy_interface.zig`); archives accept
      gaps between files (`archive.zig`); band 254 is y -107 to -36 (`grid.zig`); a failed
      settings write retries at each update (`game.zig` `keepSettings`); demos skip the
      opening scene only with a start position (`level.zig` `loadWithStart`; no effect with
      the supplied data); `Screen.init`'s `demo` receives `start != null`; the ending's error
      names scene 61 but fails only when no ending scene has a film.
    - `ending.zig` writes the code notice's prefix as a literal; `level_pack` reads it from
      FB.EXE.
    - Unreachable or unchecked: `DirectoryTooDeep` (`floppy.zig`); the eighth level code has no
      0-byte check; `floppy_rooms.decode` calls a room past 63 `InvalidRoomDirectory`.
    - `character_art` decodes only the frames inside each animation, but `showFrame` can show
      the frame after the last one: drawn as nothing if no animation decodes its sprite. Not
      checked against the original data.
    - `music.zig`: register 0xc0 tests the whole connection word, the volume only its low byte;
      the feedback is not masked to 3 bits. No effect with the supplied files.
  - flashback-re documents that the code contradicts (for that repository's plan):
    `sprite-port-map.md` (raw records), `rule-vocabulary.md` (names of codes 68 and 135,
    arguments of six operations, `strike`'s second hit, codes 72 and 95 always true, carrier
    248), `rules/engine-level.md` 1.4 (bit 2 of byte 0x15), `animation-port-map.md` (pose byte),
    `rules/engine-update.md` 3 (a byte, not a word), `falls-and-continue.md` (the SCORE
    decoder), `reference-environment.md` (three archives), `gameplay-sound.md` (35 ms queue),
    `floppy-demo.md` (the opening scene).

## Fixes from the format specifications — user request, 2026-10-17

The user, on DOC-2's list: "Fix the bug, update the docs, strengthen the scripts." Each item
keeps play unchanged unless it says so: the gate of each is `zig build test`, smoke and verify,
zigfmt clean, and `tools/agent_sessions.txt` and `tools/agent_traces.txt` reproduced.

- [x] **FX-1 — No crash on unusual input.** A slot name of any length (`--save`), a settings
  record of 8 pads with long button names, a start room of 64 or more, a frame dx of -128: each
  is refused with an error or handled, never a panic. A test for each.
  - 2026-10-17, `0937521`..`0e6ed02`: the four, plus two of DOC-1's list (`skipToAwaitedRule`'s
    unsigned loop and its cast; `Contacts.cellKey`'s negative column). A test for each; the
    contacts case fails without its fix. The agent with a 60-character slot reports InvalidName
    and writes nothing. Tests 279/279, smoke and verify, sessions and traces unchanged.
- [x] **FX-2 — Bad data is refused, not let through.** The save reader checks the values it
  restores, not only the lengths. The extractor notes a label error and a missing kind, and
  refuses two behaviors with one file name; the naming overlay refuses duplicate keys, link and
  number names, and names for the engine's fixed messages. The data-set reader refuses unknown
  fields everywhere and reads only the files directly in `behaviors/`. The data-set fingerprint
  does not depend on the order of the listing.
  - 2026-10-17, `c0715e5` (settings), `c118f47`, `85beec8`, `a04a6d7`: each refusal has a test;
    a save made by the previous build loads (same fingerprint); every level loads from a data
    set extracted to disk. Tests 283/283, smoke and verify, sessions and traces unchanged.
- [ ] **FX-3 — The hosts and the agent say what happens.** A missing `--names` file and a failed
  extraction show their reason in every build. `--trace` keeps its help true, a failed `--load`
  leaves the walk count, trace lines escape the slot name, and the level's state hash has one
  byte order on every machine.
- [ ] **FX-4 — The scripts fail loudly.** `agent_sessions.sh` and `agent_traces.sh` read the
  agent's standard output and standard error apart, check its exit status, and stop with a
  message when a run fails, rather than print empty or partial hashes.
- [ ] **FX-5 — True comments and names, no dead code.** The wrong comments listed under DOC-2,
  the ending's code notice read from FB.EXE, the eighth level code checked like the others, no
  unreachable error, error names that match their condition.
- [ ] **FX-6 — The fidelity questions, measured before any change.** The music block above 3
  bits, register 0xc0's connection and feedback bits, and the frame after an animation's last
  frame in `showFrame`: find what the original does and what the supplied files reach. Change
  the code only with that evidence; otherwise the format documents state the limit.
- [ ] **DOC-3 — The documents follow.** `docs/formats/` follows FX-1 to FX-6; the flashback-re
  documents that the code contradicts are corrected there, under that repository's own plan.

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
  - 2026-10-10 (review D1): the engine still reproduced the original's memory in four places
    where play depends on it. They live in `behavior/original_memory.zig` only, the exception
    the user decided; DESIGN 3 records it.

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
