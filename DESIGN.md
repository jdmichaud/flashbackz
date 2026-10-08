# Flashbackz design

Initial design, 2026-10-03; revised 2026-10-08 with the user's approval: character behavior and
level content are data (sections 3, 4 and 7). This is an independently organized game, verified against the supplied
Flashback DOS floppy edition. The implementation goal authorizes this initial design. Changes to the
established contracts require the user's approval; measured content and port maps evolve with
the research. Unknown original behavior is not replaced by guessed rules.

## 1. Requirements

Faithful observable behavior and maintainable architecture are separate acceptance criteria.
On 2026-10-04 the user permitted small pixel differences when exact matching would create
excessive complexity. Keep general rendering algorithms and record any accepted differences;
do not add frame-specific pixel repairs.
Original code-wheel/copy protection is excluded by explicit user instruction (2026-10-04).
The modern Start flow proceeds directly to the game opening sequence without that prompt.
Movement, animation, collisions, combat, inventory, enemies, puzzles, room transitions, menus,
cinematics, drawing and audio must match the reference. A faithful translation of the original
program does not satisfy the architecture requirement.

The user authorized the floppy edition pivot on 2026-10-04. The complete English reference is
`disk1.img`, SHA-256 `3ff964a76e90f3c25489334db38bde021d0c7632f7fa2b90ba234312c1d1272f`,
and `disk2.img`, SHA-256 `ed9b9a5bef0b42d5c394d9b715f27b42edc388d17f243b12ae52f9d3c2e0f9b2`.
Disk 1 is identical to the initial, now-removed `Flashback.ima`. Research lives in `flashback-re`.
There is no mandatory remaster and no runtime dependency on an emulator, decompiler, original
executable's instructions, research tool or sibling repository.

Linux/SDL and the deterministic headless host share the same game. Windows/SDL remains a
future target. Browser/WebAssembly support is excluded by user instruction (2026-10-04).
The user accepts Linux runtime verification plus a Windows cross-build for Windows. Windows
compilation is deferred until Linux gameplay is working (user priority, 2026-10-04); portable
host boundaries remain required. Network play is excluded. Audio acceptance is AdLib FM
plus the game's digital samples; MT-32 device ROMs are not required.

## 2. Ownership and boundaries

```text
SDL / agent host
    Platform: input, monotonic time, presentation, PCM, lifecycle
    AssetSource: bounded read-only content access
    Storage: atomic named records
        |
Application: scene lifecycle, scheduling, loading, persistence
        |
Session: World + PlayerProgress + deterministic Commands / Events
        |
Movement / collision / interactions / combat / behaviors / room flow
        |
immutable ContentPack: rooms, actor definitions, motion, rules, art, text, sound
        |
Renderer -> indexed frame -> RGBA; Audio -> scheduled voices -> PCM
```

Each application is a value with its own allocator, providers, scene state, session, renderer and
audio. No mutable global state and no borrowed provider buffer survives its documented call.
Content objects own their decoded storage and outlive sessions that use them. Actor references
are stable handles with generations, never pointers into movable arrays or original RAM offsets.

Simulation systems receive explicit state and commands, produce ordered events, and do not call
the platform, open files or wait for sound. The application coordinates I/O at update boundaries.
Long asset and movie reads become bounded jobs with explicit cancellation and completion order.

The platform contracts and native/provider skeleton come from `game-port-template`: context plus
function table, borrowed completed RGBA8 frames, copied bounded PCM queues, validated logical
asset names, explicit allocation ownership, and atomic storage replacement. Hosts own the outer
loop and cleanup. The agent supplies a virtual clock and never links SDL.

## 3. Original files, extraction and the data set

Revised 2026-10-08 with the user's approval: behavior and level content become readable data.

Two kinds of original content are used, in two different ways:

- **Images and sound** are always read from the user's original files at runtime: room art,
  sprites, palettes, cinematics, music and samples. They are decoded into owned assets and
  never written out or committed.
