A game written from scratch in AL (https://github.com/Jamination/AgentLang), for <Linux and Windows | Windows | Linux>.

## Compiler

- Build: `alc build src/main.al -o build/<game>` (`build/<game>.exe` on Windows; add `--gui` for a release)
- Run: `alc run src/main.al -o build/<game> -- <args>`
- Tests: `alc test src/main.al -o build/<game>.test` (every `test` block), plus `alc run src/main.al -o build/<game> -- --headless`
- Check without building: `alc check src/main.al` (`--all-targets` if the game has `when` branches)
- Format before committing: `alc fmt src/` (`alc fmt --check src/` fails if a file is not formatted)
- Signatures of the library with their first comment line: `alc sigs src/main.al -- std`
- Always pass `-o build/...`: without it, run and test write their executables next to the sources.
- After updating the compiler, read the `Breaking` sections of the AL `CHANGELOG.md` that are new.

## Read first, in this order

The docs are in the AL repository (its path on this machine: <path>):
1. `docs/LANGUAGE.md`: the whole language (under 900 lines). AL is not Go, Rust or C; read it
   completely before writing code.
2. `docs/GAMES.md`: how a game is structured (fixed step, entities, regions, rendering,
   platform shell, `when` and `-D`).
3. The section below for the renderer this game uses, and the pages in `docs/std/` for each
   module you use (`window`, `input`, `audio`, `time`, `image`, `font`, ...).

Fine print: `docs/DETAILS.md`. Library overview: `docs/STDLIB.md`.

## Rendering: keep the section that applies, delete the others

**std.gfx (2D, Linux and Windows).** `docs/std/gfx.md`: sprites, shapes, render textures, a
virtual resolution; text with `std.gfx_text` (`gfx_font` from a TrueType font, `draw_text`).
Reference: `examples/gfx_starter/`. No shaders, no GPU code of the game's own.

**Direct3D 12 (Windows).** `docs/std/dx12.md`. Reference code (to learn from and copy; not a
library): `examples/gamekit/dx12_gpu.al` (device with WARP fallback, fences, shaders, a sprite
batcher), `examples/dx12_breakout/` (2D), `examples/dx12_crypt/` (3D, mouse-look).
- HLSL source in `shaders/`, built in with `embed("shaders/x.hlsl")` and compiled at start-up
  with `dx_compile` (gamekit, on `D3DCompile`, which returns the compiler's error text).
- Debug layer on during development (`gpu_open(true, ...)` in debug builds, `-D DEBUG`).
- Constant buffer structs: check their size against HLSL's packing (`docs/std/dx12.md`).

**Vulkan (Linux and Windows).** `docs/std/vk.md`. Reference: `examples/vk_renderer/`,
`examples/vk_triangle.al`.
- Validation layers on during development: `VK_LAYER_KHRONOS_validation` with a debug-utils
  messenger in debug builds (`-D DEBUG`); treat every message as a bug.
- GLSL in `shaders/`, compiled to SPIR-V with `glslc` and built in with `embed("shaders/x.vert.spv")`,
  or at run time with `std.shaderc` (both systems); keep the compile commands in a build script.
- GPU structs: `const X_SIZE = std140_size[X]()` (or `std430_size`): the compiler checks the layout.

## Rules

- **Write your own game code.** The standard library has a 2D renderer (std.gfx) but no engine,
  scene graph or 3D renderer, on purpose. Copying ideas from the examples is fine.
- **Memory bugs:** when something crashes a few frames after the real mistake, run with
  `ALC_CHECK_MEMORY=1`: it stops at the use of memory released by `frame_end()` / `release()`.
- **A headless mode** (`--headless`): scripted input, a fixed number of frames, no window, no
  audio device; prints checksums of the game state. Use it to test changes; it is what CI runs.
- **Deterministic simulation:** fixed time step (`std.time`), seeded random numbers (`std.rand`).
- **Platform code** only in `when TARGET_OS == ...` blocks, in as few places as possible; a
  Windows-only game still passes `alc check --all-targets` (`docs/GAMES.md`, Platform code).
- **Credits:** a game that loads JPEG files states "this software is based in part on the work of
  the Independent JPEG Group" in its documentation (`docs/std/image.md`).

## Layout

```
src/main.al        entry point; `use` the other files
src/...
shaders/           HLSL or GLSL sources (Vulkan: + compiled .spv)
assets/            PNG, WAV, OGG, TTF
build.(sh|bat)     compiles shaders (Vulkan) and the game
```
