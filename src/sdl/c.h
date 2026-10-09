// The SDL2 API for the SDL host: build.zig translates this header into the `c` module. The game's
// own `main` stays the entry point on every system.
#define SDL_MAIN_HANDLED
#include <SDL.h>
