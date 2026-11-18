# Changelog

All notable changes to AL (the language, the compiler `alc`, the run-time library and the
standard library `std`) are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are `MAJOR.MINOR.PATCH`;
while the major version is 0, a new minor version may break programs, and every change that
can break a program is listed under **Breaking**. A patch version never breaks one.

## [Unreleased]

### Breaking
- `enum Arch` has a second variant, `Arm64` (the new target below): a `match` on `TARGET_ARCH`
  needs an arm for it or `_`.
  `TARGET_ARCH` is now declared by the OS layer of the target instead of the prelude (nothing
  changes for programs).
- `enum Os` has a third variant, `MacOS` (`--target macos` below): a `match` on `TARGET_OS`
  needs an arm for it or `_`; `when TARGET_OS == Windows { ... } else { ... }` takes the else
  branch for macOS, so check that it suits macOS (or add `else when TARGET_OS == MacOS`).

### Added
- `--target macos` (experimental, never run): arm64 Mach-O executables for macOS 11 and later
  (Apple silicon), with chained fixups, an ad-hoc code signature, thread-local data through
  dyld's descriptors, a run-time library over libSystem (`src/prelude_macos.al`), C functions
  by Apple's variant of the Arm calling convention, and dylibs or frameworks as `extern`
  libraries; the core library, std.image, std.font, std.asset, std.os, the mixer of std.audio
  and std.metal build. Checked structurally only (`tests/macho/check.al`, LLVM's tools); see
  docs/MACOS_TEST.md. Not yet: `-g`, std.net, std.input, std.window, audio devices, stack
  traces through C frames, `--all-targets` for macOS.
- `--target linux-arm64` (experimental): AArch64 Linux executables, with
  `TARGET_ARCH == Arm64`. Verified only under the project's own emulator
  (`tests/arm64/emu.al`; `tests/run.sh --target linux-arm64 --emu build/a64emu`), not yet on
  arm64 hardware: see docs/ARM64_TEST.md. Not available there yet: `-g` and the modules that
  make system calls by their x86-64 numbers (`std.net`, the gamepads of `std.input`), which
  are refused with a message.
- linux-arm64: `extern` C functions and variables. A program that uses one is dynamically
  linked (`/lib/ld-linux-aarch64.so.1`, as GCC links them) and calls C by the Arm procedure call
  standard (AAPCS64), including structs, tuples and arrays by value (in floating-point or
  integer registers or by reference, as C passes them; results through x8), variadic calls and
  callbacks; its threads are the C library's. Checked under the emulator against C compiled by
  clang (`tests/sys/c_abi`), not yet against a real loader or C library. Stack traces end at
  the first C frame.
- The compiler builds for arm64 Linux (experimental, as above):
  `alc build --target linux-arm64 -D HOST_ARM64=true src/main.al`.
- `std.gfx`: a 2D renderer on a std.window window. It draws textures from std.image images (a
  one-channel image is a coverage texture, drawn in the tint's colour, for font atlases),
  sprites with source rectangle, rotation, origin and tint, rectangles, lines, triangles with
  per-corner colours, alpha and additive blending, a 2D transform (`camera`, `set_view` for a
  letterboxed virtual resolution), scissor and render textures. Draws are batched by texture
  and state, and nothing is allocated per frame. The backend is chosen by the target:
  Direct3D 12 on Windows, Vulkan 1.3 on Linux (`use std.gfx_vk` gives Vulkan on Windows too);
  the shaders are precompiled (`tools/gen_gfx_shaders.al`). `gfx_offscreen` and `read_pixels`
  serve pixel tests. `examples/gfx_starter` is the starter game on it. See docs/std/gfx.md.
- `std.font`: TrueType / OpenType fonts with TrueType outlines in AL (cmap 4 / 12, composite
  glyphs, `kern` and GPOS pair kerning, `.ttc`), antialiased glyph rasterisation at any size,
  glyph atlases into std.image images, and UTF-8 text layout, measuring, line wrapping and
  drawing into images. CFF outlines are rejected with an error; a malformed font is rejected,
  never read out of bounds. `examples/font_demo.al`. See docs/std/font.md.
- `std.gfx_text`: text for std.gfx with std.font's fonts. `gfx_font(g, font, px, chars)` makes
  a `GfxFont` (the glyphs at one pixel size as a coverage texture; `gfx_font(g, atlas,
  filter)` from an atlas of one's own, `gfx_font_add`, `gfx_font_free`); `draw_text(g, font, x,
  y, text, color)` draws UTF-8 text with kerning and `'\n'`, also aligned (`AlignLeft`,
  `AlignCenter`, `AlignRight`); `draw_text_box` wraps into a rectangle as `wrap_text` does;
  `text_size` and `line_height` measure. Pens are rounded to whole target pixels, so the GPU
  draws what std.font's `draw_text` with the atlas draws into an image (within 1 of 255 per
  channel on Direct3D 12 and Vulkan); `font.size` draws a font rasterised at the size it has on
  the screen at its virtual size under `set_view`; characters outside the font's set draw as
  its missing glyph; drawing allocates nothing. A separate module: a std.gfx program without
  text does not grow. std.font's 4-channel atlases are now white in every pixel (alpha 0
  between the glyphs), so a linear filter no longer darkens the glyphs' edges.
  `examples/gfx_starter` draws its text with it in a system font. See docs/std/gfx.md#text.
- `std.net`: TCP (connect with a time limit, non-blocking connect, listen / accept, send / recv
  with time limits, shutdown), UDP (`udp_bind`, `send_to`, `recv_from`), IPv4 and IPv6 address
  parsing and formatting, and `poll` over several sockets for game loops. Errors are Linux
  errno numbers in `io_error()` on both systems. Sockets are never inherited by programs
  started with std.os, and writing to a closed connection never raises SIGPIPE. `resolve`
  looks names up: on Linux without libc (`/etc/hosts`, then DNS queries to the servers of
  `/etc/resolv.conf`; a program stays static), on Windows through `getaddrinfo`. A minimal
  HTTP/1.1 client (`http_get`, `http_post`, `http_request`; no TLS). See docs/std/net.md.
- `error_text` knows the socket errors 88 to 115 (`connection refused`, `connection timed
  out`, ...) and std.net's name-resolution errors.
- std.audio: Ogg Vorbis decoding in AL (`std/audio_vorbis.al`, loaded by std.audio).
  `ogg_decode` / `ogg_load` decode a whole file into a `Sound`; `ogg_open`, `ogg_open_file`,
  `ogg_read`, `ogg_seek`, `ogg_rewind`, `ogg_close` and `ogg_error` stream it without
  allocating after open. A damaged file fails cleanly. Floor type 0 is not supported.
- std.audio: streamed voices. `AudioStream` and `play_stream(m, s, volume, pan, pitch, looped)`
  play frames pulled from a source while mixing, with gapless looping and the same resampling
  as for a `Sound`; `play_stream(m, st: *OggStream, ...)` / `audio_stream(st)` stream Ogg
  music.
- std.image reads and writes JPEG in AL. `jpeg_decode` / `jpeg_load` handle baseline, extended
  sequential and progressive Huffman-coded files (8-bit), restart intervals, greyscale, YCbCr
  with any whole-number subsampling, RGB and Adobe CMYK / YCCK, with the same pixels as
  libjpeg-turbo. `jpeg_encode(img, quality)` / `jpeg_save(path, img, quality)` write baseline
  files. `image_decode` / `image_load` recognise JPEG by its signature. A truncated file is
  rejected.
- std.shaderc builds for `--target windows`: it binds `shaderc_shared.dll`, the DLL the Vulkan
  SDK installs in its Bin directory, chosen with `when` as std.vk does, so GLSL / HLSL to
  SPIR-V at run time works for Vulkan games on Windows. As on Linux, a program that calls
  shaderc does not start without the library; ship the DLL next to the `.exe`.
  (`shaderc_compile_options_set_max_id_bound` is missing from the DLL of Vulkan SDK 1.4.304.)
- `alc build -g` (also `run` and `test`): debug information. DWARF 4 in Linux and Windows
  executables (lines, functions, parameters and variables with their scopes, types, globals,
  inlined calls, call frames), and on Windows a `.pdb` next to the executable for Visual
  Studio, WinDbg and profilers. At `-O0 -g` every statement can be stepped and every variable
  is visible; with optimisation `-g` does not change the code. See
  [DETAILS.md](docs/DETAILS.md#debug-information).
- `-g` with optimisation: variables kept in registers and spill slots are described (location
  lists: DWARF `.debug_loc`, PDB `S_LOCAL` with `S_DEFRANGE_*`), where the value they have at
  that line is provably there, and "optimized out" elsewhere; parameters passed by reference
  too.
- `-g`: a breakpoint on a function shows its parameters right: they are described in their
  argument registers until the prologue has stored them, the line table marks the end of the
  prologue (`prologue_end`, and a row of its own for gdb), the PDB's debug start is there.
- `-g`, PDB: inlined functions (`S_INLINESITE` with their lines, `LF_FUNC_ID` in IPI), so cdb
  and Visual Studio show inlined calls as frames, as gdb does from DWARF; MD5 checksums of the
  source files. DWARF: `extern` C variables.
- `alc fmt`: rewrites source files in the one canonical layout, changing white space only
  (`--check` lists the files that would change, `--stdout` and `-` for filters); a file with a
  syntax error is left as it is. See [DETAILS.md](docs/DETAILS.md#alc-fmt).
- `examples/dx12_crypt`: a first-person maze with Direct3D 12 (meshes, depth buffer, lighting,
  mouse-look, gamepad, a scripted headless mode and offscreen pixel tests).
- tests: `NAME.windows.need` lists the DLLs a Windows test program needs; one that is not in a
  directory of PATH makes the test a SKIP (`NAME.windows.why`). `tests/sys/shaderc` runs on
  Windows.

### Changed
- Faster loops: the bounds checks of inclusive ranges (`for i in a..=b`) and of ranges with a
  step computed at run time (`by s`) move out of the loop where the bound allows it, and a
  check that does not change in a loop and comes first in it is made once before the loop.
- Windows: a slice, string or struct passed as an argument is no longer reloaded in the called
  function after every store or call.
- Code generation: fewer stores to spill slots; a loop that is left from the "then" side of a
  branch falls through into its own code.
- `--target linux-arm64` compiles functions in parallel threads as the x86-64 back end does
  (the same executable whatever the number of threads, `ALC_JOBS`): the compiler for arm64
  builds in about 0.25 s instead of 0.45 s at `-O0` on 16 CPUs.
- A `{`, `(` or `[` that is never closed: the error (also at the end of the file) says where it
  was opened, ``expected `}`, found keyword `fn` (the `{` opened at 4:6 is not closed)``. When a
  closing bracket stands left of the indentation of the line that opened its bracket, the inner
  bracket is named (`P{2, "y",` followed by `}` under the declaration). A declaration keyword
  in column 1 inside a struct, enum, `match` or never-closed block ends it with that error
  instead of being read as a field or statement.
- Two statements on one line without `;` (`print(x) x = 2`): the error says that they are
  separated by `;`. The hint about a struct literal in the header of `if` / `while` / `for` /
  `match` is only given when the braces could hold the fields of a literal.
- `alc check` (also `--all-targets`) no longer requires `fn main`, as `alc test` already did:
  one file of a program checks alone (its `use` paths are relative to itself, as when it is
  included). `alc build` / `alc run` still report a missing `main`.
- `alc check` type-checks the functions of the core modules (`math`, `rand`, `time`, `mem`)
  that the program does not reach, as it already did for the modules included with `use`
  (about 5 ms more for a small file).
- `in`, `by` and `test` are keywords only in their place (`for x in`, `for i in a..b by s`,
  `test "name" { }` at the top level) and ordinary names everywhere else: `bx, by` block
  coordinates, a parameter `in`, a field `test`. Every program keeps its meaning.
- Operands of different types: the error names the operator and each operand,
  ``operands of `==` have different types: `e1` is bool, `""` is str`` (two comparisons on
  one line, as in `assert e1 == "" && e2 == ""`, are told apart), and the conversion hint
  names the right operand. `expected expression` at a closing bracket or the end of a line or
  file names the bracket that is never closed.

### Fixed
- `alc build` / `alc run` accepted a type error in a function a program does not reach of a
  bundled module read from `ALC_STD_DIR` (a module being written) that `alc check` reported:
  such a module is now checked in full by every command. The modules inside the compiler are
  still compiled only as far as a program reaches them, and the tests check all of them for
  every target (`tests/check/std_targets.al` now includes `std.font`, and
  `std_targets_vk.al` the Vulkan backend of `std.gfx` with `std.vk`).

## [0.4.0] - 2026-11-17

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
- Windows, `std.os`: `run`, `run_capture`, `run_capture_all` and `spawn` no longer start a
  batch file (`.bat`, `.cmd`) directly: they fail with `io_error()` 8 (`exec format error`).
  Windows handed such a file to `cmd.exe`, which reads the command line by rules of its own, so
  an argument with `"`, `&` or `%` could turn into a command. Write `[]str{"cmd", "/c", file,
  ...}`.

### Added
- `std.vk` builds for `--target windows`: every command names the loader of the
  target (`extern VULKAN fn ...`, with `VULKAN` chosen by a `when`), and `VK_KHR_win32_surface` is bound
  (`VkWin32SurfaceCreateInfoKHR`, `vkCreateWin32SurfaceKHR`,
  `vkGetPhysicalDeviceWin32PresentationSupportKHR`, which name `vulkan-1.dll` alone). One
  `use std.vk` serves Linux and Windows; std.window has `win32_hinstance(w)` for the surface.
- `extern` takes the name of a `str` constant as well as a library name: `extern LIBC fn ...`,
  with `LIBC` chosen per system by a `when`. std.libc declares the functions both systems
  share once this way.
- `ALC_CHECK_MEMORY=1` in the environment of a program (no rebuild needed) catches the use of
  released memory: memory given back by `release`, `frame_end` or `reset` of a Region is never
  handed out again, its pages are taken away and the rest is filled with `0xDE` bytes, and the
  fault says what released it (`panic: use of released memory: the memory was released by
  frame_end(): ...`). A `Vec` or `Map` stored outside the innermost `frame_begin()` /
  `frame_end()` scope that grows inside it stops the program at that push. Without it, a
  memory fault at an address that is neither near nil nor on the stack suggests the variable.
- `std140_size[T]()` and `std430_size[T]()`: the size of a struct or array in a GLSL buffer
  block, and a compile error naming the first field whose AL offset (or array stride) differs
  from the rules (a `vec3` before a field the rules place elsewhere, an `[N]f32` under std140,
  a `bool`). Constant-evaluated: `const UBO_SIZE = std140_size[Ubo]()`.
- `std.libc` is available for `--target windows`, bound to `msvcrt.dll`: `strlen`, `getenv`,
  `malloc`, `free`, `qsort`, `printf`, `fprintf`, `sprintf`, `sscanf`, `fflush`, `cosf`,
  `getpid` as on Linux, and `_snprintf`, `_fileno`, `_setmode`, `__iob_func` of that library.
  `snprintf`, `dprintf`, `dlopen`, `dlsym`, `dlerror` and the variables `stdout` / `stderr`
  exist on Linux only. Reference: `docs/std/libc.md`.
- `std.libc`: `c_stdout()` and `c_stderr()`, C's standard streams on both systems.
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
- The conformance tests run on Windows: the test runner is now an AL program (`tests/run.al`,
  built by `build.sh` / `build.bat` as `build/altest` and `build/altest.exe`) that
  `tests/run.sh` and the new `tests\run.bat` start. On Windows it runs the tests of
  `--target windows` directly, with `build\alc.exe`; `--target linux` there builds and
  type-checks the Linux programs. New options: `-j N` (threads), `-v` (list the tests that
  passed). `verify.bat`: build, tests, one line `VERIFY: PASS` or `VERIFY: FAIL`.
- `std.os`: `Launch{stdin, stdout, stderr, env, group}` with `run(argv, how)` and `spawn(argv,
  how)` starts a program with files as its standard streams, with environment variables set
  or removed, and as the leader of a process group (Windows: a job) that `kill` ends as a
  whole; `wait(p, timeout_ns)` waits for a process for a limited time; `NULL_DEVICE` names the
  null file (`/dev/null`, `NUL`).

### Changed
- std.audio: a stall of the device before its second fill (a long first frame after
  `audio_open`, or a WASAPI engine that takes the whole first fill at once) is no longer
  counted in `underruns`: only silence was due. Every later stall is counted as before.
- Windows executables support ASLR: they have a base relocation table (`.reloc`), the flags
  `DYNAMIC_BASE` and `HIGH_ENTROPY_VA` and the preferred base 0x140000000 (before: fixed at
  0x400000, relocations stripped), so they start where "Mandatory ASLR" is enforced. The code
  addresses globals, functions and constants relative to `rip` (about 0.5 % more code, no
  measurable difference in speed). Linux executables are unchanged.
- `tests/run.sh` runs the tests in parallel, one thread per CPU (the tests of `tests/sys`
  after the others, one after the other), with the same lines of output in the same order:
  about 29 s instead of 60 s on 12 CPUs, 23 s instead of 67 s for `--target windows`.
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
- Windows: the thread-local data of the run-time library (the arena of `alloc`, `mark` /
  `release` and regions, the output buffer, `io_error`) is cheaper to reach. A function looks
  up the address of its thread's block once where it needs it (before a loop, not in it)
  and every access is then one instruction, instead of four more instructions per
  thread-local variable. `bench/binarytrees.al` executes 12 % fewer instructions (under Wine
  about 3 % less time at the median, up to 11 %), a loop of `put` 18 % fewer, the compiler
  1.4 % fewer (times unchanged); `alc.exe` is 2.3 % smaller. Behaviour and Linux executables
  are unchanged.

### Fixed
- The documentation said `--gui` (and `--icon`, `--version-info`) without `--target windows` was
  an error; the rule is a Linux target: on Windows, `--target windows` is the default.
- Windows: executables crashed at start on a real Windows ("out of memory" or "memory fault"
  in the first allocation; Wine was unaffected). The TLS directory asked the loader for a
  zero-filled thread block through `SizeOfZeroFill`, which Windows does not honour: the
  thread-local globals (the arena among them) started as garbage. The template now holds the
  zeroed block. Both seed compilers are rebuilt with the fix.
- Windows: paths of 248 UTF-16 units or more (absolute or relative) work without the
  registry setting `LongPathsEnabled`: the run-time library makes them absolute and hands
  them to Windows as `\\?\C:\...` / `\\?\UNC\server\share\...` (they failed with `no such
  file or directory` on Windows; Wine has no such limit).
- `verify.bat` calls `build.bat` and `tests\run.bat` by full path: with
  `NoDefaultCurrentDirectoryInExePath` set, cmd does not look in the current directory and
  the build did not start.
- Tests for real Windows desktops: `window_win32` and `window_win32_input` no longer assume
  Wine's 1024 x 768 screen and top-left window placement or exact pointer ballistics;
  `audio_nodevice` is skipped on a machine with a sound device; `win_files` no longer expects
  a drive root's size to be 0 (NTFS reports one).
- Windows, `std.os`: programs started from several threads at once no longer inherit each
  other's pipes (`run_capture` in one thread waited until a program that another thread had
  started meanwhile ended).
- Windows: `io_error()` after a failed file operation is the Linux number in more cases: 20
  (`not a directory`) for a path that goes through a file (was 2), 36 (`file name too long`)
  for a name of more than 255 characters, 21 (`is a directory`) for reading the
  root of a drive (was 2); running a directory fails with 13 (`permission denied`, was 2).
- Windows, `rename`: a directory over an existing file and a file over an existing directory
  fail with `not a directory` / `is a directory`, as on Linux (Windows says `permission
  denied` for both; under Wine the rename went through).
- Windows: paths in the extended-length form (`\\?\C:\...`) may contain `/`, so `path_join`
  works on them (Windows itself takes `/` there as part of a name).
- Windows: `write_file` / `write_bytes` replace a hidden or system file, which keeps the
  attribute (`CreateFileW` refuses to replace such a file with `permission denied` unless it
  is given the same attributes).

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

[Unreleased]: https://github.com/Jamination/AgentLang/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Jamination/AgentLang/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Jamination/AgentLang/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/Jamination/AgentLang/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Jamination/AgentLang/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Jamination/AgentLang/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Jamination/AgentLang/releases/tag/v0.1.0
