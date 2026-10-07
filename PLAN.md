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
- [ ] Import Flashback MIDI/PRF/INS music into named parts, instruments and scheduled events;
  verify malformed inputs, profile bindings, loops and note adjustments without game fixtures.
- [ ] Compare the music driver's timed register output against the original, then connect
  startup/menu sound to the existing chip and native PCM queue. Preserve scene stop/skip order.
- [ ] **Latest user priority: finish the casings, then complete gameplay sound throughout.**
  Include forest ambience, movement, switches, weapons and every other original effect; bind
  cues to original animation/interaction timing through one shared sound system. Do not stop
  at gunfire. Keep missing world behavior and full movement coverage explicitly tracked.
- [ ] Recover floppy music/effects sequencing and integrate AdLib plus PCM. Gate: exact event
  timing and sound comparisons against the pinned original execution profile.
- [x] Import compact LEV/BNQ/SGD room descriptions directly into owned artwork for gameplay.
  Gate: all decoded room pixels and palette selectors match the original installer’s five
  MAP outputs. Preserve compact content boundaries; reproducing the installer’s compression
  choices is unnecessary for runtime artwork.
- [ ] Restore the jungle holocube as an animated world item: contact indication, pickup,
  inventory transfer and recording playback, with explicit scene pause/resume. Gate: original
  floppy observations agree on object visibility, action/transfer order and cinematic selection;
  native input can collect and use the item from direct disk images.
- [ ] **Conrad movement pass: complete before further world mechanisms.**
  Cover walk/run blends and reversals, running jumps and edge departures, jump landings and
  catches, crouch/roll chaining, ledge movement, falls/recovery, room handoffs and input
  combinations; include locomotion with the weapon drawn. Gate: original floppy comparisons
  cover each transition, and native exploration no longer terminates on valid movement input.
- [x] Persist master volume across application restarts. Load before startup audio and save
  applied changes through the shared storage interface; check a native close/relaunch.
- [ ] Game Options: pause/resume, original settings and abort flow, host free memory in MB,
  plus user-requested master volume (0–100%). Gate: native menu input, pause behavior and
  both music/effect output levels are verified; original-only settings retain measured semantics.
- [x] Extend the existing native development scene shortcut to named levels so later-level
  mechanisms can be checked in the actual executable without remapping original assets.
- [ ] Original DEMO playback through the shared gameplay simulation: recover recording selection,
  initial state, input cadence, interruption and completion. Use the three original recordings
  as regression drivers; report divergences and resolve missing features through shared,
  data-imported systems, never recording-specific behavior.
- [ ] Shared collectible pickup, credit grants to the existing purse, and throwable stones,
  imported by behavior family. Loose credit pickups also participate in enemy distraction. Use the
  original demo to expose the next missing interaction; validate increments with quick native
  play checks, per the user's iteration preference.
- [ ] Preserve the original leftward visibility continuation after a nonmatching contact.
  Recover the observable contact ordering and redirects, isolate compatibility metadata at
  import, and keep original addresses and mutable RAM layouts out of the game state model.
- [x] Activate the carried force field through normal inventory use. Recover its deployment,
  animation, lifetime, repeat-use and projectile-blocking behavior from the supplied original;
  implement a shared equipment capability and qualify with a focused native encounter.
- [x] Audit every original placement, behavior family and static connection across all
  levels and difficulties against actual importer registrations. Keep optional, hidden and
  difficulty-excluded content visible; imported content is not automatically fidelity-qualified.
- [x] Fuse repair: recover the pickup, use predicate, receiver connection and completion
  movie/message; integrate it through shared collectibles and credential interactions.
- [x] Starting identity-card capability and employment registration: bind initial supplies
  through the same credential catalog as pickups; recover animated service counters and
  their linked work-permit grant. Preserve consumption, dialogue and movie/signal ordering.
- [ ] City bar and forger progression: recover the bartender's attention/dialogue family,
  signal-based civilian appearance, introductory handoff, payment and papers reward. Import
  shared content definitions and links; qualify normal-input conversations and transactions.
- [ ] City police and rescued civilians: import pursuit, evasive movement, shooting,
  damage/death signals, encounter-clearance relays and the Ian conversation/seat/recording
  sequence. Preserve family-wide rules and data links; qualify with original city input
  and focused native encounters, without per-placement scripting.
- [ ] Shared enemy families: import every matching placement, animation library and behavior
  profile from original data. Implement perception, stone distractions, locomotion, shooting
  and damage through independent actor/combat components; qualify with quick native encounters.
  Include the robots and ceiling laser guns as distinct behavior families (user reminder);
  gunman completion alone does not close enemy coverage.
- [ ] Import energy-generator fixtures and shared item recharge capabilities. Restore the
  shield through its authored use delay, healing value and recharge cinematic/music; reuse
  the capability for rechargeable puzzle items. Verify nearby and out-of-range use.
- [x] Rechargeable cartridge puzzle: pickup, charge completion after its film, credential
  matching, consumption, lock instruction and both linked bridge sections. Import the full
  behavior families and preserve their event order.
- [x] Item-aid NPCs and reactive quest items: import the wounded-man behavior family,
  teleporter delivery/acknowledgement, ID-card appearance/pickup and reusable card use.
  Preserve dialogue, perception, animation and same/next-update links through shared systems.
- [ ] Title-menu level codes: match the supplied edition’s codes, select their level and
  difficulty, play the appropriate entry sequence and let the user test all seven levels.
  Invalid codes return safely to the title; retry restarts the selected level.
- [x] Original temporary level-code display: import the level/difficulty codes and show
  the startup notice until its timer expires or a contact hint replaces it.
- [x] Trading NPC family and credit payment: original price checks, debit, sale dialogue,
  item grants, anti-G-belt films and linked visual effects. Preserve repeated-payment and
  insufficient-funds behavior; connect the belt-dependent exit through shared progression.
  Focused 560-update trade checks and native trade-to-city flow pass. Full arrival-film
  pixel/audio and inter-level timestamp qualification remain part of whole-game acceptance.
- [ ] Shared world-message display for item/control instructions and NPC dialogue, including
  original pages, colors, input and world pause/resume.
- [ ] Shared key/card pickups and credential locks: match original item codes at contact,
  consume successful uses, and route lock outputs through the normal door circuits.
  Preserve pickup movies, sounds and data-defined activation order.
- [ ] **Systematic mechanism import (user direction):** enumerate all level placements,
  shared rule groups and connections; classify behaviour families and translate them to typed
  definitions for shared switch/door/lift components. Gate: every instance is accounted for,
  known families are imported without per-object special cases, and unknown rule patterns are
  reported explicitly. Keep original instruction dispatch out of the modern runtime.
- [ ] Wire imported relay/pressure outputs to shared hazard consumers, preserving activation,
  event ordering, animation, sound and contact consequences. Qualify disintegration and the
  floppy Continue flow before exposing a hazard contact path that cannot return safely to play.
- [ ] Connect pressure-plate signals to independently modeled gate animation and terrain
  changes. Recover startup gate/platform footprints as behavior, not permanent level edits.
  Gate: original floppy object transitions, signal order and complete collision-grid changes
  agree through plate activation, collection, release and gate settling.
- [ ] Requalify gameplay imports and executable-backed metadata against this release before
  claiming that earlier movement, scene or inventory evidence applies.

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
