# AGENTS.md template for a game written in AL

Copy this file into the root of a new game repository as `AGENTS.md` and fill in the
placeholders. It tells an agent which compiler to use, what to read, and the house rules.

---

# <Game name>

A game written from scratch in AL (https://github.com/Jamination/AgentLang), for Linux
(Windows optional).

## Compiler

- Version: **0.2.0**. Use `alc-0.2.0` (or `alc`, if `alc --version` prints `alc 0.2.0`).
- Build: `alc-0.2.0 build src/main.al -o build/<game>`
- Run: `alc-0.2.0 run src/main.al -- <args>`
- Tests: `alc-0.2.0 test src/main.al` (every `test` block), plus `alc-0.2.0 run src/main.al -- --headless`
- Check without building: `alc-0.2.0 check src/main.al` (`--all-targets` if the game has `when` branches)
- A newer compiler may break code: read the `Breaking` sections of the AL `CHANGELOG.md` before
  switching, then change the version above.

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

- **Write your own renderer** on the Vulkan bindings (`std.vk`). The standard library has no
  renderer, sprite batcher or engine, on purpose. Copying ideas from the examples is fine.
- **Validation layers on during development:** enable `VK_LAYER_KHRONOS_validation` with a
  debug-utils messenger in debug builds (`-D DEBUG`), and treat every message as a bug.
- **Shaders:** GLSL in `shaders/`, compiled with `glslc` to SPIR-V and built in with
  `embed("shaders/x.vert.spv")`; keep the compile commands in a build script.
- **A headless mode** (`--headless`): scripted input, a fixed number of frames, no window, no
  audio device; prints checksums of the game state. Use it to test changes; it is what CI runs.
- **Deterministic simulation:** fixed time step (`std.time`), seeded random numbers (`std.rand`).
- **Platform code** only in `when TARGET_OS == ...` blocks, in as few places as possible.
- Keep it simple: no frameworks, no code generation unless a program in the repo does it.

## Layout

```
src/main.al        entry point; `use` the other files
src/...
shaders/           GLSL sources (+ compiled .spv)
assets/            PNG, WAV
build.sh           compiles shaders and the game
```
