# AL — a language for agents, with its own optimizing native compiler

AL is a small statically typed language designed to be written by AI agents, and `alc` is its
compiler, written in AL itself: it compiles its own source and reproduces itself byte for
byte. No LLVM, no assembler, no linker, no libc: it does its own optimization, instruction
selection, register allocation, x86-64 encoding and ELF linking. Programs are static Linux
executables that use raw system calls; a program that calls C functions (`extern`) is linked
dynamically against exactly the libraries it reaches.

It is meant for high-performance software such as games: `f32`, vectors, quaternions and
matrices are built-in types compiled to SSE code, functions overload on argument types, and a
game-oriented standard library ships inside the compiler. The language has generics, enums
with data and `match`, nested and anonymous functions (plain function values, no captures), file-private
declarations (`priv`), type aliases, and arena memory with regions and deep `clone` instead
of `free` or a garbage collector.

- Language reference: [docs/LANGUAGE.md](docs/LANGUAGE.md)
- Standard library: [docs/STDLIB.md](docs/STDLIB.md); structuring a game: [docs/GAMES.md](docs/GAMES.md)
- How the compiler is built and organised: [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)
- Verification (self-compilation, conformance and library tests, `f32` semantics against clang, the
  Vulkan triangle, benchmarks against `clang -O2`): `./verify.sh`

```
./build.sh                               # the compiler compiles itself -> build/alc
./build/alc run examples/hello.al
./build/alc test tests/unit/basic.al
./build/alc sigs bench/hashmap.al
```

## Layout

| Path | Contents |
|------|----------|
| `build.sh`, `bootstrap/alc` | self-hosted build and its seed compiler |
| `src/main.al`, `base.al` | driver; helpers shared by the compiler sources |
| `src/lexer.al`, `parser.al`, `ast.al`, `priv.al` | front end; file-private names |
| `src/types.al`, `lower*.al`, `lint.al` | type checking fused with lowering to SSA IR (`lower_nested.al`: nested functions, `lower_mem.al`: `Vec` indexing, `clone`) |
| `src/ir.al` | SSA IR, dominators, loop analysis |
| `src/opt/` | mem2reg/SROA, simplifier (const folding, strength reduction, magic-number division, CFG cleanup, jump threading, if-conversion), GVN with condition propagation, load/store elimination, LICM, inlining, tail-recursion elimination, full and partial loop unrolling, bounds-check hoisting and merging |
| `src/x86/` | instruction selection (addressing modes, load folding, compare/branch fusion), graph-colouring register allocation with coalescing, peepholes, encoder with branch relaxation |
| `src/lower_vec.al` | lowering of the built-in vector / matrix types |
| `src/elf.al` | ELF writer / linker (static, or dynamic when C libraries are used) |
| `src/prelude.al` | runtime and core library, written in AL |
| `std/` | bundled modules (`use std.<name>`) and the always-loaded math / rand / time / mem |
| `tools/` | binding generators (`gen_vk.py` from `vk.xml`, `gen_dx12.py` from the D3D12 headers) |
| `tests/` | conformance suite (`tests/run.sh`): `run`, `std`, `sys`, `check`, `fail`, `unit`, `c` |
| `bench/` | the ten benchmarks in AL and C (`bench/run.sh` for quick timing) |

## Compiler pipeline

```mermaid
flowchart LR
  A[source .al + prelude] --> B[lexer / parser]
  B --> C[type check + lower to SSA IR]
  C --> D[mem2reg, simplify, GVN, load elim, LICM]
  D --> E[inline bottom-up]
  E --> F[unroll, bounds-check hoisting]
  F --> G[instruction selection]
  G --> H[register allocation]
  H --> I[peephole + encode]
  I --> J[ELF link]
```

## Testing

- `tests/run.sh` — conformance suite: programs in `tests/run` are built three ways (default,
  `-O0`, `--unchecked`) and must print the expected output; `tests/fail` holds programs that
  must be rejected with given diagnostics; `tests/unit` exercises `alc test`.
- `tests/gen/fuzz.py [count] [seed]` — differential fuzzer: random programs must behave the same
  unoptimized, optimized and unchecked, and the optimizer's IR must pass the verifier after every
  pass (`ALC_DEBUG=verify`).
- `tests/gen/fuzz_vec.py [count] [seed]` — the same for `f32` / vector / matrix code.
- `tests/gen/fuzz_nested.py [count] [seed]` — programs made of nested and anonymous functions, with expected
  output computed by the generator.
- `tests/gen/divconst.py` regenerates the division-by-constant stress test.
- `ALC_DISABLE=pass,...` switches optimization passes off (`unroll`, `bce`, `licm`, `gvn`,
  `loadelim`, `checkmerge`, `tre`, `partial`, `thread4`, `thread5`) for bisecting.

## Benchmarks

`./verify.sh` builds each benchmark with `clang -O2` and with `alc` (default mode: bounds and
division checks **enabled**), requires byte-identical output, and compares the best of 7 runs.
Both sides use the same algorithms and problem sizes; `binarytrees` uses a bump arena on both
sides so that the comparison measures generated code rather than `malloc`.
