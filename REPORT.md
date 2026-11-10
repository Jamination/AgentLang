# Report: AL for games

State of the repository after the "fit for high-performance games" goal.
`./verify.sh` is the single check for everything below; its last result is in
[Verification](#verification).

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
| `extern "lib.so" fn` | C functions; a program that reaches one becomes a dynamically linked ELF (PT_INTERP, PT_DYNAMIC, GLOB_DAT relocations written by `alc` itself), every other program stays static and libc-free |
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

RESULTS_PLACEHOLDER

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
