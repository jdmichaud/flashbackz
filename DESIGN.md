# Flashbackz design

Initial design, 2026-10-03; revised 2026-10-08 with the user's approval: character behavior and
level content are data (sections 3, 4 and 7); the architecture as built, with Conrad on his
behavior table, approved by the user on 2026-10-09. This is an independently organized game, verified against the supplied
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
Application (game.zig): scenes (title, level, continue), scheduling, loading, persistence
        |
Level scene: the keyboard's input byte, films, messages, inventory, options -> Screen
        |
Behavior engine (World): every character's live state, rooms, contacts, mailboxes, terrain,
    running the behavior tables with the original's evaluation order
        |
immutable data set (characters, behavior tables, messages, scenes) + level pack (room art,
    character art, animations, collision, icons, font, sounds) read from the original files
        |
Screen -> indexed frame -> RGBA; effects mixer and film music -> PCM
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
  never written out (except by the level atlas, below) or committed.
- **Everything else** (placements, behavior rules, links between characters, timings, text)
  is converted once by the **extractor** into a readable **data set** stored outside Git, in a
  directory the user chooses. The game loads only the data set plus the original images and
  sound. The extractor is the only code that understands the original's placement and rule
  formats; addresses and record layouts never leave it, with one exception, decided by the user
(review D1, 2026-10-10): where play depends on how the original laid out its memory (reads past
the collision grid, the leftward sight scan reading placement records, the boarding test on a
record's address), `behavior/original_memory.zig` reproduces it exactly, and nothing else does.

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

**A standalone build** (approved by the user, 2026-10-10) is the one place where original files
enter a binary: `zig build -Ddisk1=PATH -Ddisk2=PATH [-Dmegadrive=PATH]` checks the user's
files, then copies them into a generated module from which a second build of the SDL game,
`flashbackz-standalone`, is made (user's names, 2026-10-10); with no path on its command line it
reads them as it would read the same files given there. That executable holds the original game
and is for the user's own machines: never committed, never distributed. The game itself,
`flashbackz`, and the agent host never have files built in.

**The level atlas** (user request, 2026-10-10) is the one tool that writes original art out:
`flashbackz-atlas [-o FILE] disk1.img disk2.img` (built by `zig build atlas`; a release build,
`-Doptimize=ReleaseFast`, takes seconds where a debug build takes a minute) draws every level's
rooms into one PNG, placed by their links (`src/atlas`). An area reached by a transport stands
beside the room the ride leaves from, on its row a room's width away, where it fits (Earth's
taxi). Links between pieces that cannot lie flat and the other transports carry matching
lettered tags; a floor that wraps around within one piece (the tower's) carries none. A level
with a transit line (a ring of links whose pictures never continue and that alone joins parts of
the level, like the city's subway) is drawn along it instead, without tags: its stations on one
row, each under the room it leads up to (touching it where no other room is near), its districts
above, closing in on each other without their rooms ever touching, the areas off the line below.
The PNG is the user's, like the standalone executable: never committed, never distributed.

Unsupported content fails loudly. The extractor reports every condition or effect it cannot
name, with level, character and state. The engine refuses a table that uses an unimplemented
condition or effect; it never substitutes a default.

## 4. Session and systems

Revised 2026-10-09: the behavior engine runs every character, and the hand-written systems
are gone.

`World` (`src/shared/behavior/world.zig`) owns one live record per character: state, position,
room, animation cursor, health, counter, facing, activity, displayed frame and inventory links.
It also owns the room lists, the contact cells, the mailboxes, the collision grid with its
terrain history, the score and the checkpoint. Definitions (characters, behavior tables) are
shared immutable content from the data set; per-session state belongs to the world.

The only command is Conrad's input byte: four directions and four buttons held, with the
original's diagonal rule, read by the level scene from the keyboard or the pads (or a demo
recording). SDL
key symbols, DOS scancodes and host repeat events never become simulation state; modal screens
release held keys as the original does.

One update walks the active characters in placement order; each plays a frame or, when its
animation ends, fires its first rule whose checks hold (section below). Movement, collision,
contact, combat and room flow are not separate systems: they are conditions and effects of the
vocabulary, each implemented once (`src/shared/behavior/operations/`). The update's other
steps (contacts, view changes, defeat countdown, protection) are documented in the engine and
measured in flashback-re `docs/rules/engine-update.md`.

### Characters and behavior tables

Every character follows a behavior table, Conrad included (2026-10-09: his table reproduces
the original on every capture, so the planned Zig controller was not needed).

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
research gates pass.

**Saves** (an addition, user decision and approval, 2026-10-10). Besides the original's
checkpoints (kept in memory for Retry), a level in play can be saved: SAVE GAME in the options
dialog into one of eight slots, or F5 into the quick slot. A save loads from LOAD GAME on the
title menu, or with F9 during play. A save holds the session's state: level, difficulty, score,
the random generator, what is carried between levels, the world (every character, the terrain,
contacts, mailboxes, the checkpoint) and the level's play state. Art, sound and pictures are
reloaded and redrawn, as Retry does. It is taken only between two updates, never during a film or
a demo. A save is one readable record, stamped with its version and a fingerprint of the data set
it was made with; a save of another version or data set is listed and refused. Loading a save and
replaying the same input reproduces every character on every update.

## 5. Time and arithmetic

The scheduler separates simulation time, presentation time and audio sample time. The original's
logic rate, cinematic rate, timer units, pauses and loading waits are measured requirements,
not assumed to be the template host's 60 Hz. Updates perform bounded work; budgets may not
change event ordering or simulation results. The agent's virtual clock makes replay independent
of how long the test runner takes to think or execute. A gameplay frame waits two ticks of the
original's 70 Hz counter. When the host falls three ticks behind, the next frame walks the
characters twice and draws once, and the lost time is dropped, as the original does (user
decision, 2026-10-09).

Simulation uses integer arithmetic with explicit precision, overflow and rounding where they
affect observable outcomes. The imported motions and rules describe their measured units.
One owned random generator supplies named draws in a defined order; its algorithm and seeding
come from the original.

## 6. Presentation and audio

The level scene's `Screen` presents the world after each update as the original does (flashback-re
`docs/rules/engine-presentation.md`): room art, the characters of the view room and the edges of
its neighbors in four layers, the HUD icon, the touch label, the password, world messages and the
colors in the display. It owns indexed pixels and palettes, then converts to an RGBA8 frame for
the host. It does not emulate VGA registers, but it keeps the original's observable timing: two
hidden updates after a room load, a HUD icon and shake that reach the picture at the flip, and
message pages alternating between two video pages. The game content is 256 by 224 pixels;
films have their own measured dimensions and pacing. Music plays with films and on the title
screens, chosen per scene (`docs/rules/engine-music.md`), and, with the Mega Drive cartridge, its
tunes during play; effects follow the engine's sound requests. The MUSIC option controls the
music and the tunes, SOUND FX the effects.

Audio sequencing and sample decoding are Flashback subsystems with measured priorities and
timing. A generic OPL2/OPL3 synthesizer is reused from vpoolz after its code, tests and
attribution were reviewed. Virtual Pool's sequencer, driver, voice ownership and memory layout
are not reused. The Mega Drive sound chips (YM2612, PSG, DAC player) are vendored whole from
sorz (`src/shared/audio/megadrive`, user permission, 2026-10-09), parts the game does not call
included, so that changes go back to sorz unaltered. One audio output, owned by the game,
opens the device once for 44,100 Hz stereo, which the host converts to what the device plays,
and mixes the sources of the moment (a music; a level's effects and tunes) on that sample clock
into a short bounded queue; the host only plays it. A device that fails leaves the game silent.
Renderer refresh rate cannot set music tempo.

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

The template's platform smoke program (a bouncing ball) established compilation, host/provider
contracts, deterministic headless execution and native SDL presentation at the start; it is gone
(2026-10-10), and the game runs only with the original's files. The final acceptance is the
whole faithful, independently designed game, not this foundation or a single playable room.
