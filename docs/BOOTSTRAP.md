# How the compiler is built

`alc` is written in AL and compiles itself. There is no other implementation language in the
repository and no build tool besides `alc`.

```
./build.sh                  # seed -> stage 1 -> stage 2 -> stage 3, installs build/alc and build/alc.exe
./build.sh --quick          # seed -> build/alc only
./build.sh --reseed         # full build, then replace the seed with the result
./build.sh --windows-check  # full build, then the cross-host fixpoint under Wine (below)
```

| Stage | Built by | From | Purpose |
|-------|----------|------|---------|
| seed | (committed) `bootstrap/alc` | an earlier state of `src/` | any compiler good enough to compile the current sources |
| 1 | seed | `src/main.al` | the current compiler, compiled by the old one |
| 2 | stage 1 | `src/main.al` | the current compiler, compiled by itself |
| 3 | stage 2 | `src/main.al` | must be byte-identical to stage 2 |

The comparison of stages 2 and 3 is the self-check: a compiler that miscompiles itself in a
way that changes its behaviour produces a different stage 3. `build/alc` is stage 2.
`verify.sh` runs the full build first and tests `build/alc`. While stage 2 compiles stage 3, it
also compiles the compiler for Windows, `build/alc.exe` (see [the compiler on
Windows](#the-compiler-on-windows)).

The seed is a static x86-64 Linux executable of about 3.7 MB. It only has to be replaced
(`--reseed`, then commit `bootstrap/alc`) when the sources start to use a language feature
the seed does not know, or a run-time library function it does not have: stage 1 is linked
with the seed's copy of the library, so add the feature or library function, build, reseed,
then use it. `ALC_SEED=/path/to/alc` selects another seed. What the compiler needs of its
host is not in the library but in `src/host_linux.al` / `src/host_windows.al` (system calls,
`extern` kernel32.dll functions), which are compiler sources: a new host function goes there
and needs no reseed. The run-time library (`src/prelude*.al`) and the bundled modules (`std/`)
are compiled by the new compiler.

Stage 1 is compiled by the seed and may therefore lay out types as an older compiler did (the
seed before the change to 4-byte enum tags stored every tag in 8 bytes). The compiler never
depends on the layout of its own types: no `sizeof` or `cast` of an enum (the threads of the
parallel back end hand their results over as AL values in memory: nothing is serialised).

## Versions and the changelog

The compiler's version is one constant in `src/main.al`: `priv const VERSION = "X.Y.Z"`, three
decimal numbers without a `v` or any suffix. `alc --version` (or `alc version`) prints
`alc X.Y.Z` on its first line and the default target on the second. Between releases the
constant keeps the last released version. `verify.sh` checks that the first line of
`build/alc --version` names the topmost released section (`## [X.Y.Z] - date`) of
`CHANGELOG.md`.

Whoever changes the compiler, the run-time library or `std` adds one line per user-visible
change under `## [Unreleased]` at the top of `CHANGELOG.md`, in the category it belongs to, in
this order (a category heading only when it has entries):

- `### Breaking`: a program that built and worked before must change: a removed or renamed
  module, function or option, a changed signature, behaviour or language rule. Each entry
  says what to write instead. Such a change is listed here only, not again below.
- `### Added`: new language features, functions, modules, options, targets.
- `### Changed`: different behaviour that breaks no program (messages, performance, sizes).
- `### Fixed`: bugs fixed.
- `### Removed`: removals that break no program (a deprecated alias nothing uses any more).

Internal work (optimiser passes, refactoring, tests, the seed) gets no entry unless a user can
notice it. A release:

1. Choose the version: while the major version is 0, the minor version goes up (0.1.3 ->
   0.2.0) when there is a Breaking or Added entry, otherwise the patch version (0.1.0 ->
   0.1.1).
2. In `CHANGELOG.md` rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a new empty
   `## [Unreleased]` above it and update the two link lines at the end.
3. Set `VERSION` in `src/main.al` to `"X.Y.Z"`; `./verify.sh` must pass.
4. Commit, then tag that commit: `git tag -a vX.Y.Z -m "AL X.Y.Z"` and push the tag.

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
| `src/main.al` | driver: arguments, the version (`VERSION`), source loading (files and the `when`s that include them), bundled modules, diagnostics output; lists every other file except the parts below that one or two files include themselves |
| `src/when.al` | `when` (deciding conditions, the branches of function bodies) and `-D NAME=VALUE` |
| `src/base.al` | helpers for compiler code: Vec constructors (`vec_one`, `vec_two`; `vec_of` and `vec_fill` are library functions), `align_up`, paths (`path_join`, `path_parent`), `file_name`, `os_error`, processes, worker threads, the working memory (`Work`: regions and per-thread pass state) |
| `src/host_linux.al`, `host_windows.al` | the compiler's host (the functions listed at the top of `base.al`: running programs, the big stack, the CPU count): included by `base.al` with `when TARGET_OS == ...` |
| `src/lexer.al`, `parser.al`, `ast.al` | front end |
| `src/priv.al` | file-private declarations: renames them right after a file is parsed |
| `src/types.al`, `lower*.al` | type checking fused with lowering to SSA IR: `lower.al` (declarations, instantiation), `lower_fn.al`, `lower_expr.al`, `lower_call.al`, `lower_vec.al` (vector / matrix types), `lower_mem.al` (builtin names shared with declared functions, `Vec` indexing, `clone`), `lower_nested.al` (nested functions) |
| `src/lint.al` | checks on the AST that need types: field writes to a struct copy that is never read |
| `src/ir.al` | IR, dominators, loops, printer, verifier |
| `src/opt/*.al` | optimiser passes; `mod.al` is the pipeline |
| `src/x86/*.al` | instruction selection, register allocation, encoder; `mod.al` is the backend driver |
| `src/elf.al` | ELF writer (Linux) |
| `src/pe.al` | PE32+ writer (Windows, `--target windows`): sections, DLL import table |
| `src/backtrace.al` | the table of the stack traces of panics (frames, source lines), added to the module before linking |
| `src/objwrite.al` | what the two writers share (little-endian output, the layout of text, read-only data, bss, relocations): included by `elf.al` and `pe.al` |
| `src/prelude.al` | the run-time library of every AL program (embedded into the compiler) |
| `src/prelude_linux.al`, `prelude_windows.al` | its OS layer for the target (`--target`): system calls on Linux, kernel32.dll on Windows; the functions a layer defines are listed at the top of `prelude.al` |

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
way, because every pass builds tables it throws away. Besides the arena of the thread it
therefore uses two prelude regions (`Region` with `enter` / `leave` / `reset`, see the language
reference; `src/base.al`), which belong to a `Work`: every thread that optimises or compiles
functions has its own (`work_main()` is the main thread's, see [parallel back
end](#parallel-back-end)), and the functions below take it:

- the **arena** of the thread for what lives to the end (AST, types, the module, machine code);
- the **work region** for one function being optimised or compiled: `work_begin(w)` enters it
  and `work_end(w)` leaves and resets it, in `opt_first`, `opt_func` and `compile_fn`. The
  function (or its machine code) is deep-copied to the arena with `clone` right after
  `work_end(w)` (`keep_func` copies what lies in the regions of `w`, `work_holds`): the
  discarded memory stays readable until the next `work_begin(w)`. `work_pause(w)` /
  `work_resume(w)` switch to the arena for a moment, for results that must stay;
- the **scratch region** for tables that a pass rebuilds on every round of a loop
  (`scratch_on(w)` / `scratch_off(w)` bracket their construction, `scratch_reset(w)` at the top
  of the next round discards them; used in `src/opt/simplify.al` and the register allocator).
  Nothing reachable from the function may be allocated between `scratch_on(w)` and
  `scratch_off(w)`.

Numbers of instructions, blocks and virtual registers are kept in 32 bits wherever they are
stored in bulk (the instruction lists of the blocks, the passes' tables: `Vec[i32]`, where
`NOV` reads as -1). The places that make new numbers (`mk`, `new_block`, `new_vreg`, and
those of types, symbols, functions and frame slots) assert that they fit in 32 bits.

Compiling the compiler (about 40,000 lines including the run-time library) takes about 0.13 s at `-O0` and 0.91 s optimised, using about 0.15 GB (`bench/compile.sh`).
`ALC_DEBUG=mem` prints memory and time after each phase.

## Notes on language features

- **`priv`** (`src/priv.al`). Once the files are loaded and their `when`s decided (`finish` in
  `src/main.al`), `priv_apply` renames each private
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
- **`when`** (`src/when.al`, driven by `src/main.al`). Each file's top-level declarations are
  kept as a list of items (`Item` in main.al: a declaration, a file included here for the
  first time, or a `when` still to decide). The library's files (prelude, OS layer, bundled
  modules) decide their `when`s while they are read; the program's are decided in rounds
  after loading (`settle`), and the files a taken branch includes are read then. `finish`
  then replaces the `when` statements of function bodies by their taken branch
  (`when_stmts`), gives the constants their `-D` values (the declared value becomes the
  literal of the command line: `when_apply_defs`), runs `priv_apply` per file (so priv.al
  only sees taken branches) and puts the declarations in order: each file where it is first
  included, as before `when` existed. The conditions are evaluated on the AST with the
  constants and enums declared outside `when` (`when_register`, only once a `when` or `-D`
  needs them), not by the type checker, which never sees an untaken branch. `TARGET_OS` is
  declared by the OS layers (`src/prelude_linux.al`, `src/prelude_windows.al`), `enum Os`,
  `enum Arch` and `TARGET_ARCH` by `src/prelude.al`; a constant may be a variant of an enum
  without data (`CV.Variant`). The bundled modules with an OS layer (std.window, std.input,
  std.audio) include it with `when TARGET_OS == Windows { use std.window_windows } else { ... }`
  at their end, which loads the files in the same order as the rule the driver had before.
- **`if` on a constant** (`if_br` in `src/lower_fn.al`): a condition (or an operand of `&&`,
  `||`, `!`) without local variables whose `const_eval` is a `bool` becomes a jump, and the
  branch it rules out is unreachable: pruned by `opt_first` at every level, with the calls and
  data in it. The linkers (ELF and PE) leave out every read-only global that the compiled
  code does not refer to, directly or through the data of other kept globals
  (`x86_live_data` in `src/x86/mod.al`). `ALC_DISABLE=constif,deaddata` turns both off, which
  gives the executables of the compiler before them.
- **`alc check --all-targets`** (`check_all` in main.al) loads and checks the program once per
  target and merges the diagnostics by file name, line, column and message.
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
  `truncate`; `count`, `replace`, `split`, `find` from a position, `find_any`, `parse_i64` and
  `parse_u64` with a base, `to_base`). A prelude function `f` may have a twin `__at_f` with the same parameters plus
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
- **Stack traces of panics** (`src/backtrace.al`, the walk `__bt_print` in `src/prelude.al`).
  The code keeps no frame pointer; the walk relies on the frame shape instead: after its
  prologue (pushes, then one allocation; Windows: a probe loop for a page or more) a function
  never moves rsp, so the return address of a frame lies at sp + 8 * pushes + allocation.
  *Source locations*: `Inst.loc` numbers a `SrcLoc` (file, line, function, the location of the
  call it was inlined at) in `Module.locs`. Lowering stamps every instruction with the location
  of its statement or expression (`Fx.at`, restored after each), trap blocks with the check's;
  the inliner rebases the callee's locations onto the call (`src_loc_inlined`; code of a library
  function, `Func.lib`, takes the call's location); unrolling copies them; other passes leave
  new instructions at 0. Isel stamps the MIR of each IR instruction (`MInst.loc`, in a padding
  word: MInst stays 80 bytes), and `emit_emit` records `Code.lines` (offset, location) where the
  location changes, after branch relaxation, plus the frame shape (`alloc`, `npush`, the
  prologue offsets); both are part of the `Code` a worker thread hands over. *The table*: `bt_attach`
  (after `x86_compile`) encodes per function its start (relative to the first function, as
  `layout_text` places them), size, frame shape and line data (ULEB128: inlined locations, then
  offset/line pairs with lines as zigzag deltas), with names and files as strings; it becomes
  the read-only global `__bt_data`, and the library's `__bt_table` points at it through a data
  relocation; frames of the program are those of files that are not `Cx.core_file` (bundled
  modules count as the program; `Func.lib` is the same notion). *The walk*: `__bt_print`
  (called by `__die`) starts at its caller through the builtin `__ra_addr()` (library only;
  `Op.RaAddr`, `lea` of `MK_INARG` -1, so the function using it must be `noinline`; such a
  function also pushes every callee-saved register, `MFunc.save_all`, so the walk knows the
  caller's registers), or at the faulting instruction and registers recorded by the OS layer's
  fault handler (Linux: the ucontext of the SIGSEGV/SIGFPE handler on its alternate stack;
  Windows: the CONTEXT of the vectored handler; a stack overflow there is reported by a new
  thread, because Wine leaves the handler less than 1 KiB). A faulting instruction may sit in a
  prologue: the pushes before it are decoded from the code, a probe loop is undone with r11.
  Each step is checked (the return address inside a function, the frame inside the thread's
  stack, `__os_stack_range`, and above the last); a fault during the walk ends the program.
  The walk keeps its state in globals and allocates nothing. *C frames*: a return address in no
  function of the table but in a C library continues the walk through the OS layer
  (`__os_bt_foreign` / `__os_bt_unwind` / `__os_bt_where`, reached through function values that
  `__bt_c_init` sets: the generated entry point calls it only when the program declares
  `extern` functions, so other programs do not contain that code). The walk tracks the
  callee-saved registers (C code may keep a frame through rbp): a frame of the program gives
  its caller's values from its prologue's pushes (decoded from the code). Linux: the libraries
  come from the loader's `r_debug` (DT_DEBUG of the program's dynamic section, found through
  AT_PHDR), each one's program headers in memory give its segments, `.eh_frame_hdr` (binary
  search for the FDE) and `.dynamic` (`.dynsym` names: the nearest function symbol whose size
  reaches the address); a small CFI interpreter (the instructions GCC and Clang emit: CFA
  rules, offsets, registers, remember/restore, advance) computes the caller's CFA, return
  address and saved registers; every read of call frame data is checked against the library's
  readable segments and every read of the stack against the frame, so bad data ends the trace.
  Windows: `RtlLookupFunctionEntry` / `RtlVirtualUnwind` on a CONTEXT built from the tracked
  registers (a frame register must point into the stack first); names from the DLL's export
  directory (the export at the function's start). Sizes: hello world 1.5 KB of table, the
  compiler about 190 KB (5%); the walker's code 6 KB, 12 KB with the Linux C-frame part (only
  in programs with C functions); on Windows the DLL part adds 3 KB to every program. The walk's
  two passes (count, then write the first 20 and last 5 lines) cost about 10 ms for a million
  frames.

