# Changelog

All notable changes to AL (the language, the compiler `alc`, the run-time library and the
standard library `std`) are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are `MAJOR.MINOR.PATCH`;
while the major version is 0, a new minor version may break programs, and every change that
can break a program is listed under **Breaking**. A patch version never breaks one.

## [Unreleased]

### Breaking
- Windows executables are relocatable and loaded at a random address above 4 GiB (see
  Changed): the address of a global or a function no longer fits in 32 bits and differs from
  run to run. A program that kept one in an `i32` / `u32` must keep it in a pointer or `i64`.
- Windows executables carry a manifest (see Added) that makes the process per-monitor DPI
  aware and gives it the UTF-8 code page from its start: a program that opens windows with its
  own `user32.dll` calls now gets physical pixels instead of being scaled by Windows, and the
  `A` functions it declares (`MessageBoxA`, a C library's `fopen`) take UTF-8 instead of the
  system's code page (Windows 10 1903 and later). Programs using std.window and the run-time
  library's functions behave as before.
- std.window, mouse-look: while the cursor is locked (`set_cursor_locked`), `mouse_delta`,
  `mouse_pos` and the positions of mouse events count **raw device counts** (Windows: raw
  input; Linux: XInput 2 raw motion), no longer pixels of the accelerated pointer: a
  sensitivity tuned against the old numbers needs retuning (see Changed). The motion of a
  freed pointer over a locked but unfocused window is no longer reported.
- std.window on Windows: no input method editor (IME) is attached to a window unless the
  program calls `set_text_input(w, true)`: a program that takes Chinese, Japanese or Korean
  text must call it while the user types (see Added). Text of layouts that type characters
  directly arrives as before.
- Linux programs that use std.window are also linked against `libdl.so.2` (part of glibc).

### Added
- `build.bat`: builds the compiler on Windows the way `build.sh` does on Linux (seed -> stage 1
  -> stage 2 -> stage 3, `--quick`, `--reseed`), from a committed Windows seed
  `bootstrap/alc.exe`; it also builds the Linux compiler. `build.sh --reseed` now refreshes both
  seeds.
- `alc build --target windows --icon app.ico`: the executable's icon (all images of the `.ico`
  file: Explorer, taskbar); std.window gives it to its windows. An unreadable or malformed
  file is an error.
- `alc build --target windows --version-info NAME=VALUE` (once per name: `FileDescription`,
  `ProductName`, `CompanyName`, `FileVersion`, `LegalCopyright`, ...): the version information
  shown in the file's Properties. Both options without `--target windows` are usage errors.
- Every Windows executable has an application manifest: `asInvoker`, Windows 10/11 as
  supported systems, long-path aware, per-monitor (v2) DPI aware, UTF-8 active code page.
