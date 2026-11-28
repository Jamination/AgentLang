# AL

AL is a small, statically typed language that compiles to native code in milliseconds.
`alc` is its compiler: one 6 MB executable with no LLVM, assembler, linker or libc behind it.

- **Fast to compile.** The compiler builds its own 68,000 lines in about 0.2 s unoptimised
  and 3 s optimised. Hello world builds in under 30 ms.
- **Fast to run.** On a par with `clang -O2` with bounds and division checks on: a geometric
  mean of 1.03 on ten classic benchmarks and 1.04 on 70 more, and 1.06 against Rust on the
  ten ([Performance](#performance)).
- **Simple memory.** Arenas and regions, reclaimed in bulk, with deep `clone` to move data
  out. No `free`, no garbage collector, no borrow checker ([the trade-offs](docs/MEMORY.md)).
- **Self-contained and reproducible.** The compiler is written in AL and reproduces itself
  byte for byte: the same source gives the same executable, on Linux and on Windows. It
  builds static Linux and Windows x86-64 binaries, and cross-compiles between the two.
- **Mistakes fail loudly.** `match` must be exhaustive, there are no implicit conversions or
  hidden captures, and run-time errors stop with a stack trace. What C leaves undefined is
  [defined](docs/SEMANTICS.md).
- **Small enough to hold in your head.** The whole reference is under 900 lines, which also
  makes AL easy for AI agents to write correctly: every diagnostic has a
  [stable code](docs/DIAGNOSTICS.md) and says what to write instead, and the CLI has
  machine-readable output throughout.

Each claim has a command that checks it:

| Claim | Check it with |
|---|---|
| Compiles its own source in a fraction of a second | `bash bench/compile.sh` |
| On a par with `clang -O2`; how it compares with gcc, C++ and Rust | `bash bench/run.sh -r 7`, `bash bench/wide/run.sh` |
| Reproduces itself byte for byte | `./build.sh` (fails unless stages 2 and 3 are identical) |
| No libc, no linker: a static executable | `alc build hello.al && file hello` |
| Everything it accepts, as one JSON object | `alc capabilities` |
| Every diagnostic has a code and a fix | `alc check --json -W file.al`, `alc explain E0301` |
| Use of released memory is found when a test runs it | `ALC_CHECK_MEMORY=1 ./program` |

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

Download the compiler from the [latest release](https://github.com/Jamination/AgentLang/releases/latest).
It is one executable with the standard library inside it; there is nothing else to install.

```
curl -L -o alc https://github.com/Jamination/AgentLang/releases/download/v0.5.0/alc-0.5.0-linux-x86_64
chmod +x alc
echo 'fn main() { print("hello") }' > hello.al
./alc run hello.al
```

On Windows, download `alc-0.5.0-windows-x86_64.exe`, rename it to `alc.exe` and run
`alc.exe run hello.al`. `SHA256SUMS` in the release lists the checksums of both.

### Building from source

Linux or Windows on x86-64 is the only requirement; the repository carries a seed compiler for
each. The compiler runs on both and builds for both (`--target linux|windows`), and, experimentally,
for arm64 Linux (`--target linux-arm64`, with C libraries through the Arm calling convention;
so far verified only under the project's own emulator, C calls against C compiled by clang,
never on arm64 hardware or with a real C library: see [docs/ARM64_TEST.md](docs/ARM64_TEST.md)),
and for macOS on Apple silicon (`--target macos`: Mach-O executables that have never run on a
Mac, checked structurally only: see [docs/MACOS_TEST.md](docs/MACOS_TEST.md)).

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
`./verify.sh` on Linux adds the comparisons with clang and the benchmarks. Run one of them
on the tree as it will be committed before every commit. More:
[BOOTSTRAP.md](docs/BOOTSTRAP.md#testing).

```
tests/run.sh                        # Linux: all tests;  tests/run.sh match: those named *match*
tests/run.sh --target windows       # Linux: the programs built for Windows, run under Wine
tests\run.bat                       :: Windows: all tests that apply to Windows
tests\run.bat -j 4 shaderc          :: Windows: those named *shaderc*, on 4 threads
verify.bat                          :: Windows: build.bat, the tests, VERIFY: PASS
```

| Command | |
|---|---|
| `alc build file.al` | compile to an executable (`-o path`, `-O0`, `--unchecked`, `-g` for debuggers and profilers: DWARF; on Windows also a `.pdb`) |
| `alc run file.al` | build and run |
| `alc test file.al` | run the file's `test` blocks (`--filter <pat>`, `--json`) |
| `alc check file.al` | type-check only (`--json` for machine-readable diagnostics; `-W` / `--deny-warnings` for lints) |
| `alc sigs file.al` | list declarations with the first line of their comments (`--std`, `--pub`, `--filter <pat>`, `--json`) |
| `alc fmt file.al dir/` | rewrite in the canonical layout (`--check`: list files that would change; `--stdout`, `-`, `--json`; `// alc fmt: off` .. `on`) |
| `alc lsp` | Language Server Protocol (LSP) server over stdio (diagnostics, hover, definition, references, completion, signature help, symbols, formatting) |
| `alc query <kind> <file[:l:c]>` | one-shot JSON semantic queries (`hover`, `def`, `refs`, `complete`, `symbols`) for terminal agents |
| `alc --version` / `--help` | the compiler's version and default target (`--json`) / command-line usage |

## Versions

Releases are tagged `vX.Y.Z` (the first is `v0.1.0`); [CHANGELOG.md](CHANGELOG.md) lists what
each one changes. A project pins the compiler it is written for:

```
git clone https://github.com/Jamination/AgentLang && cd AgentLang
git checkout v0.5.0 && ./build.sh
cp build/alc build/alc.exe ~/game/tools/       # or install on the PATH, below
```

On a machine shared by several projects, install each release beside the others and let
`alc` point at the default: `cp build/alc ~/.local/bin/alc-0.5.0 && ln -sfn alc-0.5.0
~/.local/bin/alc`. A project that must not change with a new release can call the versioned
name (`alc-0.5.0`); the [AGENTS.md template](docs/AGENTS_TEMPLATE.md) calls plain `alc`.

The standard library ships inside the compiler, so one executable is the whole toolchain;
`alc --version` names it. While the version is 0.x, a new minor version (0.2) may break
programs: the language, the run-time library and `std` can all change, and every such change
is listed under **Breaking** in the changelog with what to write instead. A patch version
(0.1.1) only fixes bugs and never breaks a program. To update, read the Breaking entries
between the two versions, then rebuild and run the project's tests with the new compiler.

## Documentation

- [Language reference](docs/LANGUAGE.md): everything needed to write programs, under 900 lines
- [The memory model and its trade-offs](docs/MEMORY.md): what arenas buy and cost, what is checked
- [Defined behaviour](docs/SEMANTICS.md): overflow, division, shifts, evaluation order, conversions
- [Diagnostics](docs/DIAGNOSTICS.md): the JSON form and every code
- [AL in one screen](docs/AGENT_CARD.md): the card a model loads before writing AL
- [Details](docs/DETAILS.md): fine print, read on demand (name resolution, grammar, C interop)
- [Standard library](docs/STDLIB.md): strings, collections, files, sockets, math, images, fonts, windows,
  input, audio, and bindings for Vulkan, Wayland, D3D12 and Metal
- [Structuring a game](docs/GAMES.md)
- [Testing on Windows](docs/WINDOWS_TEST.md): checks to run on a real Windows machine
- [Testing on arm64](docs/ARM64_TEST.md): checks to run on real arm64 Linux (or QEMU) for the experimental arm64 target
- [Testing on macOS](docs/MACOS_TEST.md): checks to run on Apple silicon for the experimental macOS target
- [AGENTS.md template](docs/AGENTS_TEMPLATE.md): for a new game repository written by agents
- [How the compiler is built and organised](docs/BOOTSTRAP.md)

## Examples

- `examples/hello.al`, `wordfreq.al`, `math_demo.al`, `image_demo.al`: small programs
- `examples/starter/`: a small space shooter rendered in software (procedural parallax nebula, pre-lit tumbling asteroids, explosions and particles, HUD text from a system font), the game structure of docs/GAMES.md (Linux and Windows)
- `examples/dx12_starter/`: the same game on Direct3D 12 used directly: procedural art, distance-field text from a system font, particle explosions, an HDR renderer with additive glow, bloom and a tone curve, WASAPI sound and music, keyboard and gamepad (Windows)
- `examples/dx12_breakout/`: neon breakout on its own Direct3D 12 renderer (procedural glass-brick sprite sheet, distance-field text, shader background, bloom, shatter effects), with title screen, pause menu, volumes and fullscreen (Windows)
- `examples/gamekit/`: parts the Direct3D 12 examples share (GPU set-up and a sprite batcher in `dx12_gpu.al`, screen, font, synthesizer, options); example code to copy, not a library
- `examples/dx12_crypt/`: a first-person 3D dungeon crawler on Direct3D 12: procedural stone, flagstone and wood materials with normal maps, per-pixel torch and lantern lighting with maze shadows and ambient occlusion, HDR bloom and tone mapping, mouse-look, gamepad, a scripted test mode and `--still` screenshots (Windows)
- `examples/font_demo.al`: a TrueType font: wrapped text drawn into an image and a glyph atlas
- `examples/dx12_triangle.al`, `vk_triangle.al`, `vk_renderer/`: a triangle with Direct3D 12 (Windows) / Vulkan (Linux), and a fuller Vulkan 1.3 renderer with compute, textures, depth and swapchain recreation
- `examples/wayland_window.al`, `win32_input.al`, `audio_tone.al`: a Wayland window, input events, a melody on the sound device

## Performance

The same algorithms and sizes in AL, C, C++ and Rust; all must print identical output. AL runs
with bounds and division checks enabled, Rust with its bounds checks. Each column is AL's time
divided by the other compiler's, so above 1 means AL is slower. Measured with AL 0.5.0 on Linux
x86-64 (Ryzen 5 3600: 6 cores, 12 threads, nothing pinned), best of 7 runs
(`bash bench/run.sh -r 7`).

| Benchmark | AL / clang -O2 | AL / gcc -O2 | AL / g++ -O2 | AL / rustc -O |
|---|---|---|---|---|
| nbody | 1.13 | 1.09 | 1.10 | 1.45 |
| spectralnorm | 1.01 | 1.51 | 1.48 | 1.01 |
| fannkuch | 1.12 | 1.18 | 1.19 | 1.40 |
| mandelbrot | 1.02 | 1.04 | 1.04 | 1.02 |
| binarytrees | 1.00 | 1.28 | 1.73 | 0.90 |
| sha256 | 0.98 | 0.95 | 0.96 | 0.95 |
| matmul | 0.97 | 0.98 | 0.98 | 0.93 |
| quicksort | 1.07 | 1.05 | 1.04 | 0.99 |
| sieve | 1.02 | 1.02 | 1.02 | 1.03 |
| hashmap | 1.05 | 1.01 | 1.02 | 1.04 |
| **geometric mean** | **1.03** | **1.10** | **1.14** | **1.06** |

clang 23.1.5, gcc 16.2.1 and rustc 1.99.0. A difference within 5 % is noise on this machine:
against clang, six of the ten are ties and four are slower. The ports are plain ones (safe Rust,
`std::vector` in C++); in binarytrees the Rust port indexes a `Vec` where C and AL use pointers.

Building these ten programs takes `alc` 0.38 s in total, clang 0.73 s, gcc 0.70 s, rustc 0.96 s
and g++ 2.6 s. They are small files, so this is mostly start-up cost; the compiler's own
source is the larger measure, below.

The scripts print the machine, refuse to record a run if other programs were using more than
half a core, and append each quiet run to `bench/history.tsv`, where the next run is compared
with it (`bench/lib.sh`).

`bench/wide` holds 70 more pairs in six areas that the ten above do not cover
(`bash bench/wide/run.sh`; best of 5; same machine; the full results are in
`bench/wide/linux.txt`. `baseline.txt` and `final.txt` are earlier runs on Windows: the
compiler before the work these benchmarks drove, and after it):

| Area | Pairs | AL / clang | AL / clang without its vectorizers |
|---|---|---|---|
| loops clang vectorizes | 13 | 1.02 | 0.62 |
| integer and bit manipulation | 10 | 1.04 | 1.05 |
| strings and text | 13 | 1.10 | 1.10 |
| calls and control flow | 11 | 1.15 | 1.12 |
| memory and data structures | 12 | 0.93 | 1.01 |
| floating point | 11 | 0.99 | 0.97 |
| **geometric mean** | **70** | **1.04** | **0.95** |

Of the 70, 10 are faster than clang by more than 5 %, 22 are within 5 % (a tie on this
machine) and 38 are slower; 20 are more than 15 % slower.
The slowest are a u8 box blur (2.6, clang narrows its arithmetic to 16-bit lanes), a lexer
state machine with many branches (1.7), a clamp/abs/select loop that is not vectorized (1.4)
and mutual recursion (1.4); a byte sum that only AL vectorizes is at 0.17 and lifts the first
row (the mean of the other 69 is 1.06). The loop vectorizer is x86-64 only (SSE2).

The compiler compiles its own 68,000 lines in about 0.2 s without optimisation (about 350,000 lines/s) and 2.9 s with optimisation (same machine, 6 cores and 12 threads, best of 7: `bash bench/compile.sh`), compiling functions in parallel worker threads on Linux and Windows (`ALC_JOBS=n` sets the number).

## Repository

| Path | Contents |
|---|---|
| `src/` | the compiler: front end, SSA optimizer (`opt/`), x86-64 back end (`x86/`), experimental arm64 back end (`arm64/`), ELF linker, and the run-time library (`prelude.al`) |
| `std/` | standard library modules (`use std.<name>`) |
| `bootstrap/alc`, `bootstrap/alc.exe` | seed compilers that `build.sh` (Linux) and `build.bat` (Windows) start from |
| `examples/`, `bench/` | sample programs; the benchmarks in AL and C (`bench/wide`: 70 more pairs, with their harness) |
| `tests/` | conformance suite (`tests/run.sh`, `tests\run.bat`; the runner is `tests/run.al`) and fuzzers (`tests/gen/`) |
| `verify.sh`, `verify.bat` | everything: self-compilation to a fixed point, tests, benchmarks (Linux); build and tests (Windows) |
| `CHANGELOG.md` | changes per release; [Versions](#versions) |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

## Acknowledgements

This software is based in part on the work of the Independent JPEG Group: the JPEG code of
`std.image` (`std/image_jpeg.al`) follows the algorithms of libjpeg. A program built with it
that uses JPEG carries the same sentence in its documentation ([std/image.md](docs/std/image.md)).