## Threads

How the run-time library and the compiler implement threads (the rules: DETAILS.md).

- **Thread-local globals.** A global of a library file whose name starts with `__tls_`,
  `__heap_` or `__region_` is thread-local (`Global.tls`, set in `global_new`, `src/lower.al`;
  zero-initialised only). Front end and optimiser treat it as any global (a `GAddr`, a distinct
  object for alias analysis, pure); the back end lays the TLS globals out in one thread block
  (`layout_tls` in `src/objwrite.al`), and `gaddr` of a TLS global is its displacement, so the
  ordinary `Abs32Global` relocations fill it in. Linux (x86-64 TLS variant II, local-exec):
  `PT_TLS` (memsz the block, no file data); the block ends at the thread pointer, a load is
  `mov rax, fs:[off - size]` (memory kind `MK_TLS`: the global's operand plus the `fs` prefix;
  base and index registers still fold), an address `mov r, fs:[0]` + `lea r, [r + off - size]`.
  A dynamically linked program gets the block from glibc's loader in every thread (also those
  of C libraries); a static one starts with FS 0, and `__rt_init` (`src/prelude_linux.al`) maps
  the block and a TCB whose first word points to itself and sets FS (`arch_prctl`) before
  anything touches a TLS global. Windows: a TLS directory (zero fill, `AddressOfIndex` =
  `__win_tls_index`); the address of a TLS global is a value computed where its `GAddr` is
  (`tls_block` in `src/x86/isel.al`: `gs:[0x58]`, the index, the block, `lea`), once per
  function after GVN / LICM. Programs without threads differ from before only in that: the
  arena, region stack, output state and `io_error` accesses carry the `fs` prefix, the extra
  program header moves the code by 48 bytes, and the library itself changed.
