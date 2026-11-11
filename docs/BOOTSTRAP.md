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
| `src/base.al` | helpers for compiler code: `Opt`, Vec / Map conveniences, environment, processes, the working-memory regions |
| `src/lexer.al`, `parser.al`, `ast.al` | front end |
| `src/priv.al` | file-private declarations: renames them right after a file is parsed |
| `src/types.al`, `lower*.al` | type checking fused with lowering to SSA IR: `lower.al` (declarations, instantiation), `lower_fn.al`, `lower_expr.al`, `lower_call.al`, `lower_vec.al` (vector / matrix types), `lower_mem.al` (builtin names shared with declared functions, `Vec` indexing, `clone`), `lower_nested.al` (nested functions) |
| `src/lint.al` | checks on the AST that need types: field writes to a struct copy that is never read |
| `src/ir.al` | IR, dominators, loops, printer, verifier |
| `src/opt/*.al` | optimiser passes; `mod.al` is the pipeline |
| `src/x86/*.al` | instruction selection, register allocation, encoder; `mod.al` is the backend driver |
| `src/elf.al` | ELF writer |
| `src/prelude.al` | the run-time library of every AL program (embedded into the compiler) |

Naming: a function `f` of file `m.al` is `m_f` (`gvn_run`, `elf_link`); functions that act on
a type take it as first parameter and are called as methods (`f.rpo()`, `cx.resolve(..)`);
enum variants carry the enum name (`OpAdd`, `TermJmp`): the sources were written when variants
were global names, and keep them until the seed compiler knows qualified variants.

## Memory

AL programs allocate from an arena and never free. The compiler would need gigabytes that
way, because every pass builds tables it throws away. Besides the main arena it therefore
uses two prelude regions (`Region` with `enter` / `leave` / `reset`, see the language
reference; `src/base.al`):

- the **main arena** for what lives to the end (AST, types, the module, machine code);
- the **work region** for one function being optimised or compiled: `work_begin()` enters it
  and `work_end()` leaves and resets it, in `opt_optimize` and `x86_compile`. The function (or
  its machine code) is deep-copied to the main arena with `clone` right after `work_end()`:
  the discarded memory stays readable until the next `work_begin()`. `work_pause()` /
  `work_resume()` switch to the main arena for a moment, for results that must stay;
- the **scratch region** for tables that a pass rebuilds on every round of a loop
  (`scratch_on()` / `scratch_off()` bracket their construction, `scratch_reset()` at the top
  of the next round discards them; used in `src/opt/simplify.al`). Nothing reachable from
  the function may be allocated between `scratch_on()` and `scratch_off()`.

Compiling the compiler (about 29,000 lines) takes about 3.5 s and 0.6 GB.
`ALC_DEBUG=mem` prints memory and time after each phase.

## Notes on language features

- **`priv`** (`src/priv.al`). Right after a file is parsed, `priv_apply` renames each private
  declaration to `name` + byte 1 + the file's index (a spelling that cannot occur in source),
  in the declaration and in every identifier of that spelling in the file, including local
  declarations; field names, field labels and variant names are left alone. The rest of the
  compiler works on one flat namespace. Places that know about internal names: `ast_plain`,
  `ast_is_private`, `ast_plain_text` (`src/ast.al`; every diagnostic and `alc sigs` line passes
  through `ast_plain_text`), `inst_struct` / `inst_enum` / `inst_fn` / `global` and
  `fn_candidates` (`src/lower.al`: plain names for output, public candidates appended to the
  private ones), `call_overloaded` (`src/lower_call.al`: drops public candidates when a
  private one fits), and `priv_hint` (the "is declared `priv` in ..." hint). A new kind of
  declaration becomes private-capable with one case in `parser_set_priv` and one in
  `priv_decl_info` / `priv_rewrite`.
- **Nested and anonymous functions** (`src/lower_nested.al`). `name :: (..) { }` inside a
  block is the statement `SKFn`, `(..) { }` the expression `EKFn` (a `FnDecl` with an empty
  name). Both become ordinary IR functions `outer.name` / `outer.fn@line:col`, lowered where
  they are written by `lower_fn_lower_body` with the type environment of the enclosing
  function (so once per instantiation of it); `Fx.nested_done` makes a declaration that is
  lowered again (a `defer` block on another way out) reuse the same function. The name lives
  in the block's scope next to the variables (`Scope.vars`, with a negative type slot that
  indexes `Cx.nested`). The `Fx` of the body has the enclosing one as `parent`: `lookup`
  continues there, finds nested functions, and reports a variable as `LOWER_NESTED_OUTER`,
  which is the "does not see the variables of the function around it" error. There is no
  capture and no environment: calls go through `call_fn` like calls of top-level functions,
  and the value is `OpFAddr`.
- **Copy-write check** (`src/lint.al`). `lint_copy_writes` runs per `:=` statement while a
  function is lowered (it needs the type of the initialiser) and counts, in the rest of the
  block, direct field assignments to the new name against every other occurrence of it.

## Debugging switches

`ALC_DEBUG=verify` (IR verifier between passes), `trace`, `mir`, `unroll`, `mem`;
`ALC_DISABLE=pass,...` (`unroll`, `bce`, `licm`, `gvn`, `loadelim`, `checkmerge`, `tre`,
`partial`, `thread4`, `thread5`, `ifconv`); `ALC_STD_DIR=<dir>` reads bundled modules from
`<dir>` instead of the copies inside the compiler; `ALC_ALIGN=1` aligns inner loops.
