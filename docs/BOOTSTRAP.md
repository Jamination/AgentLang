# How the compiler is built

`alc` is written in AL and compiles itself. There is no other implementation language in the
repository and no build tool besides `alc`.

```
./build.sh            # seed -> stage 1 -> stage 2 -> stage 3, installs build/alc
./build.sh --quick    # seed -> build/alc only
./build.sh --reseed   # full build, then replace the seed with the result
```

| Stage | Built by | From | Purpose |
|-------|----------|------|---------|
| seed | (committed) `bootstrap/alc` | an earlier state of `src/` | any compiler good enough to compile the current sources |
| 1 | seed | `src/main.al` | the current compiler, compiled by the old one |
| 2 | stage 1 | `src/main.al` | the current compiler, compiled by itself |
| 3 | stage 2 | `src/main.al` | must be byte-identical to stage 2 |

The comparison of stages 2 and 3 is the self-check: a compiler that miscompiles itself in a
way that changes its behaviour produces a different stage 3. `build/alc` is stage 2.
`verify.sh` runs the full build first and tests `build/alc`.

The seed is a static x86-64 Linux executable of about 2.8 MB. It only has to be replaced
(`--reseed`, then commit `bootstrap/alc`) when the sources start to use a language feature
the seed does not know; add the feature, build, reseed, then use it. `ALC_SEED=/path/to/alc`
selects another seed.

## History

The compiler was first written in Rust (the last such state is tagged `rust-final` in git) and
then translated to AL file by file with the same algorithms. Before the Rust version was
removed, both compilers were compared: byte-identical output for every program in `tests/`,
`bench/` and `examples/` in all three build modes, for the compiler's own source, and for
1000 random programs; identical diagnostics for every program in `tests/fail/`.

## Sources

| Path | Contents |
|------|----------|
| `src/main.al` | driver: arguments, source loading, bundled modules, diagnostics output; lists every other file |
| `src/base.al` | helpers for compiler code: `Opt`, Vec / Map conveniences, environment, processes, the three heaps |
| `src/lexer.al`, `parser.al`, `ast.al` | front end |
| `src/types.al`, `lower*.al` | type checking fused with lowering to SSA IR |
| `src/ir.al` | IR, dominators, loops, printer, verifier |
| `src/opt/*.al` | optimiser passes; `mod.al` is the pipeline |
| `src/x86/*.al` | instruction selection, register allocation, encoder; `mod.al` is the backend driver |
| `src/elf.al` | ELF writer |
| `src/prelude.al` | the run-time library of every AL program (embedded into the compiler) |

Naming: a function `f` of file `m.al` is `m_f` (`gvn_run`, `elf_link`); functions that act on
a type take it as first parameter and are called as methods (`f.rpo()`, `cx.resolve(..)`);
enum variants carry the enum name (`OpAdd`, `TermJmp`), because variants are global.

## Memory

AL programs allocate from an arena and never free. The compiler would need gigabytes that
way, because every pass builds tables it throws away. It therefore uses three heaps
(`src/base.al`):

- the **main heap** for what lives to the end (AST, types, the module, machine code);
- the **work heap** for one function being optimised or compiled: `work_begin()` ..
  `work_end()` in `opt_optimize` and `x86_compile`; the function (or its machine code) is
  deep-copied to the main heap afterwards and the work heap is emptied;
- the **scratch heap** for tables that a pass rebuilds on every round of a loop
  (`scratch_on()` / `scratch_off()` / `scratch_reset()` in `simplify_cfg`).

Compiling the compiler (about 23,000 lines) takes about 2.8 s and 1.1 GB.
`ALC_DEBUG=mem` prints memory and time after each phase.

## Debugging switches

`ALC_DEBUG=verify` (IR verifier between passes), `trace`, `mir`, `unroll`, `mem`;
`ALC_DISABLE=pass,...` (`unroll`, `bce`, `licm`, `gvn`, `loadelim`, `checkmerge`, `tre`,
`partial`, `thread4`, `thread5`, `ifconv`); `ALC_STD_DIR=<dir>` reads bundled modules from
`<dir>` instead of the copies inside the compiler; `ALC_ALIGN=1` aligns inner loops.