- **Atomics** are `Op.Atomic` (k = `ATOMIC_*`), not pure and `clobbers()`: every pass that keeps
  memory facts drops them there like at a call (loadelim, licm, cleanup keeps it as a root,
  gvn does not number it, bce / checkmerge / `opt_is_check_trap` do not move checks across it,
  an alloca it uses escapes). `and` / `or` / `xor` are lowered to a CAS loop in the IR
  (`atomic` in `src/lower_call.al`). Back end: `Xchg`, `Xadd`, `Cmpxchg` (fixed rax), `Mfence`.
- **Threads.** `__thread_spawn` / `__thread_main` / `__thread_join` (`src/prelude.al`) with a
  pooled control block (`__ThreadCtl`, a generation number makes stale handles detectable); the
  OS layers create threads: Linux looks up `pthread_create` and friends in the loader's link
  map (`DT_GNU_HASH`, default version: `c_symbol`) or, in a static program, uses the
  library-only builtin `__clone(flags, stack, ptid, ctid, tls)`: `Op.Syscall` with k = 1, whose
  encoding continues in the child with `pop rdi; pop rax; call rax` (argument and entry pushed
  on the new stack); Windows calls `CreateThread`. Locks: futexes (Linux), SRW locks and
  condition variables (Windows). The output buffers, the output lock and the panic lock: the
  comments of "output" and `__die` in `src/prelude.al`.