- **Everything else** (placements, behavior rules, links between characters, timings, text)
  is converted once by the **extractor** into a readable **data set** stored outside Git, in a
  directory the user chooses. The game loads only the data set plus the original images and
  sound. The extractor is the only code that understands the original's placement and rule
  formats; addresses and record layouts never leave it.

```text
disk images --extractor--> data set (outside Git)  --+
                          committed overlays (ours) --+--> ContentPack --> World
disk images --------------------------------------------> art and sound decoders
```

The data set uses ZON (Zig object notation): human-readable, parsed by the standard library,
no new dependency. Per level it contains `characters.zon` (every placement: name, label, kind,
room, position, facing, behavior, links, numeric settings) and one `behaviors/<name>.zon`
table per behavior. `messages.zon` holds the world messages that `show_message` refers to. Names are ours. The extractor's vocabulary maps every original
condition and effect to a named, typed form. A committed naming overlay, keyed by the behavior's
structure, names behaviors and states (`frightened_civilian`, `aiming`). Unnamed states keep a
systematic name until someone names them. Overlays are committed ZON files in the same format.
They may rename, add or replace data, and must not contain original content.

Unsupported content fails loudly. The extractor reports every condition or effect it cannot
name, with level, character and state. The engine refuses a table that uses an unimplemented
condition or effect; it never substitutes a default.

## 4. Session and systems

`World` owns actors, room state and pending events. An actor has typed position, facing, health,
current motion/animation progress, timers, inventory/interaction references and a behavior
instance. Definitions are shared immutable content; per-session state belongs to the world.

Commands express player intent: directions, action, arm, use, inventory and pause. The input
interpreter owns key-held state, transitions, focus-loss release and action precedence. SDL key
symbols, DOS scancodes and host repeat events never become simulation state.

Systems have cohesive purposes: movement advances a motion; environment collision resolves
contacts; interactions identify and operate nearby items; combat applies hits and damage;
behaviors choose transitions and emit actions; room flow moves actors across named exits. Their
ordering is explicit and will be established from measured original outcomes. A fidelity test
can require one event before another without requiring the original's routine boundaries.

### Characters and behavior tables

Every acting character except Conrad follows a behavior table. Conrad keeps a Zig controller
for now; moving him to a table is a later decision.

- A **state** has a name and an animation, given as original frames, per-frame movement and
  sound cues.
- Each state lists its **transitions** in order. A transition has a list of checks (`when`), at
  most one effect (`then`), changes to the character (turn, damage, heal, score), a movement and
  a target state. Some original checks are actions that always succeed, such as `set_timer` or
  `send`. They stay in `when`, in order, because they run even when a later check fails.
