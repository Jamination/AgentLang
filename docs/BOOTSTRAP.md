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
depends on the layout of its own types: no `sizeof` or `cast` of an enum, and the records the
parallel back end shares between processes (`emit_put_code`, the reachability records in
`src/x86/mod.al`) are written and read field by field.

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
| `src/main.al` | driver: arguments, source loading (files and the `when`s that include them), bundled modules, diagnostics output; lists every other file except the parts below that one or two files include themselves |
| `src/when.al` | `when` (deciding conditions, the branches of function bodies) and `-D NAME=VALUE` |
| `src/base.al` | helpers for compiler code: Vec constructors (`vec_one`, `vec_two`; `vec_of` and `vec_fill` are library functions), `align_up`, paths (`path_join`, `path_parent`), `file_name`, `os_error`, processes, the working-memory regions |
| `src/host_linux.al`, `host_windows.al` | the compiler's host (the functions listed at the top of `base.al`: running programs, the big stack, worker processes): included by `base.al` with `when TARGET_OS == ...` |
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

Numbers of instructions, blocks and virtual registers are kept in 32 bits wherever they are
stored in bulk (the instruction lists of the blocks, the passes' tables: `Vec[i32]`, where
`NOV` reads as -1). The places that make new numbers (`mk`, `new_block`, `new_vreg`, and
those of types, symbols, functions and frame slots) assert that they fit in 32 bits.

Compiling the compiler (about 36,500 lines including the run-time library) takes about 0.12 s at `-O0` and 0.84 s optimised, using about 0.12 GB (`bench/compile.sh`).
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
  prologue offsets); both cross the worker mapping with the code. *The table*: `bt_attach`
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

## Parallel back end

`x86_compile` compiles functions independently of each other. With more than one CPU (the
CPUs of `sched_getaffinity`, limited by a cgroup quota in `/sys/fs/cgroup/cpu.max`, at most 6)
it forks workers (`fork_worker` in `src/host_linux.al`; on Windows, which has no fork, the compile is
always sequential: `can_fork`). The functions go into a queue, largest
first: a pipe filled before the fork, from which every process (the compiler too) takes one
function at a time (`queue_new`, `queue_take`), so all processes finish at about the same
time. A worker writes each function's machine code, relocations and float constants into a
mapping shared with the compiler (`emit_put_code`) and closes its end of a pipe when it is
done; the compiler then builds the float constant pool in the order of the functions, so the
output is byte-identical to a sequential compile.

At `-O0` the optimiser is only `opt_first` per function (prune, mem2reg, DCE), which reads
nothing of the module but the function: `opt_optimize` leaves it to the back end
(`opt_finish`), and the workers optimise the functions they take before compiling them. As the
reachable functions are only known from the optimised IR (prune and DCE remove calls), at
`-O0` every lowered function is optimised and compiled (with at least 64 functions in the
module; nearly all are reachable at `-O0`); each worker also reports the calls and function
addresses of the optimised IR, from which the compiler computes the reachable functions as a
sequential compile does and keeps only their code. Optimised builds compute the reachable
functions first and send only those (at least 64) to the queue.

A fork's changes to the IR are its own, so the compiler still has the unoptimised IR of the
functions the workers took. Whatever a worker does not deliver (it crashed, failed, exited
before it was done or ran out of room) the compiler optimises and compiles itself; workers
are silent unless `ALC_DEBUG` is set. `ALC_JOBS=n` sets the number of processes
(`ALC_JOBS=1`: sequential); `--emit-asm` and the per-function debug output (`ALC_DEBUG` other
than `mem`) are always sequential, and `--emit-ir` optimises every function in the compiler
before it prints them.

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
- **Stack.** The compiler needs a big stack (deep recursion in the front end and SSA
  construction): `with_stack(1 GB, ...)` at the start of `main`. Linux raises the stack limit
  and starts the compiler again (`ALC_STACK_SET` holds the original limit, which the programs
  of `alc run` get back); Windows runs the compiler on a thread whose stack reserves 1 GB
  (`CreateThread` with `STACK_SIZE_PARAM_IS_A_RESERVATION`, committed as it is used, with the
  64 KiB stack guarantee for the overflow handler) while the first thread only waits for it:
  only one thread ever runs AL code, so the arenas need no locking. (Other programs keep the
  16 MiB of the PE header.) The nesting limit of the parser is measured against this stack.
- **Parallelism.** None: there is no fork, so the back end takes its sequential path.
- **Processes.** `alc run` / `alc test` start the program with `CreateProcessW` (arguments
  quoted by the Microsoft rules) and wait for it; a Linux executable (`--target linux`) is
  built but not run. `ALC_WINE` only applies on Linux.
- **Paths** may use `\` and drive or UNC roots; the compiler joins paths with `/` and keeps
  them as written in diagnostics and panic locations (so the executables are the same).