- **The compiler's host.** The compiler is a threaded program too (its parallel back end, below);
  `alc build` unlinks and rewrites an executable that is busy (ETXTBSY: Linux keeps an ended
  multi-threaded process's file mapped while it frees its memory).

## Parallel back end

`x86_compile` compiles functions independently of each other. With more than one CPU and
enough functions (**Number of threads** below) the compiler's thread
and worker threads compile them together, on Linux and Windows alike (`compile_spread` in
`src/x86/mod.al`; the threads are the run-time library's, started by `worker_start` in
`src/base.al`). The functions are in one list, largest first, and every thread takes the next
one with an `atomic_add` on the position in the list, so all threads finish at about the same
time. A thread puts the result of a function (`Done`: machine code, relocations, float
constants, frame shape, line table) into that function's element of a result array; it is
allocated in the thread's own arena, which the join hands to the compiler's thread and which
is never freed, so nothing is copied. After the join the compiler builds the float constant
pool in the order of the functions and takes the back end's diagnostics (`Code.err`: a frame
too large, a Linux system call in a Windows executable) in that order too, so output and
messages are byte-identical to a sequential compile with any number of threads.

At `-O0` the optimiser is only `opt_first` per function (prune, mem2reg, DCE), which reads
nothing of the module but the function: `opt_optimize` leaves it to the back end
(`opt_finish`), and the threads optimise the functions they take before compiling them. As the
reachable functions are only known from the optimised IR (prune and DCE remove calls), at
`-O0` every lowered function is optimised and compiled (with at least 64 functions in the
module; nearly all are reachable at `-O0`); each thread also records the calls and function
addresses of the optimised IR in the function's entry of `Refs`, from which the compiler
computes the reachable functions as a sequential compile does and keeps only their code.
Optimised builds compute the reachable functions first and compile only those (at least 64) in
the threads.

