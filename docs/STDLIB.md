# AL standard library

Everything here ships inside the compiler: there is nothing to install and no search path.
`alc sigs file.al -- std` lists every declaration that a program can see (internal helpers that
are `priv` do not appear: a program may reuse their names).

## Always available (no `use`)

| Part | What it gives | Reference |
|------|---------------|-----------|
| core | printing (`print`, `eprint`), `Vec`, `Map` (insertion-ordered), strings, number formatting and parsing, sorting, `Opt`, file I/O with `io_error()`, `args`, `env_get`, arena memory and regions, `clone`: every signature with its edge cases | [LANGUAGE.md](LANGUAGE.md#standard-library) |
| built-in types | `vec2 vec3 vec4`, `quat`, `mat4` with operators | [std/math.md](std/math.md#the-built-in-types-vec2-vec3-vec4-quat-mat4) |
| math | scalar functions for `f32`/`f64`, vector / quaternion / matrix functions, geometry tests, easing, colour | [std/math.md](std/math.md) |
| rand | seedable generators, ranges, shuffles, noise | [std/rand.md](std/rand.md) |
| time | clocks, sleeping, frame clock, fixed timestep, timers | [std/time.md](std/time.md) |
| mem | sub-arenas, frame allocation, object pools with generational handles, ring buffers (regions themselves are core: [LANGUAGE.md](LANGUAGE.md#regions)) | [std/mem.md](std/mem.md) |

## Modules (`use std.<name>`)

| Module | What it gives | Links against | Reference |
|--------|---------------|---------------|-----------|
| `std.asset` | files, directories, per-user data and config directories, paths, cached asset loading, hot-reload polling, config and JSON readers | nothing | [std/asset.md](std/asset.md) |
| `std.os` | for tools and build scripts: run programs (status, captured output) or start them in the background (wait, kill), shared memory, process id, working directory; loads `std.asset` for files and directories | nothing | [std/os.md](std/os.md) |
| `std.image` | images, PNG and BMP load / save, inflate / deflate, CRC | nothing | [std/image.md](std/image.md) |
| `std.input` | per-frame key / mouse / gamepad state, action maps | nothing (Windows: `xinput1_4.dll` or `xinput9_1_0.dll`, loaded when a gamepad is opened) | [std/input.md](std/input.md) |
| `std.window` | windows, events, software presentation, native handles for GPU surfaces | `libX11.so.6`; Windows: `user32.dll`, `gdi32.dll` | [std/window.md](std/window.md) |
| `std.audio` | WAV, software mixer, sound device output | `libasound.so.2`; Windows: `ole32.dll` (WASAPI) (device only) | [std/audio.md](std/audio.md) |
| `std.wayland` | Wayland client bindings: libwayland-client, core / xdg-shell / xdg-decoration protocols, xkbcommon, cursor themes | `libwayland-client.so.0` (+ `libxkbcommon.so.0`, `libwayland-cursor.so.0`) | [std/wayland.md](std/wayland.md) |
| `std.vk` | Vulkan 1.0-1.3 bindings generated from `vk.xml` | `libvulkan.so.1` | [std/vk.md](std/vk.md) |
| `std.dx12` | Direct3D 12 / DXGI bindings generated from the mingw-w64 headers (Windows only) | `d3d12.dll`, `dxgi.dll`, `d3dcompiler_47.dll`, `user32.dll`, `kernel32.dll` | [std/dx12.md](std/dx12.md) |
| `std.metal` | Metal bindings over the Objective-C runtime (type-check only: no macOS backend yet) | macOS frameworks | [std/metal.md](std/metal.md) |
| `std.libc`, `std.x11`, `std.alsa` | raw C declarations used by the modules above | the named library | source in `std/` |

A program is a static, libc-free executable unless it reaches an `extern` function; then it is a
dynamically linked executable that needs only the libraries of the functions it can reach.
For example a game that uses `std.audio` only to mix into a buffer stays static.

Built with `--target windows` ([DETAILS.md](DETAILS.md#windows)), the core library and
`std.asset`, `std.os`, `std.image`, `std.input`, `std.window` and `std.audio` (its device
through WASAPI) work the same on Windows (the differences are in their pages). `std.wayland`,
`std.vk`, `std.libc`, `std.x11` and `std.alsa` use Linux interfaces: `use` of one of them is a
compile error that names the module and the target. `std.dx12` is the other way round:
Windows only (a Linux build stops at its Windows DLLs).

Graphics are bindings only: `std.vk` and `std.dx12` give the APIs, and the renderer (device
set-up, pipelines, sprite or mesh drawing) is the program's own code. The examples
(`examples/gamekit/dx12_gpu.al`, `examples/vk_triangle.al`) are reference code, not a library.

How to structure a game on top of these: [GAMES.md](GAMES.md).

Language fine print that few programs need (exact overloading and `priv` rules, bounds-check
placement, region limits, C interop, the grammar): [DETAILS.md](DETAILS.md).
