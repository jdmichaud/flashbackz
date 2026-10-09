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
- [ ] The title menu's pages frame for frame: the main menu with each item selected, Skill,
  Info and the password page while a code is typed, and their keys. Gate: the original's frames
  of each page (flashback-re capture) match flashbackz's.
- [x] The original's other keys (flashback-re engine-presentation 6.1, engine-music 9; key
  handlers 0x7b60-0x7c5c). P is a global toggle that only films read, so a P pressed during play
  holds the next film until P is pressed again; keypad + and - change the music volume one step
  per press (0..63 from 48, for notes started afterwards) for the session; S switches the sound
  effects on or off, as the options row does, during play only (not in films, the inventory,
  messages, the continue screen or the title); J turns the joystick option on at the next
  gameplay frame (not in a demo), K turns it off at once. The calibration dialog J shows for an
  analog joystick is left out: SDL controllers need none. Gate: agent runs.
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
  - All levels, difficulties, enemy and puzzle behaviors, menus, demos, cinematics, languages,
    sound modes, checkpoints/passwords and configuration.
  - Gate: exact behavior coverage is complete and the user can play the game through.
  - Audio acceptance uses AdLib FM plus game-supplied PCM; MT-32 emulation is not required
    (user decision, 2026-10-03). Reuse only generic chip code after review, with its tests and
    attribution; Flashback's audio engine is independently designed and verified.
- [ ] **05 — Target acceptance** — Depends: 04.
  - Status 2026-10-09: Linux builds and runs (SDL and agent hosts); Windows builds are deferred
    and browser support is excluded by the user (2026-10-04).
  - Linux, Windows and browser packaging, inputs, audio, storage, lifecycle and long sessions.
  - Gate: Linux runtime acceptance and a successful Windows cross-build suffice for Windows
    (user decision, 2026-10-03); browser acceptance still includes actual browser execution.
- [x] **S1 — Standalone builds and tests** — Depends: none.
  - Gate, repeated at each phase: clean checkout builds and tests without game files, research
    tools or sibling repositories; no proprietary content enters version control.
  - 2026-10-09 at `b6f3350`: a fresh clone in /tmp with empty Zig caches passes `zig build
    test` and builds the SDL, agent and extractor programs; no game file types are tracked.
