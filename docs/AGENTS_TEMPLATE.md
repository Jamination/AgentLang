A game written from scratch in AL (https://github.com/Jamination/AgentLang), for Linux and Windows.

## Compiler

- Build: `alc build src/main.al -o build/<game>`
- Run: `alc run src/main.al -o build/<game> -- <args>`
- Tests: `alc test src/main.al -o build/<game>.test` (every `test` block), plus `alc run src/main.al -o build/<game> -- --headless`
- Check without building: `alc check src/main.al` (`--all-targets` if the game has `when` branches)
- Always pass `-o build/...` (with `.exe` on Windows): without it, run and test write their
  executables next to the sources.
- After updating the compiler, read the `Breaking` sections of the AL `CHANGELOG.md` that are new.

## Read first, in this order

The docs are in the AL repository (`/home/james/Projects/AgentLang` on this machine):
1. `docs/LANGUAGE.md`: the whole language (under 900 lines). AL is not Go, Rust or C; read it
   completely before writing code.
2. `docs/GAMES.md`: how a game is structured (fixed step, entities, regions, rendering,
   platform shell, `when` and `-D`).
3. `docs/std/vk.md`: the Vulkan workflow (shaders, validation layers, swapchain), and the pages
   in `docs/std/` for each module you use (`window`, `input`, `audio`, `time`, `image`, ...).
4. Reference code (to learn from; not a library): `examples/vk_renderer/`,
   `examples/vk_triangle.al`.

Fine print: `docs/DETAILS.md`. Library overview: `docs/STDLIB.md`.

## Rules

- **Write your own renderer** The standard library has no renderer, sprite batcher or engine,
  on purpose. Copying ideas from the examples is fine.
- **Validation layers on during development:** enable `VK_LAYER_KHRONOS_validation` with a
  debug-utils messenger in debug builds (`-D DEBUG`), and treat every message as a bug.
- **Shaders:** GLSL in `shaders/`, compiled with `glslc` to SPIR-V and built in with
  `embed("shaders/x.vert.spv")`; keep the compile commands in a build script.
- **GPU structs:** declare each uniform / storage buffer struct with
  `const X_SIZE = std140_size[X]()` (or `std430_size`): the compiler checks its layout.
- **Memory bugs:** when something crashes a few frames after the real mistake, run with
  `ALC_CHECK_MEMORY=1`: it stops at the use of memory released by `frame_end()` / `release()`.
- **A headless mode** (`--headless`): scripted input, a fixed number of frames, no window, no
  audio device; prints checksums of the game state. Use it to test changes; it is what CI runs.
- **Deterministic simulation:** fixed time step (`std.time`), seeded random numbers (`std.rand`).
- **Platform code** only in `when TARGET_OS == ...` blocks, in as few places as possible.

## Layout

```
src/main.al        entry point; `use` the other files
src/...
shaders/           GLSL sources (+ compiled .spv)
assets/            PNG, WAV
build.(sh|bat)     compiles shaders and the game
```
