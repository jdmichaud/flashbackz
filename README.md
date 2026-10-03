# flashbackz

The modern reimplementation of the supplied Flashback DOS CD edition. The current code is a
platform smoke skeleton, not Flashback gameplay. The native, headless and browser hosts share
one module; the template's synthetic moving ball only exercises those boundaries.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. `zig build`, `zig build test`, `zig build smoke`,
`zig build verify`, `zig build web` and `zig build web-check` are the foundation checks.
`web-check` also needs Node.js. Windows is cross-built with
`zig build -Dtarget=x86_64-windows-gnu`; its SDL2 dependency is pinned and built from source.

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
