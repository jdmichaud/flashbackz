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
- [ ] Recover floppy music/effects sequencing and integrate AdLib plus PCM. Gate: exact event
  timing and sound comparisons against the pinned original execution profile.
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
