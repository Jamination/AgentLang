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

Linux on x86-64 is the only requirement; the repository carries a seed compiler. The compiler
runs on Linux and Windows (`build/alc.exe`), and builds for both (`--target linux|windows`).

```
./build.sh                          # the compiler compiles itself -> build/alc
./build/alc run examples/hello.al
```

| Command | |
|---|---|
| `alc build file.al` | compile to an executable (`-o path`, `-O0`, `--unchecked`) |
| `alc run file.al` | build and run |
| `alc test file.al` | run the file's `test` blocks |
| `alc check file.al` | type-check only (`--json` for machine-readable diagnostics) |
| `alc sigs file.al` | list declarations (`-- std` adds the standard library) |

## Documentation

- [Language reference](docs/LANGUAGE.md): everything needed to write programs, under 900 lines
- [Details](docs/DETAILS.md): fine print, read on demand (name resolution, grammar, C interop)
- [Standard library](docs/STDLIB.md): strings, collections, files, math, images, windows,
  input, audio, and bindings for Vulkan, Wayland, D3D12 and Metal
- [Structuring a game](docs/GAMES.md)
- [How the compiler is built and organised](docs/BOOTSTRAP.md)

## Examples

- `examples/hello.al`, `wordfreq.al`, `math_demo.al`, `image_demo.al`: small programs
- `examples/starter/`: a small shooter in software rendering, the game structure of docs/GAMES.md (Linux and Windows)
- `examples/dx12_starter/`: the same game with Direct3D 12 sprites, WASAPI sound and music, keyboard and gamepad (Windows)
- `examples/dx12_breakout/`: breakout with a title screen, pause menu, volumes, fullscreen and a bitmap font (Windows)
- `examples/gamekit/`: the parts both Direct3D 12 games share (screen, font, synthesizer, options)
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

The compiler compiles its own 34,000 lines in about 0.12 s without optimisation (about 280,000 lines/s) and 0.86 s with optimisation (`bench/compile.sh`), compiling functions in parallel worker processes (`ALC_JOBS=n` sets the number).

## Repository

| Path | Contents |
|---|---|
| `src/` | the compiler: front end, SSA optimizer (`opt/`), x86-64 back end (`x86/`), ELF linker, and the run-time library (`prelude.al`) |
| `std/` | standard library modules (`use std.<name>`) |
| `bootstrap/alc` | seed compiler that `build.sh` starts from |
| `examples/`, `bench/` | sample programs; the benchmarks in AL and C |
| `tests/` | conformance suite (`tests/run.sh`) and fuzzers (`tests/gen/`) |
| `verify.sh` | everything: self-compilation to a fixed point, tests, benchmarks |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