- **Conditions and effects** form a fixed vocabulary implemented once in Zig. Each is a small
  named function with typed arguments, for example `sees(player, within_cells: 16)`,
  `chance(1, in: 20)`, `timer_expired`, `received(.hit_front)`, `signal(.ambush, .cover)` or
  `reveal(in_room: 19)`. Original quirks live inside the condition or effect that has them,
  documented there (for example, the sight scan's leftward continuation).
- **Links** connect a character to others. A behavior names its links (`cover`, `gunman`);
  each placement binds them to characters (`cover = papers_20`). Signals travel over links.
- **Messages** have names: engine-wide ones for fixed meanings (hits, talk, acknowledgement)
  and level-wide ones from the naming overlay. Unnamed messages keep a systematic name.

The evaluation order is part of the behavior and is stated explicitly:

1. Characters advance in authored order, which is the data set's order.
2. When a character's animation completes, it tries its current state's transitions in order.
   The first transition whose conditions all hold applies its effect and movement, enters its
   target state, and restarts that state's animation.
3. Conditions are evaluated left to right and stop at the first false one. Random draws
   therefore happen only where the original draws them.
4. A signal reaches its recipient immediately. A recipient later in the order reacts in the
   same update; an earlier one reacts in the next update. Conrad's shot is a character in that
   order. Every mailbox is emptied at the end of its owner's update.
5. A message that arrives during an animation is lost, unless the current state has a
   transition waiting for it. Then the animation's remaining movement applies at once and the
   transitions are tried in that update. No marker is needed; the engine derives this.

Research recorded this model from the executable (flashback-re `docs/rule-vocabulary.md`) and
confirms each part in running scenarios before the engine relies on it.

Player progress and checkpoints include the complete game state needed by the original's
restart/save behavior. Persistence semantics and the initial state remain unmeasured until their
research gates pass; the template's synthetic smoke save is not Flashback's save format.

## 5. Time and arithmetic

The scheduler separates simulation time, presentation time and audio sample time. The original's
logic rate, cinematic rate, timer units, pauses and loading waits are measured requirements,
not assumed to be the template host's 60 Hz. Updates perform bounded work; budgets may not
change event ordering or simulation results. The agent's virtual clock makes replay independent
of how long the test runner takes to think or execute.

Simulation uses integer arithmetic with explicit precision, overflow and rounding where they
affect observable outcomes. The imported motions and rules describe their measured units.
One owned random generator supplies named draws in a defined order; its algorithm and seeding
come from the original. The placeholder's RNG is only for platform smoke tests.

## 6. Presentation and audio

The renderer consumes room layers, animation frames, actor placements, UI text and palette
effects. It owns indexed pixels and palettes, then converts to an RGBA8 frame for the host.
It does not emulate VGA registers or route drawing through translated DOS calls. The observed
menu/game content is 256 by 224 pixels; movies have their own measured dimensions and pacing.

Audio sequencing and sample decoding are Flashback subsystems with measured priorities and
timing. A generic OPL2/OPL3 synthesizer may be reused from vpoolz after its code, tests and
attribution are reviewed. Virtual Pool's sequencer, driver, voice ownership and memory layout
are not reused. AdLib output and game PCM are mixed on a sample clock into bounded
interleaved samples; the host only plays them. Renderer refresh rate cannot set music tempo.

## 7. Extension examples and architecture gate

A new room adds a room definition, art/collision content, placements and named exits. Linking
the existing jungle room's right exit to it changes content; it does not add a new branch in the
collision engine, renderer, input interpreter or original-code dispatcher.

A new guard behavior is a new behavior table with named states (patrol, pursue, aim, recover),
using existing conditions (distance, sight, health, timers, received signals) and effects
(start motion, fire, signal). It needs no Zig change. A genuinely new mechanic adds one new
condition or effect to the vocabulary, with tests, rather than a new hand-coded component.
A table can be exercised in a synthetic room without original assets.

Implementation review checks that these additions remain local and understandable. Behavior
tables must read as game rules: named states, named conditions and effects with typed arguments,
and named links. A table that only renames original opcode numbers and argument slots fails
this gate, as does copied original control flow that merely passes pixel tests. If an exact behavior is a quirk, it is
documented as a named rule at the narrowest relevant boundary.

## 8. Evidence and delivery

Builders and tests use the repository alone, with synthetic format/content cases and committed
measurements carrying provenance. User content is supplied explicitly and never committed.
Original frame hashes, arithmetic outputs and semantic event traces are measurements; original
images, music, text, executable bytes and memory dumps are not test fixtures.

Observers live outside the engine and map original state to the game's vocabulary. Exact
comparisons name the first differing actor, event, field, tick, pixel or sample. No baseline is
regenerated to bless a change. Missing observations, errors and timeouts fail explicitly.
Interactive milestones require the SDL game with real events and presented frames; agent tests
are complementary. An incomplete subsystem is reported as incomplete, not hidden by a synthetic
renderer or a build-only gate.

The initial template program is explicitly a platform smoke placeholder. It establishes
compilation, host/provider contracts, deterministic headless execution and native SDL presentation;
it is replaced as measured Flashback content and systems arrive. The final acceptance is the
whole faithful, independently designed game, not this foundation or a single playable room.
