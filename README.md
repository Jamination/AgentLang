# AL — a language for agents, with its own optimizing native compiler

AL is a small statically typed language designed to be written by AI agents, and `alc` is its
compiler: Rust, standard library only, no LLVM. It does its own optimization, instruction
selection, register allocation, x86-64 encoding and ELF linking, and emits static Linux
executables that use raw system calls (no libc, no dynamic loader).

- Language reference: [docs/LANGUAGE.md](docs/LANGUAGE.md)
- Verification (build + conformance tests + benchmarks against `clang -O2`): `./verify.sh`

```
cargo build --release
./target/release/alc run examples/hello.al
./target/release/alc test tests/unit/basic.al
./target/release/alc sigs bench/hashmap.al
```

## Layout

| Path | Contents |
|------|----------|
| `src/lexer.rs`, `parser.rs`, `ast.rs` | front end |
| `src/types.rs`, `lower*.rs` | type checking fused with lowering to SSA IR |
| `src/ir.rs` | SSA IR, dominators, loop analysis |
| `src/opt/` | mem2reg/SROA, simplifier (const folding, strength reduction, magic-number division, CFG cleanup, jump threading), GVN with condition propagation, load/store elimination, LICM, inlining, full and partial loop unrolling, bounds-check hoisting and merging |
| `src/x86/` | instruction selection (addressing modes, load folding, compare/branch fusion), graph-colouring register allocation with coalescing, peepholes, encoder with branch relaxation |
| `src/elf.rs` | static ELF writer / linker |
| `src/prelude.al` | runtime and standard library, written in AL |
| `tests/` | conformance suite (`tests/run.sh`) |
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