**Number of threads** (`spread_threads` in `src/x86/mod.al`), the compiler's thread included:
one per CPU (Linux: the CPUs of `sched_getaffinity`, limited by a cgroup quota in
`/sys/fs/cgroup/cpu.max`; Windows: `GetActiveProcessorCount`), at most 32, and at most one per
24 functions at `-O0` (where the threads also optimise them) or per 16 functions when
optimising (fewer, bigger functions after inlining); below 64 functions the compile stays on
the compiler's thread. A thread costs its start and memory: its arena and its work and
scratch regions each begin with a 2 MiB page where the kernel backs memory with transparent
huge pages, about 6 MB a thread for a small program, and up to 10 MB in the optimised
self-compile (the work regions of the largest functions, whose register allocation needs a
bit matrix of up to 16 MB). Measured on a 12-CPU machine (6 cores with 2 hardware threads
each), wall time of `alc build`, best of 5 (large) or 15 (small) runs, interleaved:

| program (functions compiled at `-O0` / optimised) | 1 | 2 | 4 | 6 | 8 | 12 threads |
|---|---|---|---|---|---|---|
| hello world (78, sequential), `-O0` | 10.3 ms | 9.4 | 9.3 | 10.0 | 10.6 | 10.4 |
| `tests/run/clone.al` (163 / 83), `-O0` | 18.6 | 14.2 | 12.6 | 12.8 | 13.3 | 14.1 |
| the same, optimised | 55.5 | 49.5 | 48.9 | 49.0 | 50.8 | 52.2 |
| `tests/run/index_scale.al` (125), `-O0` | 26.8 | 19.7 | 16.9 | 16.4 | 17.0 | 18.2 |
| `tools/gen_dx12.al` (347 / 135), `-O0` | 42.5 | 29.2 | 22.9 | 22.0 | 21.6 | 21.7 |
| the same, optimised | 145.3 | 128.8 | 118.7 | 116.6 | 115.1 | 116.6 |
| the compiler (1967 / 963), `-O0` | 341 | 214 | 166 | 136 | 132 | 125 |
| the same, optimised | 1179 | 1045 | 972 | 935 | 933 | 931 |
| back end of the compiler (`ALC_DEBUG=mem`), `-O0` | 255 | 130 | 80 | 51 | 46 | 42 |
| peak RSS of the compiler, `-O0` | 184 MB | 186 | 190 | 204 | 218 | 236 |
| peak RSS of the compiler, optimised | 258 MB | 258 | 286 | 306 | 330 | 368 |
| peak RSS of `clone.al`, `-O0` | 40 MB | 40 | 40 | 50 | 62 | 78 |

