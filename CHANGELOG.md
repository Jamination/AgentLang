# Changelog

All notable changes to AL (the language, the compiler `alc`, the run-time library and the
standard library `std`) are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are `MAJOR.MINOR.PATCH`;
while the major version is 0, a new minor version may break programs, and every change that
can break a program is listed under **Breaking**. A patch version never breaks one.

## [Unreleased]

### Added
- `docs/AGENTS_TEMPLATE.md`: an `AGENTS.md` template for game repositories written by agents
  (compiler version, reading order, rules).
- README: installing several releases side by side (`alc-0.1.0`, with `alc` as a link).

### Fixed
- `docs/std/vk.md`'s synchronization-validation snippet (and `examples/vk_renderer`) also turn on
  `syncval_shader_accesses_heuristic`; without it, current validation layers do not track
  accesses that shaders make through descriptors, so compute/graphics hazards went unreported.
  The page now also shows destroying the debug messenger.
- Docs: `ortho`'s Y direction and winding with `perspective_vk` (`std/math.md`); parameter types
  of `memcopy` / `memfill`; `str` constants, like literals, are NUL-terminated.
- Docs: raw memory from C (mapped Vulkan buffers) is handled through slices (`mkslice` once,
  then sub-slices, `cast[[]T](...)` views and `ptr(mem[a..])`), which are bounds-checked;
  replaces an integer-cast pointer workaround the docs suggested briefly.

## [0.1.0] - 2026-11-14

The first release. An overview of what a project starting on 0.1.0 gets:

### Language

- Statically typed, compiled, whole-program: `alc build main.al` with no build system;
  `use "file.al"` includes files, `use std.<name>` bundled modules. The reference
  (`docs/LANGUAGE.md`) stays under 900 lines.
- Types: `i8`-`i64`, `u8`-`u64` (wrapping arithmetic), `f32`, `f64`, `bool`, pointers, slices,
  fixed arrays, `str`, tuples, function values, generic structs and enums with data; built-in
  `vec2 vec3 vec4 quat mat4` with operators. No implicit conversions.
- `match` with nested patterns, guards, alternatives and tuple patterns; exhaustiveness checked.
- Generics on functions and types (no constraints); overloading by parameter types; `x.f(a)` is
  `f(x, a)` (no methods, interfaces or closures).
- Nested and anonymous functions (no captures), `defer`, labelled loops, `for .. by` steps.
- Errors are values: `(T, bool)` / `(T, str)` results, `Opt[T]` for absent data; `assert`,
  `panic`.
- Memory: arena allocation, `mark` / `release`, regions (`enter` / `leave` / `reset`), deep
  `clone`; no `free`, no garbage collector.
- `priv` file-private declarations; `when` compile-time branches on constants (`TARGET_OS`,
  `TARGET_ARCH`, constants set with `-D`); `embed("file")` constants; `test` blocks.
- C interop: `extern "lib" fn` and `extern "lib"` variables; AL functions can be C callbacks.
  Programs without `extern` are static, libc-free executables.
- Bounds and division checks on by default (`--unchecked` removes them).

### Targets

- Linux x86-64 (static ELF, or dynamically linked when C libraries are used) and Windows x86-64
  (PE32+, console or `--gui`; the run-time library calls only `kernel32.dll`).
- The compiler runs on both: `build/alc` (Linux) and `build/alc.exe` (Windows) produce the same
  executables. It needs no assembler, linker, LLVM or libc, and compiles itself.
- Generated code runs within about 6% of `clang -O2` on the benchmark set, with checks on.

### Standard library

- Always available: strings, `Vec`, `Map`, sorting, formatting and parsing, files, arguments and
  environment, arenas and regions; `math` (scalars, vectors, matrices, quaternions, geometry,
  easing, colour), `rand`, `time`, `mem` (sub-arenas, pools, ring buffers).
- Modules: `std.asset` (files, paths, user directories, asset cache, hot reload, config and
  JSON), `std.os` (processes, shared memory), `std.image` (PNG, BMP, deflate), `std.input`
  (keyboard, mouse, gamepad, action maps, gamepad hot-plug with `GamepadWatch` /
  `gamepad_changed`), `std.window` (windows, events including `EventMinimize` /
  `EventRestore` and `Window.minimized`, fullscreen, pointer lock for mouse-look with
  `set_cursor_locked` and `mouse_delta`, software presentation, native handles; X11 on Linux,
  Win32 on Windows), `std.audio` (WAV, mixer, ALSA / WASAPI device).
- Bindings: `std.vk` (Vulkan 1.0-1.3 with the surface, swapchain, debug-utils, layer-settings,
  memory-budget and memory-priority extensions, Linux), `std.shaderc` (shaderc's C API: GLSL /
  HLSL to SPIR-V at run time, Linux), `std.wayland` (Linux; with the relative-pointer and
  pointer-constraints protocols), `std.dx12` (Direct3D 12 / DXGI, Windows; with
  `hresult_name`, `hresult_code`, `hresult_text`), `std.metal` (type-check only), and raw
  `std.libc`, `std.x11`, `std.alsa`.
- `std.vk` adds only what the C headers provide: `sType` constructors, a constructor per union
  member (`vk_clear_value_color`, `vk_clear_color_value_float32`, ...), the version macros
  (`vk_make_api_version`, `vk_api_version_major`, ...) and `vk_result_name`. It has no result
  checking, memory-type search or shader-module helper (`vk_check`, `vk_find_memory_type`,
  `vk_create_shader_module`, `vk_clear_color` and `vk_version_*` of earlier development
  states are gone; `examples/vk_renderer/renderer.al` shows the few lines each takes).
- `std.alsa`: `snd_pcm_hw_params_set_*_near` / `get_*` call the current libasound API (they
  reached the pre-1.0 symbols); added period, buffer-time, resampling and poll-descriptor
  functions.
- Graphics are bindings only: `std` has no renderer, sprite batcher or device set-up code. The
  examples' Direct3D 12 set-up and sprite batcher (`examples/gamekit/dx12_gpu.al`, formerly
  `std.dx12_util`) and the Vulkan renderer `examples/vk_renderer` (validation layer and
  messenger, Vulkan 1.3 features, staging, textures, depth, descriptors, compute, timestamps,
  frames in flight, X11 and Wayland swapchains with present modes) are reference code to copy,
  not a library.

### Tools

- `alc build`, `run`, `test`, `check` (`--json` diagnostics, `--all-targets`), `sigs`
  (declarations of a file or of `std`), `alc --version`.
- Options: `-o`, `--target linux|windows`, `--gui`, `-D NAME=VALUE`, `-O0`, `--unchecked`,
  `--emit-ir`, `--emit-asm`.
- Every panic prints a stack trace (`at file:line in function`), also through C library
  frames and inlined code; `ALC_BACKTRACE=0` turns it off.
- `alc run` / `alc test` of a Windows executable on Linux use Wine when `ALC_WINE=1`.

### Known limitations

- x86-64 only; no macOS target (`std.metal` only type-checks).
- No threads in the language; a C callback running on a foreign thread must not allocate.
- Memory released with `release` / `reset` and pointers into a `Vec` that grew are not checked
  (see "Unsafe corners" in `docs/LANGUAGE.md`).
- Windows: C functions with variable arguments cannot be declared; vector types cannot cross the
  C boundary; the compiler compiles sequentially there (no parallel back end).
- No package manager: code outside `std` is included by path.

[Unreleased]: https://github.com/Jamination/AgentLang/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Jamination/AgentLang/releases/tag/v0.1.0
