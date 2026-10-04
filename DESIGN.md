# Flashbackz design

Initial design, 2026-10-03. This is an independently organized game, verified against the supplied
Flashback DOS floppy edition. The implementation goal authorizes this initial design. Changes to the
established contracts require the user's approval; measured content and port maps evolve with
the research. Unknown original behavior is not replaced by guessed rules.

## 1. Requirements

Exact observable behavior and maintainable architecture are separate acceptance criteria.
Movement, animation, collisions, combat, inventory, enemies, puzzles, room transitions, menus,
cinematics, drawing and audio must match the reference. A faithful translation of the original
program does not satisfy the architecture requirement.

The user authorized the floppy edition pivot on 2026-10-04. The complete English reference is
`disk1.img`, SHA-256 `3ff964a76e90f3c25489334db38bde021d0c7632f7fa2b90ba234312c1d1272f`,
and `disk2.img`, SHA-256 `ed9b9a5bef0b42d5c394d9b715f27b42edc388d17f243b12ae52f9d3c2e0f9b2`.
Disk 1 is identical to the initial, now-removed `Flashback.ima`. Research lives in `flashback-re`.
There is no mandatory remaster and no runtime dependency on an emulator, decompiler, original
executable's instructions, research tool or sibling repository.

Linux/SDL, a deterministic headless host, Windows/SDL and WebAssembly share the same game.
The user accepts Linux runtime verification plus a Windows cross-build for Windows. Browser
acceptance includes browser execution. Network play is excluded. Audio acceptance is AdLib FM
plus the game's digital samples; MT-32 device ROMs are not required.

## 2. Ownership and boundaries

```text
SDL / agent / browser host
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

## 3. Content import

The compatibility boundary reads the user's extracted files or floppy images, validates ranges and formats,
and produces meaningful typed content. The modern game never indexes an executable by address.
Imported entity identifiers are mapped to semantic content identifiers and actor handles before
the simulation starts. Original addresses and layouts remain in importers, provenance and port
maps, not in world state or public engine APIs.

A `ContentPack` contains named definitions:

- Rooms: background/layers, collision geometry, exits, actor placements and encounter rules.
- Actors: visual definition, health/collision properties, movement and behavior definitions.
- Motion: named moves with animation frames, displacement, collision shapes, transition guards,
  timing and associated events. Original discrete timing and arithmetic are preserved explicitly.
- Items and puzzles: inventory properties, interaction conditions and effects on the world.
- Scenes: menus, text, cinematic selection and transitions.
- Sound: instruments, timed sequences and decoded samples with their rates and priorities.

Legacy object scripts are imported into typed conditions and world effects; the engine does not
dispatch original opcode numbers or reproduce the original's register machine. Conditions name
input actions, pose, collision, health, room, inventory, timers and received events. Effects name
motion changes, damage, item transfers, room changes, activation, spawning and sound. Rules retain
the observable evaluation and event ordering established by the original. They do not retain its
call graph or unstructured jumps.

Parsing and semantic recovery are separate steps. A decoded binary record is not automatically
a useful engine definition. Unsupported content fails with its location and reason; it is not
silently replaced by a default actor, animation or rule.

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

A new guard behavior adds a definition with named states such as patrol, pursue, aim and recover.
Its conditions use distance, visibility, health, timers and events; its effects start motions and
emit attacks. Existing movement, collision, damage, animation and sound systems execute those
effects. A genuinely new mechanic adds a small cohesive behavior/system API, rather than an
original-address branch or a duplicate update loop. The definition can be exercised in a
synthetic room without original assets.

Implementation review checks that these additions remain local and understandable. Merely
renaming original fields, writing a bytecode interpreter with prettier opcodes, or passing pixel
tests over copied original control flow fails this gate. If an exact behavior is a quirk, it is
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
compilation, host/provider contracts, deterministic headless execution and browser linkage;
it is replaced as measured Flashback content and systems arrive. The final acceptance is the
whole faithful, independently designed game, not this foundation or a single playable room.
