# flashbackz

The modern reimplementation of the supplied Flashback DOS CD edition. The current native build
loads the original main-menu artwork directly from an ISO, MODE1/2352 BIN, or extracted directory
and reproduces its pixels. This is a menu preview; gameplay and menu actions are still being
implemented. Without game content, the template's moving ball is a platform smoke placeholder.

The content library also imports all 193 original room backgrounds with bounded run decoding
and the DOS level-palette conversion. Their indices match execution of the original decoder;
first-room background colors match the original capture outside its actor/UI overlays. These
content checks do not yet make the preview playable.

The shared library now also imports packed sprites, interface icons, actor palettes and
collision streams. A research composition through these importers and the modern renderer
matches the complete first-room screenshot pixel for pixel. Animation and gameplay are still
being implemented; one alternate sprite encoding remains explicitly unsupported.

Motion clips use an independent playback API with opaque art references. Imported animation
steps match 59,964 original routine executions, covering facing, movement and signed wrapping.
Behavior selection, clip transitions and the original scheduling clock remain unfinished.

Wake-up and complete turns now have a named controller, verified update by update against
three original runs. Walking, running, braking, a room crossing and the first ledge descent
also match original state traces. Other actions, dynamic geometry and scene integration remain unfinished;
the native application is still the menu preview.

Build with Zig 0.17.0 and SDL2 2.32.4 on Linux. `zig build`, `zig build test`, `zig build smoke`,
`zig build verify`, `zig build web` and `zig build web-check` are the foundation checks.
`web-check` also needs Node.js. Windows is cross-built with
`zig build -Dtarget=x86_64-windows-gnu`; its SDL2 dependency is pinned and built from source.

```sh
zig build
zig-out/bin/flashbackz-sdl "../Flashback CD.bin"
zig-out/bin/flashbackz-sdl /path/to/flashback.iso
zig-out/bin/flashbackz-agent --frames 2 /path/to/flashback.iso --saves /tmp/flashback/saves
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
