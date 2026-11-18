# AL

AL is a small, statically typed, compiled language designed to be written by AI agents.
`alc` is its compiler.

- **One small language.** The whole reference fits in an agent's context. There is usually one
  way to write something, and diagnostics say what to write instead.
- **Mistakes fail at compile time or loudly at run time.** Bounds and division checks are on by
  default, `match` must be exhaustive, and there are no hidden captures or implicit conversions.
- **Fast.** Native code within about 6% of `clang -O2` on the benchmark set, with checks on.
- **Self-contained.** The compiler is written in AL and compiles itself. It has no dependency on
  LLVM, an assembler, a linker or libc: one 3 MB executable turns source into a static Linux
  x86-64 binary in milliseconds.
- **Simple memory.** Arena allocation with regions and deep `clone`; no `free`, no garbage
  collector, no borrow checker.

```
enum Shape { Circle(f64), Rect(f64, f64) }

fn area(s: Shape) -> f64 {
    match s {
        Circle(r) => 3.14159 * r * r
        Rect(w, h) => w * h
    }
}

fn main() {
    shapes := []Shape{Circle(1.0), Rect(2.0, 3.0), Circle(0.5)}
    sort_by(shapes, fn(a: Shape, b: Shape) -> bool { area(a) > area(b) })
    for s in shapes {
        print(s, area(s))
    }
}
```

## Getting started

Linux or Windows on x86-64 is the only requirement; the repository carries a seed compiler for
each. The compiler runs on both and builds for both (`--target linux|windows`), and, experimentally,
for arm64 Linux (`--target linux-arm64`, with C libraries through the Arm calling convention;
so far verified only under the project's own emulator, C calls against C compiled by clang,
never on arm64 hardware or with a real C library: see [docs/ARM64_TEST.md](docs/ARM64_TEST.md)).

```
./build.sh                          # Linux: the compiler compiles itself -> build/alc (and build/alc.exe)
./build/alc run examples/hello.al
```

```
build.bat                           :: Windows: the same -> build\alc.exe (and build\alc)
build\alc.exe run examples\hello.al
```

