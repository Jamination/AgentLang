# Report: AL for games

State of the repository after the "fit for high-performance games" goal.
`./verify.sh` is the single check for everything below; its last result is in
[Verification](#verification).

## Later change: the compiler is now written in AL

After this report was written, the compiler was translated from Rust to AL and the Rust
sources were removed (last Rust state: git tag `rust-final`). `alc` now compiles itself;
see [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md). Everything below still holds, with
"`cargo build --release`" replaced by "`./build.sh`" (seed compiler, three stages, stages 2
and 3 byte-identical). The numbers in the verification section are from the Rust-built
compiler; the AL-built compiler produced byte-identical executables for all of those
programs, so they are unchanged apart from timing noise.

## Changes to the goal made by the user while the work was running

- **No power-off.** The goal said to power the machine off at the end; the user came back and
  said not to power it off at all. Nothing was powered off.
- **No ECS.** The user dropped the entity-component module: entities are meant to be fat
  structs or tagged unions. `std.ecs` was removed; `docs/GAMES.md` and `docs/std/mem.md`
  describe the fat-struct-in-a-pool pattern instead, and `tests/std/mem_entities.al` runs
  100,000 such entities.

## What exists now

### Language

| Feature | Notes |
|---------|-------|
| `f32` | full arithmetic, conversions, shortest round-trip printing; scalar SSE code |
| `vec2`, `vec3`, `vec4`, `quat`, `mat4` | built-in types with operators, swizzles, component stores, constructors; one SSE register per vector, packed instructions (`addps`, `mulps`, `shufps`); C-compatible memory layout (`vec3` is 12 bytes) |
| overloading | functions overload on parameter types; resolution looks at the receiver and then every argument; exact definitions beat generic ones |
| `f[T](x)`, `x.f[T](a)`, generic function values | explicit type arguments everywhere |
| `extern "lib.so" fn name(...)` | C functions; a program that reaches one becomes a dynamically linked ELF (PT_INTERP, PT_DYNAMIC, GLOB_DAT relocations written by `alc` itself), every other program stays static and libc-free |
| `use std.<name>` | modules bundled inside the compiler binary |
| raw strings, `embed("file")` | multi-line text between backquotes; file contents at compile time |
| `fmin`, `fmax`, `cstr`, `from_cstr` | |

Fixes found on the way: `release()` of a mark taken before the first allocation, `fmt()`'s
buffer living in the arena, functions hiding library types of the same name.

### Standard library

Always loaded: **math** (transcendentals written in AL for `f32` and `f64`, vectors,
quaternions, matrices, geometry, easing, colour), **rand**, **time** (frame clock, fixed
timestep, timers), **mem** (sub-arenas, frame scopes, pools with generational handles, rings).

`use std.…`: **asset** (files, paths, cached loading, config and JSON readers), **image**
(PNG / BMP load and save with its own inflate / deflate), **input** (key / mouse / gamepad
state, action maps), **window** (X11: events, fullscreen, software present, Vulkan surface
handles), **audio** (WAV, software mixer, ALSA output), **vk** (generated from `vk.xml`:
300 structs, 235 commands), **dx12** (generated from the mingw headers: 278 structs,
124 interfaces), **metal** (hand-written over the Objective-C runtime).

Documentation: `docs/LANGUAGE.md`, `docs/STDLIB.md`, `docs/GAMES.md`, `docs/std/*.md`.
A complete small game in the recommended structure: `examples/starter/game.al`.

## Verification

`./verify.sh` exits 0 (`VERIFY: PASS`). It was run twice in total: the first run failed on a
bug in the new part of the script itself (it reported "no test for module" for modules that
have tests), the second passed. Two runs against a cap of 40 failures.

| Check | Result |
|-------|--------|
| build | (at the time) `cargo build --release`, Rust std only, no crates; now `./build.sh` |
| no external tools in the compile path | pass |
| conformance | 190 passed, 0 failed, 1 skipped: language (default, `-O0`, `--unchecked`), standard library, system-dependent tests, bindings, diagnostics, unit tests |
| `f32` against C | `tests/c/f32.al` prints the same 182 lines as `tests/c/f32.c` built with `clang -O2`, in all three build modes |
| vectors / matrices / quaternions | `tests/run/vectors.al`, `vectors2.al`, `overload.al`, `overload2.al`, `tests/std/math_linalg.al` |
| standard library | every module has tests and a documentation page; the 23 library test programs that need no system library are static executables |
| Vulkan | an offscreen 256 x 256 triangle rendered by the NVIDIA driver; pixels match `tests/sys/data/vk_triangle.ref` |
| DX12, Metal | bindings and one triangle sample each pass `alc check` |
| benchmarks | byte-identical output on all 10; geometric mean AL / clang -O2 = 1.072 (limit 1.5); worst ratio 1.248 (limit 2.5) |

| benchmark | clang -O2 | AL | ratio |
|---|---|---|---|
| nbody | 0.334s | 0.417s | 1.248 |
| spectralnorm | 0.209s | 0.219s | 1.046 |
| fannkuch | 0.192s | 0.223s | 1.158 |
| mandelbrot | 0.560s | 0.567s | 1.012 |
| binarytrees | 1.247s | 1.136s | 0.911 |
| sha256 | 0.768s | 0.849s | 1.105 |
| matmul | 0.399s | 0.424s | 1.061 |
| quicksort | 0.420s | 0.433s | 1.032 |
| sieve | 0.500s | 0.514s | 1.028 |
| hashmap | 0.736s | 0.851s | 1.157 |

**Skipped (1):** `window_x11`: opening a real window needs a private X display
(`AL_TEST_DISPLAY`), which this machine does not provide to tests. The window module is
covered headlessly by `tests/std/window_logic.al` (key mapping, scaling, event translation)
and `tests/sys/window_nodisplay.al` (clean failure without a display).

Other measurements taken during development (not part of `verify.sh`):

- Scalar math against the C library, 160 inputs per function and precision: every
  transcendental function within 1 ulp in `f32` and `f64`, `fmod` exact.
- Differential fuzzing (unoptimised vs optimised vs unchecked, IR verifier on): 750 general
  programs and 1,160 `f32` / vector programs since the vector work, no differences.
- `mat4 * mat4` + `mat4 * vec4` loop: 0.102 s against 0.144 s for scalar C at `clang -O2`;
  an `f32` Mandelbrot loop: 0.117 s against 0.202 s. Single runs, one machine.
- Compiling hello world takes 17 ms with the whole core library loaded; the starter game 84 ms.

## Things you should know

- **DX12 and Metal are type-checked only.** `alc` has no Windows or macOS backend; building a
  program that uses them stops with a clear link error. The DX12 layouts, vtable slots and
  constants were proven against the mingw headers with static assertions (278 structs,
  2667 vtable slots, 2993 constants). The Metal module has never run anywhere: it is checked
  only by the type checker against Apple's documented names and values.
- **The mingw cross compiler (gcc) was used once, at development time,** by
  `tools/gen_dx12.py --verify` for those static assertions. It is not in the compile path of
  `alc`, and `verify.sh` does not call it.
- **Window on a real display.** The window test in `verify.sh` is skipped: it only runs when
  `AL_TEST_DISPLAY` names a private X display, so that tests never open windows on your
  desktop. During development the real window path (events, text input, resize, fullscreen,
  close button, software present) was exercised on an isolated private desktop. Not confirmed
  visually: hiding the mouse cursor.
- **Sound on a real device was never played.** The mixer is tested by its output samples and
  the ALSA path against the `null` device; the only untested difference is the device name.
- **A real gamepad was not available**; only event parsing and the open-failure path ran.
- **No Vulkan validation layers are installed here**, so the triangle was not run under them.
  Its pixels match an analytically computed reference image (largest channel difference 1).
- **Three of the helper agents were cut off by an API rate limit** (math, image, DX12 / Metal)
  after writing their modules. I finished those parts myself: the math tests and reference
  generator, the image encoder / operations test, the Metal sample, and the four
  documentation pages. I did not re-derive the agents' internal claims that I could not
  check, and left them out of the docs (for example that the PNG decoder was fuzzed).
- **nbody** is still the slowest benchmark against clang (about 1.25x), for the same reason as
  before: clang vectorises pairs of doubles and `alc` has no auto-vectoriser. Explicit
  `vec3` / `vec4` code does compile to packed SSE.

## Not done

- Windows and macOS code generation (PE / Mach-O writers, their calling conventions).
- A Wayland window backend, and an audio thread (sound is pumped from the game loop).
- An auto-vectoriser; AVX. Vector code is SSE2-level, like plain `clang -O2`.
- `vec2` / `vec3` / `vec4` of types other than `f32`; `mat3`.
