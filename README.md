# flashbackz

The modern Zig reimplementation of the supplied Flashback DOS CD edition. Both native hosts
load an ISO, MODE1/2352 BIN or extracted game root directly. The default entry remains a menu
preview; `--scene jungle` opens the interactive development slice.

In that slice, Left/Right walk or turn, Shift with a direction runs, Up jumps in place,
Shift+Up jumps forward from standing, Down crouches, and Escape exits.
To roll, press forward while holding Down, then release Down while keeping forward held.
Wake-up, committed steps, turns, braking, one room crossing and the first ledge landing have
exact original state comparisons. Four actual SDL frame checkpoints match the original pixels.
The scene uses shared content, input, controller and rendering code in both native hosts.

This is not a complete game. Running jumps, climbing/grabs, compound roll exits, inventory, combat, other actors, dynamic geometry,
sound, cinematics, saves and menu actions remain unfinished. Unsupported controls/transitions
report errors. The development clock has measured room-change discrepancies; full original
scheduling is not accepted yet. One alternate sprite encoding also remains unresolved.

The content library covers all 193 room backgrounds, 1,284 packed sprite frames, icons, palettes
and collision streams. Imported motion steps match 59,964 original routine executions and use
opaque art references in an independent playback API. Without content, the template's moving
ball remains a platform smoke fixture.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. `zig build`, `zig build test`, `zig build smoke`,
`zig build verify`, `zig build web` and `zig build web-check` are the foundation checks.
`web-check` also needs Node.js. Windows is cross-built with
`zig build -Dtarget=x86_64-windows-gnu`; its SDL2 dependency is pinned and built from source.

```sh
zig build
zig-out/bin/flashbackz-sdl "../Flashback CD.bin"
zig-out/bin/flashbackz-sdl /path/to/flashback.iso
zig-out/bin/flashbackz-sdl --scene jungle "../Flashback CD.bin"
zig-out/bin/flashbackz-agent --frames 2 /path/to/flashback.iso --saves /tmp/flashback/saves
zig-out/bin/flashbackz-agent --scene jungle --frames 180 --key-down 75:left --key-up 85:left /path/to/flashback.iso
```

Images are opened read-only and accessed by ranges, with no external extraction program or full
image buffering. Use the BIN itself for the supplied raw track; CUE descriptors are not yet input
paths. Asset lookup follows DOS case-insensitive names and removes ISO version suffixes.

The game will use the port template's Zig/platform foundation, with Linux/SDL, a deterministic
headless host, Windows/SDL and WebAssembly sharing one game implementation. Its engine will
describe game concepts with typed state and named content, independently of the DOS program's
memory and control flow. Exact original behavior is the acceptance criterion from the outset.

The user clarified on 2026-10-03 that the implementation must not be tethered to the original
game code. Architecture, state models, algorithms, module boundaries and APIs are designed for
readability and extensibility. Merely renaming a translation is insufficient. Original layouts
remain in importers and research; fidelity tests compare observable outcomes through separate
observers. Adding content or behavior must work through coherent systems and named definitions.
Maintainability is an independent acceptance gate, even when fidelity comparisons pass.

The reference, format maps, tools and measurements live in `../flashback-re`. Any direct
reconstruction lives in `../flashback-remaster`. Original game content is supplied by the user
and kept out of this repository. Network play is out of scope.

See [PLAN.md](PLAN.md) and [DESIGN.md](DESIGN.md). The initial architecture defines independent
scene, world, content, rendering and audio boundaries. Original timings and gameplay rules are
established from measurements before their implementation.
