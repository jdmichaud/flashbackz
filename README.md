# flashbackz

The modern reimplementation of the supplied Flashback DOS CD edition. This repository is at
the planning stage; it contains no game code or playable build yet.

The game will use the port template's Zig/platform foundation, with Linux/SDL, a deterministic
headless host, Windows/SDL and WebAssembly sharing one game implementation. Its engine will
describe game concepts with typed state and named content, independently of the DOS program's
memory and control flow. Exact original behavior is the acceptance criterion from the outset.

The reference, format maps, tools and measurements live in `../flashback-re`. Any direct
reconstruction lives in `../flashback-remaster`. Original game content is supplied by the user
and kept out of this repository. Network play is out of scope.

See [PLAN.md](PLAN.md). Architecture and timings will be established from the original before
the first gameplay implementation; no Flashback design has been approved yet.