The rule gives hello world 3 threads, `clone.al` 6 at `-O0` and 5 optimised,
`index_scale.al` 5, `gen_dx12.al` 12 and 8, the compiler 12: within 0.5 ms of the best count
of every program measured (also generated ones with 100 to 3000 functions), never slower than
the earlier fixed 6 by more than that, and 11 ms faster on the compiler at `-O0`. The cap of
32 is not measured: there the largest functions start to bound the gain (the compiler's
largest takes 6 ms of its 255 ms `-O0` back end) while every thread still costs 5-10 MB.

**What the threads share**, and why that is safe:

- Per thread: a `Work` (`src/base.al`) with the work and scratch regions and everything the
  passes remember between calls (the CFG memo of `ir.al`, the change count and clean passes of
  `opt_pass`, the escaping allocas of `alias.al`, licm's preheader count, mem2reg's `settled`,
  `insts_main`), which were globals before; the allocation arena and region stack (run-time
  library). While a thread works on a function, `Func.w` points to its Work, so the passes find
  their state through the function they are given. The compiler's main thread uses
  `work_main()`, a worker thread the Work compile_spread made for it.
- Per function: a function is optimised and compiled by one thread, which alone writes its
  `Func`, its elements of the optimiser's tables by function (`first_done`, `clean_at`,
  `clean_end`), of `Refs` and of the result array (distinct elements, never resized while the
  threads run).
- Filled before the threads start, then only read: the rest of the module (globals, and the
  signatures of other functions, which isel reads for calls: `keep_func` copies only lists in
  the regions of its own Work, so a thread never rewrites `params` or `rets` that others read),
  the optimiser's environment switches and `check_fail` (`opt_optimize`), `win_tls_index`
  (`isel_init`), the register order (`regalloc_windows`), `deferred`. The front end's tables
  (types and their layout caches, symbols, interned names) are not used by `opt_first` or the
  back end at all.
- Shared and written: only the position in the list (atomic). The threads take no lock.

Thread-local globals (`__tls_*`) are a feature of library files only; making compiler globals
thread-local would need a language change and a new seed, and every pass has the function,
hence its Work, at hand.

**Failure.** A panic or memory fault in a worker thread ends the compiler with that thread's
message and stack trace, as in any AL program. The forked workers had a fallback (the compiler
optimised and compiled itself what a crashed worker had not delivered); threads share the
process, so there is none. A worker that fails is a compiler bug either way: the same code runs
on the same function as in a sequential compile, which fails the same way (`ALC_JOBS=1`
reproduces it on one thread), and the fallback only hid the bug.

