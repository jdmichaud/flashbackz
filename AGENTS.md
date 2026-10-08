Purpose: reimplement Flashback DOS in modern, readable, extensible code with exact fidelity to
the supplied floppy edition. Research and tools live in the sibling flashback-re repository.

Rules:
- Read README.md and PLAN.md first. Follow game-port-template's platform contracts and process.
- Add missing items to PLAN.md in a separate commit before implementation; check only gates
  that actually pass. Make small commits on main; never push.
- The original's observable behavior is authoritative. Exactness is required from the start.
- Model rooms, actors, actions, animation, collision, inventory, puzzles, scenes and audio in
  game terms. Use typed state and explicit ownership. Keep the simulation independent of hosts.
- Design from a blank page (user direction, 2026-10-08): the game must be easy to understand,
  extensible and as simple as possible while staying faithful to the original. The original's
  code is evidence of behavior, not a template: never transplant decompiler output, addresses
  or routine structure, and never add complexity the design does not need.
- Character behavior is data (user decision, 2026-10-08). Every acting character follows a
  declarative rule table: named states, ordered transitions, named conditions and effects with
  typed arguments, and named links to other characters. The engine implements each condition
  and effect once and runs every table with the original's observable evaluation order. Do not
  hand-code a behavior family in Zig when it can be expressed as a table.
- An extractor turns the user's disks into a readable data set (characters, behavior tables,
  text, timings) stored outside Git. Images and sound are always read from the original files.
  Committed overlays may add or adjust data but never contain original content. Names in the
  data set are ours (states such as `aiming`, effects such as `signal(gunman)`), not opcodes.
- Original addresses, CPU registers, segment layouts and DOS services belong in research or
  compatibility parsers, never as the engine's state model. Semantic comparisons must not
  require a copy of the original's RAM layout.
- Preserve observable widths, wrapping, rounding, event order, timing and quirks explicitly.
  Modern organization is not permission to change behavior.
- Builds and tests must stand alone. No original game code, assets, screenshots or memory dumps
  may be committed. Reference behavior measurements with provenance and synthetic tests are
  permitted. The user supplies original content at runtime or during an explicit asset build.
- Linux/SDL, a deterministic headless agent host and eventual Windows/SDL are the targets. Use few dependencies and static linking where practical. Network play is excluded.
- Build and capture under /tmp/flashback, not the repository or zig-out; emulate a copy only.
- Verify the build the user runs with real input and presented frames before marking playable
  gates complete. For Windows, the user accepts Linux runtime checks plus a successful Windows
  cross-build (2026-10-03); an actual Windows machine is not an acceptance prerequisite.
- Review maintainability independently of fidelity tests. A faithful result that remains tied
  to the original code structure fails acceptance, even if every fidelity test passes.
- Once DESIGN.md is established, changes require explicit user approval. No design is approved
  merely by copying a template. Do not ask again for decisions already authorized in the session.

- Original code-wheel/copy protection is explicitly excluded by the user (2026-10-04).
  Do not port its prompts or checks; normal Start proceeds to the game opening sequence.

- Windows compilation is deferred until Linux gameplay is working (user priority, 2026-10-04).
  Focus validation on Linux while preserving portable boundaries and avoiding obvious Windows
  incompatibilities; do not run Windows cross-builds during this phase.

- The user permits small pixel differences when exact matching would add undue complexity
  (2026-10-04). Prefer readable, general rendering rules over frame-specific pixel fixes.
  Keep exact comparison reports and document accepted differences; never alter the reference
  or silently treat a broad visual mismatch as acceptable.

- Browser/WebAssembly support is excluded by the user (2026-10-04). Keep native SDL and
  headless hosts only. Reuse established vpoolz/template infrastructure and focus new work
  on Flashback-specific content, music sequencing and gameplay.

- REminiscence and other third-party Flashback reimplementations are forbidden as references
  (explicit user instruction, 2026-10-04). Recover Flashback-specific behavior from the supplied
  original executable and assets. Previously approved vpoolz/template infrastructure reuse
  remains allowed. Prior external leads are not authority for new implementation work.

- Current user priority (2026-10-04): implement all Conrad movement before further world
  mechanisms, so the user can explore the level. Keep naming each movement delivered and
  provide its exact controls for direct testing; distinguish ready moves from remaining work.

- Latest user priority (2026-10-04): after finishing ejected casings, implement all gameplay
  sound, including forest ambience, movement, switches, weapons and other effects. Use shared
  animation/interaction sound events; do not limit this work to gunfire. The movement and
  whole-game goals remain open, and missing sound-producing world behavior must stay visible.

- Mechanisms must be handled systematically from original data (user clarification). Discover
  instances, behaviour families and links across levels through the extracted behavior tables.
  Do not hand-code each switch or door. Reference scenarios qualify conditions, effects and
  tables, not individual hard-coded IDs.

- Latest user workflow preference: keep iteration fast. Launch the game and test the feature
  directly, then move on when it works. Do not run broad regressions or lengthy qualification
  for each increment. Investigate observed failures as needed; the original remains authority.

- User-authorized durable reference exception (2026-10-07): keep the installed English
  floppy game and qualified observer under `~/flashback-reference/`, outside Git. Treat
  that installation as read-only; disposable runs, captures and build caches stay in /tmp.
