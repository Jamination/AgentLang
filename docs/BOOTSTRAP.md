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

The translation was done before AL had file-private names, per-enum variant namespaces,
nested patterns and guards, a builtin `clone`, `embed` in constants and `v[i]` on a `Vec`, so
the first AL sources prefixed every function with its file and every variant with its enum,
nested their matches and copied by hand. Those workarounds were removed afterwards in one
pass over the sources (27,500 lines became 25,400; the compiler produced byte-identical
executables before and after); the conventions below describe the result.

## Sources

| Path | Contents |
|------|----------|
| `src/main.al` | driver: arguments, source loading, bundled modules, diagnostics output; lists every other file |
| `src/base.al` | helpers for compiler code: Vec constructors (`vec_one`, `vec_two`; `vec_of` and `vec_fill` are library functions), processes, the working-memory regions |
| `src/lexer.al`, `parser.al`, `ast.al` | front end |
| `src/priv.al` | file-private declarations: renames them right after a file is parsed |
| `src/types.al`, `lower*.al` | type checking fused with lowering to SSA IR: `lower.al` (declarations, instantiation), `lower_fn.al`, `lower_expr.al`, `lower_call.al`, `lower_vec.al` (vector / matrix types), `lower_mem.al` (builtin names shared with declared functions, `Vec` indexing, `clone`), `lower_nested.al` (nested functions) |
| `src/lint.al` | checks on the AST that need types: field writes to a struct copy that is never read |
| `src/ir.al` | IR, dominators, loops, printer, verifier |
| `src/opt/*.al` | optimiser passes; `mod.al` is the pipeline |
| `src/x86/*.al` | instruction selection, register allocation, encoder; `mod.al` is the backend driver |
| `src/elf.al` | ELF writer |
| `src/prelude.al` | the run-time library of every AL program (embedded into the compiler) |

Conventions:

- **Interface and private parts.** What a file offers to other files keeps a name that says
  where it comes from: `gvn_run`, `elf_link`, `lexer_lex`, `opt_optimize`. Everything else is
  `priv` and has the short name that is natural inside its file (`priv fn numberable`,
  `priv struct Key`, `priv const COUNT_MAX` ...): about 490 of 880 top-level names are private; a
  pass exports one `x_run`, the parser 12 names, `main.al` nothing. Several files have private
  declarations of the same name (`block`, `stmt`, `Ctx`, `run_find`). A short name is not
  used where a local variable or field of the file has it (a local would shadow the
  function): those keep the file prefix (`lexer_pos`, `lower_match_subs`, `emit_kind`).
- **Methods.** Functions that act on a type take it as first parameter and are called as
  methods (`f.rpo()`, `cx.resolve(..)`); they have no prefix and are overloaded across files
  by that first parameter (`expr(self: *Fx, ..)` in lower_expr.al, a private
  `expr(p: *Parser)` in parser.al, private `expr`s in lint.al and priv.al).
- **Enum variants** have no enum prefix: `Op.Add`, `Term.Jmp`, `EK.Int`, `TyK.Ptr`, written
  bare (`Add`, `Jmp(t)`) wherever the type is known, which is almost everywhere. 45 names
  belong to several enums (`Add`: `BinOp`, `Op`, `MOp`; `Fn`: five enums). Written qualified:
  the few places the compiler asks for; the constructed side in functions that translate
  between two enums sharing a name (`Tuple(ts) => .. intern(TyK.Tuple(ids))`, `o = Op.Add`
  next to `op == Add` on a `BinOp`); and always the variants called `None` (`Term.None`,
  `Opnd.None`, `RetAbi.None`), because `None` alone reads as `Opt`. A variant may have the
  name of a struct: `SK.Expr` / `Loop` / `Block`, `UnOp.Addr`, `Decl.Global`,
  `RelocTarget.Func` stand next to the structs `Expr`, `Loop`, `Block`, `Addr`, `Global`,
  `Func` (`Addr{base: Global(g), off: off}` is the struct `Addr` with a `Base.Global`).
- **`match`.** Nested patterns, guards, alternatives and tuple matches replace nested
  matches (`match (fk, tk) { (Int(fb, fs), F64) => .. }` in `convert`, `match (&i.a, &i.b)`
  in the x86 encoder: a tuple of pointers, so nothing is copied). `x := match o { Some(v) =>
  v  None => return .. }` and `c, t, e := match term { Br(a, b, c) => (a, b, c)  _ =>
  continue }` are the forms for "take it or leave". `&name` bindings change a payload in
  place (`Br(_, &t, &e)`). What still needs an inner `match`: looking into a struct behind a
  payload (`Field(b, n) => match b.k { Ident(q) => ..`), and a scrutinee computed from an
  outer binding (`Some(t) => match self.types.k(t) { .. }`). Enums with data are compared
  with `==` (`p.peek() == Nl`, `blk.term != Trap`, `i.b == I(0)`); "is it this variant,
  whatever the payload" is a small function (`is_r`, `tk_id`).
