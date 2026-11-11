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

Linux on x86-64 is the only requirement; the repository carries a seed compiler.

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

- [Language reference](docs/LANGUAGE.md)
- [Standard library](docs/STDLIB.md): strings, collections, files, math, images, windows,
  input, audio, and bindings for Vulkan, D3D12 and Metal
- [Structuring a game](docs/GAMES.md)
- [How the compiler is built and organised](docs/BOOTSTRAP.md)

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

The compiler compiles its own 30,000 lines in about 4 seconds.

## Repository

| Path | Contents |
|---|---|
| `src/` | the compiler: front end, SSA optimizer (`opt/`), x86-64 back end (`x86/`), ELF linker, and the run-time library (`prelude.al`) |
| `std/` | standard library modules (`use std.<name>`) |
| `bootstrap/alc` | seed compiler that `build.sh` starts from |
| `examples/`, `bench/` | sample programs; the benchmarks in AL and C |
| `tests/` | conformance suite (`tests/run.sh`) and fuzzers (`tests/gen/`) |
| `verify.sh` | everything: self-compilation to a fixed point, tests, benchmarks |
