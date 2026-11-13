# AL standard library

Everything here ships inside the compiler: there is nothing to install and no search path.
`alc sigs file.al -- std` lists every declaration that a program can see (internal helpers that
are `priv` do not appear: a program may reuse their names).

## Always available (no `use`)

| Part | What it gives | Reference |
|------|---------------|-----------|
| core | printing (`print`, `eprint`), `Vec`, `Map` (insertion-ordered), strings, number formatting and parsing, sorting, `Opt`, file I/O with `io_error()`, `args`, `env_get`, arena memory and regions, `clone`: every signature with its edge cases | [LANGUAGE.md](LANGUAGE.md#standard-library) |
| built-in types | `f32`, `vec2 vec3 vec4`, `quat`, `mat4` with operators | [std/math.md](std/math.md#the-built-in-types-f32-vec2-vec3-vec4-quat-mat4) |
| math | scalar functions for `f32`/`f64`, vector / quaternion / matrix functions, geometry tests, easing, colour | [std/math.md](std/math.md) |
| rand | seedable generators, ranges, shuffles, noise | [std/rand.md](std/rand.md) |
| time | clocks, sleeping, frame clock, fixed timestep, timers | [std/time.md](std/time.md) |
| mem | sub-arenas, frame allocation, object pools with generational handles, ring buffers (regions themselves are core: [LANGUAGE.md](LANGUAGE.md#regions)) | [std/mem.md](std/mem.md) |

## Modules (`use std.<name>`)

| Module | What it gives | Links against | Reference |
|--------|---------------|---------------|-----------|
| `std.asset` | files, directories, paths, cached asset loading, hot-reload polling, config and JSON readers | nothing | [std/asset.md](std/asset.md) |
| `std.os` | for tools and build scripts: run programs (status, captured output) or start them in the background (wait, kill), shared memory, process id, working directory; loads `std.asset` for files and directories | nothing | [std/os.md](std/os.md) |
| `std.image` | images, PNG and BMP load / save, inflate / deflate, CRC | nothing | [std/image.md](std/image.md) |
| `std.input` | per-frame key / mouse state, action maps | nothing | [std/input.md](std/input.md) |
| `std.window` | windows, events, software presentation, native handles for GPU surfaces | `libX11.so.6` | [std/window.md](std/window.md) |
| `std.audio` | WAV, software mixer, sound device output | `libasound.so.2`; Windows: `ole32.dll` (WASAPI) (device only) | [std/audio.md](std/audio.md) |
| `std.wayland` | Wayland client bindings: libwayland-client, core / xdg-shell / xdg-decoration protocols, xkbcommon, cursor themes | `libwayland-client.so.0` (+ `libxkbcommon.so.0`, `libwayland-cursor.so.0`) | [std/wayland.md](std/wayland.md) |
| `std.vk` | Vulkan 1.0-1.3 bindings generated from `vk.xml` | `libvulkan.so.1` | [std/vk.md](std/vk.md) |
| `std.dx12` | Direct3D 12 / DXGI bindings (type-check only: no Windows backend yet) | Windows DLLs | [std/dx12.md](std/dx12.md) |
| `std.metal` | Metal bindings over the Objective-C runtime (type-check only: no macOS backend yet) | macOS frameworks | [std/metal.md](std/metal.md) |
| `std.libc`, `std.x11`, `std.alsa` | raw C declarations used by the modules above | the named library | source in `std/` |

A program is a static, libc-free executable unless it reaches an `extern` function; then it is a
dynamically linked executable that needs only the libraries of the functions it can reach.
For example a game that uses `std.audio` only to mix into a buffer stays static.

Built with `--target windows` ([DETAILS.md](DETAILS.md#windows)), the core library and
`std.asset`, `std.os`, `std.image` and `std.audio` (its device through WASAPI) work the same on
Windows (the differences are in their pages). `std.input`, `std.window`, `std.wayland`,
`std.vk`, `std.libc`, `std.x11` and `std.alsa` use Linux interfaces: `use` of one of them is a
compile error that names the module and the target.

How to structure a game on top of these: [GAMES.md](GAMES.md).

Language fine print that few programs need (exact overloading and `priv` rules, bounds-check
placement, region limits, C interop, the grammar): [DETAILS.md](DETAILS.md).