- **Copies.** `clone(x)` is the builtin deep copy everywhere (functions leaving the work
  region, instruction and operand lists). `clone(p)` of a pointer is a compile error:
  write `clone(*p)` / `clone(v)`. A plain assignment of a `Vec` shares its
  buffer, which is what the read-only uses of type tables want (`fields :=
  self.types.structs[sid].fields`).
- **Embedded files** are constants: `priv const PRELUDE = embed("prelude.al")` and the table
  `STD_MODULES = [_](str, str){...}` in `src/main.al`.
- **Loops.** `for x in v` over a `Vec`; `v.items()` only where a slice is needed (`join`,
  `sort`, `extend`, `==`). Labelled `continue` / `break` instead of flags for leaving two
  loops (`continue blocks` in simplify.al).

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

Compiling the compiler (about 25,800 lines and the 2,700 of the prelude) takes about 3.4 s and 0.4 GB.
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
  declaration becomes private-capable with one case in `set_priv` (`src/parser.al`) and one
  in `priv_decl_info` / `rewrite` (`src/priv.al`).
- **Nested and anonymous functions** (`src/lower_nested.al`). `fn name(..) { }` inside a
  block is the statement `SK.Fn`, `fn(..) { }` the expression `EK.Fn` (a `FnDecl` with an empty
  name). Both become ordinary IR functions `outer.name` / `outer.fn@line:col`, lowered where
  they are written by `lower_fn_lower_body` with the type environment of the enclosing
  function (so once per instantiation of it); `Fx.nested_done` makes a declaration that is
  lowered again (a `defer` block on another way out) reuse the same function. The name lives
  in the block's scope next to the variables (`Scope.vars`, with a negative type slot that
  indexes `Cx.nested`). The `Fx` of the body has the enclosing one as `parent`: `lookup`
  continues there, finds nested functions, and reports a variable as `LOWER_NESTED_OUTER`,
  which is the "does not see the variables of the function around it" error. There is no
  capture and no environment: calls go through `call_fn` like calls of top-level functions,
  and the value is `Op.FAddr`.
- **Copy-write check** (`src/lint.al`). `lint_copy_writes` runs per `:=` statement while a
  function is lowered (it needs the type of the initialiser) and counts, in the rest of the
  block, direct field assignments to the new name against every other occurrence of it.
- **Failures that name the caller** (`pop`, `last`, `insert`, `remove`, `swap_remove`,
  `truncate`; `count`, `replace`, `split`, `find` from a position, `find_any`, `parse_i64`
  with a base, `to_base`). A prelude function `f` may have a twin `__at_f` with the same parameters plus
  a last `at: str`. `cx_new` records the pairs (`Cx.located`, matched by parameter types) and
  `call_fn` compiles every call of `f` as a call of `__at_f` with the "file:line" of the call
  (`loc_str`, as `assert` and bounds checks get theirs). Overload resolution, method calls
  and `alc sigs` only ever see `f`; `f` itself (what the name means as a function value)
  calls the twin with "?". To give another library function a caller location, write its
  twin; nothing in the compiler changes.
- **`Map`** (`src/prelude.al`). The entries are stored in insertion order (`keys`, `vals`,
  `tags`: three parallel arrays) and found through `index`, an open-addressing table of
  `u32` slots that hold the entry number and the upper bits of the hash; the comment above
  `struct Map` has the details. The compiler knows three things about the type (`map_kv` in
  `src/lower_mem.al` recognises it): the field `len` (for `len(m)`), `__clone_map` (for
  `clone`) and `__put_map` (for `print`, which shows the entries, not the fields).
- **`match`** (`src/lower_match.al`). The patterns of all arms are tested in order; the
  bodies are lowered by `arm_body`, normally right after their tests, but an arm whose value
  needs its type from the other arms (`needs_type`) is lowered after all others. `covers`
  is the whole unreachable-pattern rule.

## Parallel back end

`x86_compile` compiles functions independently of each other. With at least 64 reachable
functions and more than one CPU (the CPUs of `sched_getaffinity`, limited by a cgroup quota
in `/sys/fs/cgroup/cpu.max`, at most 6) it forks workers (`fork_worker` in `src/base.al`) that
each compile a share of the functions balanced by IR size and write the machine code,
relocations and float constants into a mapping shared with the compiler (`emit_put_code`);
the compiler compiles its own share meanwhile, then builds the float constant pool in the
order of the functions, so the output is byte-identical to a sequential compile. Whatever a
worker does not deliver (it crashed, failed or ran out of room) the compiler compiles itself;
workers are silent unless `ALC_DEBUG` is set. `ALC_JOBS=n` sets the number of processes
(`ALC_JOBS=1`: sequential); `--emit-asm` and the per-function debug output (`ALC_DEBUG` other
than `mem`) are always sequential.

## Debugging switches

`ALC_DEBUG=verify` (IR verifier between passes), `trace`, `mir`, `unroll`, `mem`;
`ALC_DISABLE=pass,...` (`unroll`, `bce`, `licm`, `gvn`, `loadelim`, `checkmerge`, `tre`,
`partial`, `thread4`, `thread5`, `ifconv`); `ALC_STD_DIR=<dir>` reads bundled modules from
`<dir>` instead of the copies inside the compiler; `ALC_ALIGN=1` aligns inner loops.