**Stack.** A worker thread reserves a stack of 1 MiB (`WORKER_STACK` in `src/base.al`),
committed as it is used. Nothing a worker runs (`opt_finish`: prune, mem2reg, DCE; then
`compile_fn`) recurses deeper with the size or the nesting of a function: mem2reg's search for
the definition of a variable goes back through the predecessors with a work stack of its own
(`read_in` in `src/opt/mem2reg.al`; it used to recurse once per block on its way back, 2.5 MiB
for 20,000 `if`s in a row), and the other recursions are bounded by a constant (address
folding in isel at 8 levels, `decompose_obj` in `alias.al`, the sort's depth limit). Measured
with an instrumented compiler that runs all functions on one worker and counts the stack pages
it touched (`mincore`): about 12 KiB on every program, at `-O0` and optimised, for the Linux
and the Windows target: the tests of `tests/run`, the examples, the benchmarks, the compiler
itself, generated programs with 5,000 to 80,000 `if`, `if`/`else`, `while`, `match`, `&&`/`||`
conditions or statements in a row, and nests of 1,950 levels (the parser's limit is 2,000) of
blocks, `if`, `if`/`else`, `while`, `for`, `loop`, `match`, `else if`, parentheses, unary
minus, operators, calls, method calls and `if` expressions. Under Wine the Windows compiler
compiles them (all but the 80,000-statement programs and the `for` nest, too slow there) with
a worker stack of 128 KiB, half of which is the guarantee for the overflow handler
(`SetThreadStackGuarantee`). 1 MiB leaves a margin of about 80 times; what remains is the depth
of the passes' fixed call chains, which no input deepens. (The compiler's own thread needs
more: up to 22 MB on the 2,000-level nests, in the parser and lowering, whose recursion follows
the nesting.)

`ALC_JOBS=n` sets the number of threads (`ALC_JOBS=1`: sequential, on the compiler's thread
alone); `--emit-asm` and the per-function debug output (`ALC_DEBUG` other than `mem`) are always
sequential, and `--emit-ir` optimises every function in the compiler before it prints them.
`ALC_DEBUG=mem` counts the memory of the threads' arenas in the "compiled" line.

## Debugging switches

`ALC_DEBUG=verify` (IR verifier between passes), `trace`, `mir`, `unroll`, `mem`;
`ALC_DISABLE=pass,...` (`unroll`, `bce`, `licm`, `gvn`, `loadelim`, `checkmerge`, `tre`,
`partial`, `thread4`, `thread5`, `ifconv`, `devirt`: calls through known function values stay
indirect, `spec`: no specialised copies; outside the optimiser `constif`: `if` on a constant
is not decided while lowering, `deaddata`: all read-only data is linked, `backtrace`: no stack-trace table); `ALC_STD_DIR=<dir>` reads bundled modules from
`<dir>` instead of the copies inside the compiler; `ALC_PRELUDE=<file>` reads the prelude
from `<file>` and the OS layer from `prelude_linux.al` / `prelude_windows.al` next to it (no
layer if there is none: the file is then the whole run-time library), so
`ALC_PRELUDE=src/prelude.al` tests library changes without a rebuild; `ALC_ALIGN=1` aligns inner loops.

## Windows target

`--target windows` sets `target_os` (`src/main.al`); the front end and the optimiser are the
same, the differences are:

- **Calling convention** (Microsoft x64, for every function, so that any AL function value is
  a C callback). `abi_param` / `abi_ret` (`src/lower.al`): an aggregate of 1, 2, 4 or 8 bytes
  is one integer leaf read and written as untyped memory, any other goes by reference (a copy
  the caller makes) or, as a result, through a hidden pointer that the callee also returns;
  `extern` calls take the same path as calls of AL functions, through the IAT slot. The back
  end (`params_win` and `call` in `src/x86/isel.al`) assigns registers by position, numbers
  stack arguments by position (words 0-3 are the shadow space every call reserves).
- **Preserved registers.** rsi, rdi (`mir_callee_saved`) and xmm6-xmm15 (`mir_xmm_saved`,
  saved in the frame) are saved by a function that writes them. Calls are still taken to
  clobber them (`CALL_CLOBBER` is the Linux set), which keeps the register allocator the same.
- **Stack probes.** A frame of 4096 bytes or more is allocated a page at a time, touching each
  page (`stack_probe` in `src/x86/emit.al`): the stack grows through a guard page.
- **Linking** (`pe_link`): the image is loaded at 0x400000 without base relocations (the code
  uses 32-bit absolute addresses, as on Linux), sections `.text`, `.rdata`, `.idata` (import
  descriptors, lookup tables, the IAT, which holds the import slots), `.pdata`, `.data` (with the zero
  data); the entry point is `__entry`, stack reserve 16 MiB. A reachable `syscall` is an error.
- **Unwind information.** Every function with a frame gets an UNWIND_INFO (`unwind_info` in
  `src/x86/emit.al`, kept in `Code.unwind`: pushes, the allocation, the xmm saves of its
  prologue) and a `.pdata` entry, so that the system can walk the stack through AL frames
  (exception dispatch, debuggers); functions without a frame are leaf functions.
- **Run-time library.** `src/prelude_windows.al` replaces `src/prelude_linux.al` (kernel32.dll
  only); bundled modules with Linux interfaces are refused (`LINUX_ONLY` in `src/main.al`), and
  the modules with an OS layer include the target's one with `when TARGET_OS == ...`.
  `tests/run.sh --target windows` runs the conformance suite under Wine (skip list:
  `tests/windows.skip`).
- `tests/winabi/run.sh` checks the convention against C compiled by MinGW, under Wine.

## The compiler on Windows

`alc build --target windows src/main.al -o alc.exe` makes the compiler for Windows; `build.sh`
builds it as `build/alc.exe`. It runs the same front end, optimiser and back end and writes the
same bytes as the Linux compiler: under Wine, `alc.exe` built by `build/alc` rebuilds itself
byte for byte, and `alc.exe build --target linux src/main.al` is byte-identical to `build/alc`
(`./build.sh --windows-check`; `tests/run.sh --target windows --host-wine build/alc.exe` runs
the conformance suite with it).

- **The host.** What the compiler needs of the system it runs on is in `src/host_linux.al`
  (system calls) and `src/host_windows.al` (kernel32.dll `extern`s), one of which `src/base.al`
  includes with `when TARGET_OS == ...`; files, paths and the environment go through the OS
  layers of the run-time library (the `__os_*` functions of `src/prelude_linux.al` and
  `src/prelude_windows.al`). The default `--target` is the host.
- **Stack.** The compiler needs a big stack (deep recursion in the front end, which follows the
  nesting): `with_stack(1 GB, ...)` at the start of `main`. Linux raises the stack limit
  and starts the compiler again (`ALC_STACK_SET` holds the original limit, which the programs
  of `alc run` get back); Windows runs the compiler on a thread whose stack reserves 1 GB
  (`CreateThread` with `STACK_SIZE_PARAM_IS_A_RESERVATION`, committed as it is used, with the
  64 KiB stack guarantee for the overflow handler) while the first thread only waits for it.
  The run-time library treats that thread like one a C library created: it gets its own arena,
  id and line-buffered output on first use (`big_stack_thread` flushes before it returns), so
  a panic of the compiler there says `panic in thread 1:`. (Other programs keep the 16 MiB of
  the PE header.) The nesting limit of the parser is measured against this stack.
- **Parallelism.** The same as on Linux ([parallel back end](#parallel-back-end)): that thread
  starts the worker threads (`CreateThread` through the run-time library, 1 MiB reserved each);
  the number of threads follows the same rule, with `GetActiveProcessorCount` as the number of
  CPUs, or `ALC_JOBS`.
- **Processes.** `alc run` / `alc test` start the program with `CreateProcessW` (arguments
  quoted by the Microsoft rules) and wait for it; a Linux executable (`--target linux`) is
  built but not run. `ALC_WINE` only applies on Linux.
- **Paths** may use `\` and drive or UNC roots; the compiler joins paths with `/` and keeps
  them as written in diagnostics and panic locations (so the executables are the same).