- std.window: `set_text_input(w, on: bool)` and `Window.text_input`: the user types text (on)
  or plays (off, the default). On Windows it attaches / detaches the IME, so that with an IME
  language active every key still arrives as a key event while playing; on X11 it changes
  only the field (the session's input method stays attached).
- std.window on Windows: `WM_UNICHAR` (UTF-32 text sent by other programs) arrives as
  `EventText`.
- std.window helpers for tests and custom loops: `motion_from_raw_mouse` (Windows: one
  `RAWINPUT` mouse record, `RawInputMouse` / `RawMotion`) and `motion_from_xi_raw` (Linux: one
  XInput 2 raw event, `XIRawEvent` / `XiAbsDevice`); std.x11: `X_GENERIC_EVENT`,
  `XQueryExtension`, `XGetEventData`, `XFreeEventData`, `x_event_cookie_extension` / `_evtype`
  / `_data`.
- `examples/win32_input.al`: F3 locks the pointer and prints the raw motion of each frame, F4
  switches text input.

### Changed
- Windows executables support ASLR: they have a base relocation table (`.reloc`), the flags
  `DYNAMIC_BASE` and `HIGH_ENTROPY_VA` and the preferred base 0x140000000 (before: fixed at
  0x400000, relocations stripped), so they start where "Mandatory ASLR" is enforced. The code
  addresses globals, functions and constants relative to `rip` (about 0.5 % more code, no
  measurable difference in speed). Linux executables are unchanged.
- std.window, mouse-look reads the mouse itself instead of the pointer. Windows: raw input
  (`RegisterRawInputDevices` for the mouse while the window holds the pointer, `WM_INPUT`,
  `GetRawInputData`); the pointer is confined to the pixel in the centre of the client area
  (before: to the client area, and moved back with `SetCursorPos`). Linux: XInput 2
  `XI_RawMotion` through `libXi.so.6`, loaded at run time (without it, or without the
  extension, the pointer's motion as before). The units are device counts on both systems,
  independent of pointer speed, acceleration and display scale; devices that report positions
  (tablets, remote desktop, virtual machines) are differenced in screen pixels.
- std.window: a run of motion of a locked pointer between two polls is one `EventMouseMove`,
  so a mouse that reports thousands of times a second cannot fill an event queue.
- std.window on Windows: a locked pointer is free (and visible) while the window is not
  focused, is minimized, is being moved or resized or has its menu open, and until a click on
  the title bar, border or caption buttons that activated the window is over; it is hidden
  only while the window holds it.

## [0.3.0] - 2026-11-15

### Breaking
- `std.libc`'s `snprintf` is now declared as the variadic C function it is (`snprintf(buf: *u8,
  n: i64, format: *u8, ...)`) instead of taking exactly an `f64` and an `i64`: any number of
  arguments of any C-compatible type works, but an untyped integer literal is now passed as a C
  `int` (`i32`): for `%ld` write `i64(42)`. It can no longer be used as a function value.
- `std.x11`'s `XCreateIC` is variadic too (`XCreateIC(im: *u8, ...)`): pass each value as an
  `i64` or a pointer (`i64(style)`, not an untyped constant), ending the list with `nil`.

### Added
- C variadic functions: the parameter list of an `extern` function may end in `...` (`extern
  "libc.so.6" fn printf(format: *u8, ...) -> i32`). The further arguments are passed with the C
  default argument promotions (`i8`, `i16`, `u8`, `u16`, `bool` become `i32`, `f32` becomes
  `f64`, untyped integer literals are `i32` if they fit, else `i64`, untyped float literals
  `f64`, `nil` a `*u8`); structs, tuples, arrays, slices (`str`: pass `ptr(s)`), vectors and
  enums with data are errors. Linux: System V convention (`al` = vector registers used);
  Windows: floating-point arguments in the first four slots go in both the xmm and the integer
  register. `...` in an AL function or a function type is an error (take a slice); defining
  variadic functions in AL is not supported.
- `std.libc`: `printf`, `fprintf`, `dprintf`, `sprintf`, `sscanf`, `fflush` and the C
  library's `stdout` and `stderr`.

## [0.2.2] - 2026-11-14

### Changed
- The compiler uses more threads for big programs and fewer for small ones: one per CPU, up to
  32 (was at most 6), and at most one per 24 functions at `-O0` or per 12 when optimising
  (`ALC_JOBS=n` still sets the number). On 12 CPUs the compiler compiles itself without
  optimisation in 0.124 s instead of 0.134 s (`bench/compile.sh`); small programs no longer
  start threads that cost more than they save (memory included: about 6 MB a thread).
- The worker threads reserve a stack of 1 MiB instead of 1 GiB: mem2reg no longer recurses once
  per block (its search for a variable's definition uses a work stack of its own), and nothing
  else in the back end recurses with the size or nesting of a function (about 12 KiB used on
  every program measured, 2,000-level nests and 80,000 `if`s in a row included).

## [0.2.1] - 2026-11-14

### Changed
- The compiler compiles functions in parallel on Windows too: worker threads instead of forked
  worker processes, the same on Linux and Windows (`ALC_JOBS=n` still sets the number).
  `alc.exe` compiles the compiler 40% faster without optimisation and 15% faster optimised
  (under Wine); on Linux the back end takes 10-15% less time. A crash in a worker now ends the
  compiler with its message; the forked workers' fallback (the compiler redid what a crashed
  worker had not delivered) is gone.

## [0.2.0] - 2026-11-14

### Added
- Threads (`std.os`): `thread_spawn(f, ctx)` (also with a stack size), `thread_join(&t)` (the
  thread's memory becomes the region `t.region`), `thread_id()`, `cpu_count()`, `Mutex`
  (`lock`, `unlock`, `try_lock`) and `Cond` (`wait`, `wait` with a timeout, `signal`,
  `broadcast`); zero values usable. The run-time library is thread-safe: every thread has its
  own arena, region stack, output buffer and `io_error()`; lines of different threads never
  mix; a panic in any thread ends the program and names the thread (`panic in thread 3: ...`).
  Run-time checks: regions entered/reset/freed by another thread, double or self `thread_join`,
  `unlock` by a thread that does not hold the mutex.
- Atomic builtins, sequentially consistent: `atomic_load`, `atomic_store`, `atomic_swap`,
  `atomic_add`, `atomic_sub`, `atomic_and`, `atomic_or`, `atomic_xor`, `atomic_cas`,
  `atomic_fence()`.
- AL code may run on threads that C libraries create (callbacks): it gets an arena, an id and an
  output buffer of its own on first use.
- `docs/AGENTS_TEMPLATE.md`: an `AGENTS.md` template for game repositories written by agents
  (compiler version, reading order, rules).
- README: installing several releases side by side (`alc-0.1.0`, with `alc` as a link).

### Changed
- Executables have a `PT_TLS` program header (Linux) or a TLS directory (Windows); the arena
  globals are thread-local, accessed `fs`-relative on Linux (the same speed).
- `alc build` replaces an executable that cannot be written because a process that just ended
  still maps it (Linux, after programs with threads) instead of failing with "Text file busy".
- `Region` has one more internal field (the thread that entered it).

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

[Unreleased]: https://github.com/Jamination/AgentLang/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/Jamination/AgentLang/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/Jamination/AgentLang/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Jamination/AgentLang/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Jamination/AgentLang/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Jamination/AgentLang/releases/tag/v0.1.0
