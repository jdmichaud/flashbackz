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
- [ ] Import both floppy images together through native command-line input; recover the
  installer's level expansion without a runtime dependency on DOS. Gate: all installed file
  bytes match the original installer's output, including all five generated level maps.
- [ ] Reproduce title, vector introduction and original scene order. Gate: exact original
  presented-frame comparisons, palette changes, timing and input behavior. Small documented
  pixel differences may be accepted to avoid excessive renderer complexity (user decision).
  - 2026-10-09, flashback-re `capture_cinematics.py` and `vector_cinematic_probe.zig`: LOGOS
    153/153 and INTRO1 260/260 presented frames match the original exactly, INTRO2 362/380
    (the rest differ on polygon edges, at most 33 pixels). Timing and input are not compared.
- [ ] Import Flashback MIDI/PRF/INS music into named parts, instruments and scheduled events;
  verify malformed inputs, profile bindings, loops and note adjustments without game fixtures.
- [ ] Compare the music driver's timed register output against the original, then connect
  startup/menu sound to the existing chip and native PCM queue. Preserve scene stop/skip order.
- [ ] **Latest user priority: finish the casings, then complete gameplay sound throughout.**
  Include forest ambience, movement, switches, weapons and every other original effect; bind
  cues to original animation/interaction timing through one shared sound system. Do not stop
  at gunfire. Keep missing world behavior and full movement coverage explicitly tracked.
  - Since 2026-10-09 casings are characters run from their tables, and every effect is the
    engine's sound request at the moment a rule fires (animation entry sounds and
    `play_sound`), mixed by the shared effects player. Every recorded request of the
    captures matches by update, id and attenuation (engine regression); the mixer's output
    timing is not compared yet.
- [ ] Recover floppy music/effects sequencing and integrate AdLib plus PCM. Gate: exact event
  timing and sound comparisons against the pinned original execution profile.
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
- [ ] Game Options: pause/resume, original settings and abort flow, host free memory in MB,
  plus user-requested master volume (0–100%). Gate: native menu input, pause behavior and
  both music/effect output levels are verified; original-only settings retain measured semantics.
  - The level scene opens it on Esc after the update's walk and abandons to the continue
    screen, as the original does.
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
- [ ] **Systematic gap detection (user concern, 2026-10-08):** replace reliance on manual play
  with a family-agnostic world comparison.
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
- [x] The ending: scene 61's film list under END31, the final score screen (scene 73) and the
  return to the title. Gate: compared with an original capture of the ending.
  - 2026-10-09, flashback-re `tools/compare_ending.py` (engine-ending-zoom 12.5): the credits
    follow the original's replay-mode rules and their state is exact at all 3,996 list presents
    given the original's hold values; with the modern cadence they stay within a few characters
    and end on the same step. 4,479 of 4,799 film presents and all 142 score frames match; the
    rest differ on film polygon edges (next item). The agent host plays the ending from the
    title's eighth code and returns to the title; the level route (scene 61) was not played.
- [ ] Film polygon edges: 320 of the ending's 4,799 presents and 18 of INTRO2's 380 frames differ
  from the original on polygon edges or one- and two-point shapes (at most 337 pixels; FIN,
  MEMO, ESPIONS, VOYAGE). Gate: the ending and introduction comparisons report every film
  frame identical, or each remaining difference is explained and accepted.
- [x] The zoom view option (flashback-re engine-presentation 4.3), including the automatic
  combat zoom. Gate: original frames with the option on.
  - flashback-re `docs/rules/engine-ending-zoom.md`; all 816 frames of four zoom captures match.
- [ ] Catch-up walks: when a frame is late the original repeats the walk without presenting.
  Decide with the user whether the modern cadence should reproduce it; record the decision.

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
- [ ] **02 — Content sources and compatibility parsers** — Depends: 01, research 06.
  - Read the user's original CD or extracted directory into named, validated content; keep
    source layout and legacy scripting semantics at the compatibility boundary.
  - Gate: synthetic malformed-input cases pass; decoders agree with independent original
    observations; game code consumes typed content rather than executable addresses.
- [x] **02a — Direct disc-image argument** — Depends: 01.
  - Both native hosts accept an ISO or supplied MODE1/2352 BIN image in the existing positional
    asset argument, reading files directly through the same asset contract as a directory.
  - Gate: synthetic image and malformed-input tests pass; all original files read from the
    image match the inventory, and Linux/Windows hosts build without extraction dependencies.
- [ ] **03 — Exact first playable room** — Depends: 02, research 05 and 07.
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
  - All levels, difficulties, enemy and puzzle behaviors, menus, demos, cinematics, languages,
    sound modes, checkpoints/passwords and configuration.
  - Gate: exact behavior coverage is complete and the user can play the game through.
  - Audio acceptance uses AdLib FM plus game-supplied PCM; MT-32 emulation is not required
    (user decision, 2026-10-03). Reuse only generic chip code after review, with its tests and
    attribution; Flashback's audio engine is independently designed and verified.
- [ ] **05 — Target acceptance** — Depends: 04.
  - Linux, Windows and browser packaging, inputs, audio, storage, lifecycle and long sessions.
  - Gate: Linux runtime acceptance and a successful Windows cross-build suffice for Windows
    (user decision, 2026-10-03); browser acceptance still includes actual browser execution.
- [ ] **S1 — Standalone builds and tests** — Depends: none.
  - Gate, repeated at each phase: clean checkout builds and tests without game files, research
    tools or sibling repositories; no proprietary content enters version control.