The tests run on both systems: `tests/run.sh` (Linux) and `tests\run.bat` (Windows) start the
same runner, an AL program (`tests/run.al`) that runs the tests in parallel and ends with
`conformance: N passed, M failed, K skipped`. On Windows the programs run directly; the few
tests that need a C compiler (MinGW-w64) are skipped with that reason when it is not installed.
`verify.bat` is the whole check there (build, tests, one line `VERIFY: PASS` or `VERIFY: FAIL`);
`./verify.sh` on Linux adds the comparisons with clang and the benchmarks. More:
[BOOTSTRAP.md](docs/BOOTSTRAP.md#testing).

```
tests/run.sh                        # Linux: all tests;  tests/run.sh ./build/alc match: those named *match*
tests/run.sh --target windows       # Linux: the programs built for Windows, run under Wine
tests\run.bat                       :: Windows: all tests that apply to Windows
verify.bat                          :: Windows: build.bat, the tests, VERIFY: PASS
```

| Command | |
|---|---|
| `alc build file.al` | compile to an executable (`-o path`, `-O0`, `--unchecked`, `-g` for debuggers and profilers: DWARF; on Windows also a `.pdb`) |
| `alc run file.al` | build and run |
| `alc test file.al` | run the file's `test` blocks |
| `alc check file.al` | type-check only (`--json` for machine-readable diagnostics) |
| `alc sigs file.al` | list declarations (`-- std` adds the standard library) |
| `alc fmt file.al dir/` | rewrite in the canonical layout (`--check`: list files that would change; `--stdout`, `-`) |
| `alc --version` | the compiler's version and default target |

## Versions

Releases are tagged `vX.Y.Z` (the first is `v0.1.0`); [CHANGELOG.md](CHANGELOG.md) lists what
each one changes. A project pins the compiler it is written for:

```
git clone https://github.com/Jamination/AgentLang && cd AgentLang
git checkout v0.4.0 && ./build.sh
cp build/alc build/alc.exe ~/game/tools/       # or install on the PATH, below
```

On a machine shared by several projects, install each release beside the others and let
`alc` point at the default: `cp build/alc ~/.local/bin/alc-0.4.0 && ln -sfn alc-0.4.0
~/.local/bin/alc`. A project that must not change with a new release can call the versioned
name (`alc-0.4.0`); the [AGENTS.md template](docs/AGENTS_TEMPLATE.md) calls plain `alc`.

The standard library ships inside the compiler, so one executable is the whole toolchain;
`alc --version` names it. While the version is 0.x, a new minor version (0.2) may break
programs: the language, the run-time library and `std` can all change, and every such change
is listed under **Breaking** in the changelog with what to write instead. A patch version
(0.1.1) only fixes bugs and never breaks a program. To update, read the Breaking entries
between the two versions, then rebuild and run the project's tests with the new compiler.

## Documentation

- [Language reference](docs/LANGUAGE.md): everything needed to write programs, under 900 lines
- [Details](docs/DETAILS.md): fine print, read on demand (name resolution, grammar, C interop)
- [Standard library](docs/STDLIB.md): strings, collections, files, sockets, math, images, fonts, windows,
  input, audio, a 2D renderer with text, and bindings for Vulkan, Wayland, D3D12 and Metal
- [Structuring a game](docs/GAMES.md)
- [Testing on Windows](docs/WINDOWS_TEST.md): checks to run on a real Windows machine
- [Testing on arm64](docs/ARM64_TEST.md): checks to run on real arm64 Linux (or QEMU) for the experimental arm64 target
- [AGENTS.md template](docs/AGENTS_TEMPLATE.md): for a new game repository written by agents
- [How the compiler is built and organised](docs/BOOTSTRAP.md)

## Examples

- `examples/hello.al`, `wordfreq.al`, `math_demo.al`, `image_demo.al`: small programs
- `examples/starter/`: a small shooter in software rendering, the game structure of docs/GAMES.md (Linux and Windows)
- `examples/dx12_starter/`: the same game with Direct3D 12 sprites, WASAPI sound and music, keyboard and gamepad (Windows)
- `examples/dx12_breakout/`: breakout with a title screen, pause menu, volumes, fullscreen and a bitmap font (Windows)
- `examples/gamekit/`: the parts both Direct3D 12 games share (GPU set-up and sprite batcher in `dx12_gpu.al`, screen, font, synthesizer, options); example code to copy, not a library
- `examples/gfx_starter/`: the starter game on std.gfx, its text in a TrueType font with std.gfx_text (Linux and Windows)
- `examples/dx12_crypt/`: a first-person 3D maze with Direct3D 12, mouse-look, gamepad and a scripted test mode (Windows)
- `examples/font_demo.al`: a TrueType font: wrapped text drawn into an image and a glyph atlas
- `examples/dx12_triangle.al`, `vk_triangle.al`: a triangle with Direct3D 12 (Windows) / Vulkan (Linux)
- `examples/wayland_window.al`, `win32_input.al`, `audio_tone.al`: a Wayland window, input events, a melody on the sound device

## Performance

Best of 7 runs against `clang -O2`, same algorithms and sizes, identical output required. AL
runs with bounds and division checks enabled.

| Benchmark | AL / clang |
|---|---|
| nbody | 1.26 |
| spectralnorm | 1.01 |
| fannkuch | 1.15 |
| mandelbrot | 1.02 |
| binarytrees | 0.97 |
| sha256 | 1.07 |
| matmul | 1.01 |
| quicksort | 1.05 |
| sieve | 1.02 |
| hashmap | 1.11 |
| **geometric mean** | **1.06** |

The compiler compiles its own 40,000 lines in about 0.125 s without optimisation (about 320,000 lines/s) and 0.91 s with optimisation (`bench/compile.sh`), compiling functions in parallel worker threads on Linux and Windows (`ALC_JOBS=n` sets the number).

## Repository

| Path | Contents |
|---|---|
| `src/` | the compiler: front end, SSA optimizer (`opt/`), x86-64 back end (`x86/`), experimental arm64 back end (`arm64/`), ELF linker, and the run-time library (`prelude.al`) |
| `std/` | standard library modules (`use std.<name>`) |
| `bootstrap/alc`, `bootstrap/alc.exe` | seed compilers that `build.sh` (Linux) and `build.bat` (Windows) start from |
| `examples/`, `bench/` | sample programs; the benchmarks in AL and C |
| `tests/` | conformance suite (`tests/run.sh`, `tests\run.bat`; the runner is `tests/run.al`) and fuzzers (`tests/gen/`) |
| `verify.sh`, `verify.bat` | everything: self-compilation to a fixed point, tests, benchmarks (Linux); build and tests (Windows) |
| `CHANGELOG.md` | changes per release; [Versions](#versions) |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
