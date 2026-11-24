# How the compiler is built

`alc` is written in AL and compiles itself. There is no other implementation language in the
repository and no build tool besides `alc`.

```
./build.sh                  # seed -> stage 1 -> stage 2 -> stage 3, installs build/alc and build/alc.exe
./build.sh --quick          # seed -> build/alc only
./build.sh --reseed         # full build, then replace the seed with the result
./build.sh --windows-check  # full build, then the cross-host fixpoint under Wine (below)
```

On Windows, `build.bat` does the same from the seed `bootstrap\alc.exe` (`build.bat --quick`,
`build.bat --reseed`); its stage 2 also builds the Linux compiler `build\alc`. Both scripts
produce byte-identical compilers, and `--reseed` on either replaces both seeds, so they never
drift apart: a seed that falls behind could not compile sources that use newer features.
`build.bat` compares the stages with `fc /b` (Wine's `fc` cannot compare binaries: under Wine it
warns and skips the comparison).

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

## Testing

```
tests/run.sh                        # Linux: the conformance suite with build/alc
tests/run.sh match                  # only the tests whose name contains "match"
tests/run.sh ./build/alc match      # the same with the compiler named
tests/run.sh --target windows       # the programs built for Windows, run under Wine
tests/run.sh --target windows --host-wine build/alc.exe   # the same with the compiler for Windows under Wine
./verify.sh                         # Linux: everything (build, suite, results against clang, benchmarks)
tests\run.bat                       :: Windows: the suite with build\alc.exe, no Wine
tests\run.bat -j 4 -v shaderc       :: Windows: the tests named *shaderc*, 4 threads, ok lines too
tests\run.bat --target linux        :: Windows: the programs built and type-checked for Linux, not run
verify.bat                          :: Windows: build, both of the above, one line VERIFY: PASS or VERIFY: FAIL
```

**Before every commit** run `verify.bat` (Windows) or `./verify.sh` (Linux) on the tree exactly
as it will be committed, after the last edit, and commit only on `VERIFY: PASS`. A suite run
from before the last change (an edit, a rebase, a merge, another commit on the branch) says
nothing about the commit: an expected output can go stale in between, as one did. A run of
`tests\run.bat` with a filter is for working on a change, not for committing it.

The runner is an AL program, `tests/run.al` (its top lists the kinds of tests and their
files); `build.sh` / `build.bat` build it with the new compiler as `build/altest` and
`build/altest.exe`, and `tests/run.sh` / `tests\run.bat` only start it in the repository root
(`run.sh` rebuilds it when `tests/run.al` is newer, `run.bat` always, with `build.bat
--runner`). A test run keeps the runner and the compiler open, and Windows writes no file of a
running program: `build.bat` therefore builds each under another name and leaves the old one
in place when the bytes are the same; a changed one replaces it, and a running one is renamed
away first (`build\altest.old*.exe`, removed by a later build), so `build.bat --quick` and a
second `tests\run.bat` work while tests run (`build.sh` does the same with `mv`, which Linux
allows over a running program). It can also be started
directly from there: `build/alc run tests/run.al -- -v ./build/alc match`.

- **Options**: `-j N` threads (default: one per CPU; `-j 1` runs one test after the other),
  `-v` also prints `ok   name` for every test that passed, `--target linux|windows`,
  `--host-wine alc.exe` (Linux), and the words `[path/to/alc] [filter]`, before or after the
  options. Two words are the compiler and the filter; one word alone is the compiler if it
  names a file or has a directory in it (`./build/alc`, `build\alc.exe`), else the filter
  (`tests\run.bat -j 4 shaderc`), with the default compiler (`./build/alc`, Windows
  `build/alc.exe`). A compiler that does not exist or does not answer `alc --version` stops
  the run at once with one message and status 2. Output: `FAIL name: reason` with the first
  lines of a diff or of the messages, `SKIP name: reason`, and `conformance: N passed, M
  failed, K skipped` at the end; the exit status is 0 if nothing failed.
- **Expected files** (`NAME.out`, `NAME.err`, `NAME.fmt`) are compared byte for byte, since a
  program's exact output matters: they use LF line endings and have no byte order mark.
  PowerShell writes neither by default (`Set-Content` and `>` give CRLF, a BOM or UTF-16):
  write them from bash or cmd (`build\alc.exe run t.al > tests\run\t.out` in cmd), or with
  `[IO.File]::WriteAllText(path, text)` and `\n`. A `.out` or `.err` that differs only in its line endings
  or a BOM fails with that reason (`tests/run/t.out has CRLF line endings: expected files
  must use LF`), not with a diff of lines that look the same.
- **Parallel.** Each test (a program with its three build modes, a check, a driver script) is
  one job with a directory of its own under the temporary directory; the jobs are spread over
  the threads, except those of `tests/sys`: they run when the others are done, one after the
  other, with the machine to themselves (they share its display, sound and GPU, and window
  and pointer tests depend on timing). The modes of one program run in order,
  because a test may write a file named after itself. The lines are printed in the order of
  the tests, so two runs print the same text. Every program runs with a limit of 60 seconds
  (status 124); a Windows program is then ended with everything it started (a process group
  or job: the program under `alc run`, the processes of Wine).
  Measured on 12 CPUs against the bash script the runner replaced (which ran the tests one
  by one), the same 877 / 830 results each: Linux 60 s -> 29 s (of which `tests/sys` alone
  22 s: `vk_present` takes 16 s), `--target windows` 67 s -> 23 s, `--host-wine` 116 s ->
  35 s; `-j 1` 55 s; `build/altest.exe` itself under Wine 36 s.
- **Tools.** Nothing but the compiler is needed for most tests. A test that needs more is
  reported as `SKIP` with the reason when it is missing: a C compiler for the tests with a C
  library (`tests/sys/NAME.c`: clang on Linux; MinGW-w64 for Windows programs, as
  `x86_64-w64-mingw32-gcc` or, on Windows, `gcc`), what `NAME.need` asks for on Linux
  (libraries, weston, an X display in `AL_TEST_DISPLAY`), the DLLs `NAME.windows.need` lists
  for a Windows program run on Windows (found through `PATH`; under Wine such a test is
  skipped: `shaderc_shared.dll` of the Vulkan SDK), what only the program can tell
  (status 77: no Direct3D 12 device). `--target windows` on Linux needs Wine and
  stops without it. `tests/driver` (bash scripts for the Linux command line) runs on Linux
  for the Linux target only.
- **On Windows** the tests are those of `--target windows` (skip list `tests/windows.skip`),
  run directly; the default mode of every program goes through `alc run` and the unit tests
  through `alc test`, as with `--host-wine`, so the compiler's own process handling is
  tested too. Linux programs cannot run there: `--target linux` builds each in its three
  modes (those with a `NAME.need` are skipped: the check is a Linux shell command),
  type-checks `tests/check` and `tests/fail` and runs the `--all-targets` checks.
- **Wine** (Linux, `--target windows`): the prefix `$WINEPREFIX` (default
  `tmp/win/prefix-tests`) with the null display driver, `DISPLAY` and `WAYLAND_DISPLAY`
  removed, no sound device, no crash dialog (a program that crashes ends at once with the
  debugger's report on standard error); one Wine server for the run, which the runner stops
  at the end.
  After Ctrl+C `tests/run.sh` stops that server (and with it the Windows programs) and
  removes the run's temporary directory, which it hands to the runner in `ALTEST_TMP`.
- **`verify.sh` stays a bash script and a Linux job.** Beyond the build and the suite it
  compares f32 results and ten benchmarks with clang -O2, reads ELF headers with readelf and
  greps the sources: none of that exists on a Windows machine, and all of it tests the
  compiler's output, which is byte-identical whichever host built it (`build.sh
  --windows-check`, `build.bat`). `verify.bat` is what Windows can add: the compiler rebuilds
  itself there, and the programs it builds run on real Windows.
- **`alc fmt`**: `tests/fmt/NAME.al` with the expected result `NAME.fmt` (or `NAME.err` for a
  file with a syntax error), and `fmt/tree` (`tests/fmt/tree/check.al`), which formats copies of
  every `.al` file of the repository, builds the compiler from the formatted sources and
  formats scrambled layouts back (about 20 s; `check ALC DIR ROUNDS SEED` runs more rounds of
  scrambling). It runs where the compiler's target is the machine (not under Wine). Tests whose
  layout is the point carry `// alc fmt: off`; fmt/tree checks that those lines stay as they are.
- `tests/winabi/run.sh`, `tests/winaudio/run.sh` (Wine, MinGW, PipeWire) and the fuzzers in
  `tests/gen/` (Python) are Linux tools as before.

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
| `src/types.al`, `lower*.al` | type checking fused with lowering to SSA IR: `lower.al` (declarations, instantiation), `lower_fn.al`, `lower_expr.al`, `lower_call.al`, `lower_vec.al` (vector / matrix types), `lower_mem.al` (builtin names shared with declared functions, `Vec` indexing, `clone`), `lower_nested.al` (nested functions), `lower_ccall.al` (calls of C functions on arm64: AAPCS64) |
| `src/lint.al` | checks on the AST that need types: field writes to a struct copy that is never read |
| `src/fmt.al` | `alc fmt` ([DETAILS.md](DETAILS.md#alc-fmt)): white space between the tokens of the lexer, comments from the gaps between them; the parser marks the `{` of literals (`parser_lits`, recorded only while `alc fmt` parses). `comment_lines` gives `alc sigs` the comments of a file the same way |
| `src/ir.al` | IR, dominators, loops, printer, verifier |
| `src/opt/*.al` | optimiser passes; `mod.al` is the pipeline |
| `src/spread.al` | what the two back-end drivers share: the reachable functions (`Refs`), the number of threads and the parallel compile of functions (`spread_run`) |
| `src/regalloc.al` | the register allocator of both back ends (iterated register coalescing: liveness, interference graph, coalescing, simplify / select, spill choice and spill rounds), generic over the target's machine function and instruction types; the target supplies the rest ([register allocation](#register-allocation)) |
| `src/x86/*.al` | instruction selection, the x86-64 part of register allocation (register file, spill code with memory operands), encoder; `mod.al` is the backend driver |
| `src/arm64/*.al`, `src/elf_arm64.al` | the arm64 back end (`--target linux-arm64`) and its ELF writer: instruction selection, the arm64 part of register allocation (register file, spill loads and stores), encoder, driver ([arm64 target](#arm64-target)) |
| `src/elf.al` | ELF writer (Linux) |
| `src/pe.al` | PE32+ writer (Windows, `--target windows`): sections, DLL import table, base relocations |
| `src/rsrc.al` | the resources of a Windows executable (`.rsrc`): manifest, icon (`--icon`), version information (`--version-info`); included by `pe.al` |
| `src/backtrace.al` | the table of the stack traces of panics (frames, source lines), added to the module before linking |
| `src/debug.al`, `dwarf.al`, `pdb.al` | debug information (`-g`, see DETAILS.md): the variables and function lines recorded while lowering and in isel / emit, the line rows and scopes both formats share; DWARF 4 sections for `elf.al` and `pe.al`; the PDB of a Windows executable |
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
  anything touches a TLS global. Windows: a TLS directory (template: the block's size
  in zero bytes in `.data`, `SizeOfZeroFill` 0, since the Windows loader allocates only the
  template's size; `AddressOfIndex` = `__win_tls_index`); a TLS global is an offset (`win_tls_off`, from `layout_tls`) from a
  register that holds the address of the thread's block, so an access is `mov rax, [r + off]`
  (an 8-bit offset for the arena) and needs no relocation. A function has one such register
  (`tls_base` in `src/x86/isel.al`), set by three loads (`tls_place`: `gs:[0x58]`, the TEB's
  array of blocks; `__win_tls_index`; the entry) before the first use in a block, before the
  outermost loop around a use, and not where such a place dominates: at most once per block
  that needs it, not inside a loop, not on a path without a TLS global unless a loop with one
  follows. The loads are repeated on a path through several such places (the same value).
  What was measured and rejected: **Thread block on Windows** below. Programs without
  threads differ from before only in that: the
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

**Thread block on Windows.** Linux reaches a TLS global with one `fs`-relative instruction;
Windows has no register for it, only the TEB (`gs`), whose array of thread blocks is indexed
by a number the loader chooses. Before, every TLS global a function used cost four
instructions (the three loads and a `lea`) where its `GAddr` stood after GVN / LICM:
`__heap_cur` and `__heap_end` of one allocation paid twice. Measured under Wine 11.22 on a
Ryzen 5 3600 (Windows builds, relocatable images; user-mode instructions and cycles counted
with `perf_event_open`; times: best of 5, interleaved, the best of four Wine sessions;
before -> now):

| program | instructions | time |
|---|---|---|
| `bench/binarytrees.al` (308 million allocations) | 12.49 G -> 10.94 G (-12.4 %) | 1307 -> 1163 ms (median of the four sessions 1316 -> 1282 ms) |
| the same, its hot functions at 8 code offsets 16 bytes apart | | cycles: median 5013 M -> 4849 M (-3.3 %), lowest 4734 M -> 4530 M, highest 5260 M -> 5324 M |
| `bench/hashmap.al` (no allocation in its loop) | 1.249 G -> 1.249 G | 567 -> 557 ms |
| a loop of `put` (20 million) | 2.865 G -> 2.345 G (-18 %) | 464 -> 462 ms |
| the compiler compiling itself | 10.54 G -> 10.38 G (-1.4 %) | 1222 -> 1210 ms |
| the same at `-O0` | 3.28 G -> 3.29 G | 289 -> 280 ms |
| the same on one thread (`ALC_JOBS=1`) | 10.13 G -> 9.99 G (-1.3 %) | 1443 -> 1429 ms |
| size of `alc.exe` | | 4,523,520 -> 4,420,096 bytes (-2.3 %) |

The instructions are exact; the times are not a steady measure. Only binarytrees moves
beyond the noise (about 3 % at the median), and there the same instructions take 4.4 to 5.6 G
cycles depending on where the code lies and where the loader puts the image (the best time of
a session of the new build lay between 1163 and 1306 ms): the old sequences were loads that
do not depend on the allocation before, which the processor runs beside the chain that most
likely sets the time (store `__heap_cur` -> load `__heap_cur` of consecutive allocations).
Linux runs binarytrees in 9.86 G instructions and 4.19 to 4.53 G cycles (median 4.31 G) at
the same 8 offsets: Windows is left with 3 instructions per allocating call and about 12 %
of cycles. Variants, measured on binarytrees before the images became relocatable (median
cycles over the 8 offsets; before 4.99 G, the place per block 4.86 G):

- *One place per function* (the nearest block that dominates all uses): the same
  instructions, 19 % more cycles than the place per block (5.78 G against 4.86 G; the loads
  then stand before the branch that separates the leaf from the inner node). Rejected.
- *The index taken as 0* (`mov r, gs:[0x58]; mov r, [r]`): 2.8 % fewer instructions, cycles
  3 % lower, inside the spread of the offsets (the index load does not lengthen the chain of
  dependent loads). The loader gives the program's block index 0 on Wine also when a DLL with
  thread-local data of its own is loaded with it, and on Windows as far as known, but nothing
  promises it, and a check per access costs what it saves. Rejected.
- *A pointer to the block in a TEB field* (`ArbitraryUserPointer`, `gs:[0x28]`): 5.7 % fewer
  instructions, cycles 1 % lower (inside the spread). The field is the debugger's and the
  loader's, other run-time libraries have used it for the same purpose (Go's on
  windows/amd64), and every thread would have to set it before its first access: threads
  that C libraries create do not (their callbacks run AL code). In the experiment, where only
  the library's own threads set it, `alc.exe` ended without output (most likely for this
  reason: it works on a thread it makes with `CreateThread` itself, for the large stack).
  Rejected.
- *A register reserved for the block in all AL code, or the block passed as a hidden
  argument*: could at most close the rest of the gap to Linux on such a recursion, and costs
  a register everywhere; an AL function is called by C as it is (callbacks, on any thread),
  so every function whose address is taken would need a second entry. Not built.
- *Hoisting out of loops* needed nothing new: the address was loop-invariant for LICM before
  (a `GAddr` is pure), and the place before the outermost loop keeps that (a loop that
  allocates a million nodes: 6.111 G instructions before and now, Linux 6.000 G).

## Register allocation

One allocator serves both back ends: `src/regalloc.al` (iterated register coalescing after
George and Appel) is generic over the target's machine function type `F` (`MFunc`, `AFunc`)
and instruction type `I` (`MInst`, `AInst`): `ra_allocate[MFunc, MInst]` in
`src/x86/regalloc.al`, `ra_allocate[AFunc, AInst]` in `src/arm64/regalloc.al`. AL has no
traits; a generic function is compiled per type like a template, so the shared code calls the
target's functions by name (`ra_decode(mf, ..)`, `ra_order(mf, cls)`, ...: the list is at the
top of `src/regalloc.al`), and overloading on `*MFunc` / `*AFunc` picks the target's. These
functions are `inline`, and the constant ones ignore their argument (`ra_npre` gives the number
of machine registers, 32 or 65, for an `Irc[F]` without reading anything), so each instance is
the code a copy of the allocator for one target would be: comparing the selected machine code
of the compiler's allocator functions before and after the change, the hot ones (graph
building, simplify, coalesce, the Briggs and George tests, liveness, select) differ only in
frame slot numbers and the lengths of the "file:line" strings of their bounds checks; the
self-compile takes the same time (best of 7 runs, interleaved, three times: optimised 1150 to
1155 ms against 1154 to 1164 ms before, `-O0` 260 to 261 ms against 261 to 266 ms).

Shared: decoding the instructions once per round, liveness, the interference graph (bit
matrix or hash set, the lists), coalescing, simplify / freeze / spill choice, select with
biased colouring, the spill rounds (choice of the registers, new slots, temporaries loaded
before and stored after, unspillable temporaries), the rewrite to machine registers.
Per target, because only the target knows it: the register file and allocation order, the
call clobbers, which registers an instruction defines and uses (`mir_decode` / `a_decode`:
x86-64 two-address operations and fixed registers, the early-clobber operands of the arm64
atomic loops are expressed there as defs, uses and machine registers), the spill code
(`ra_spill_load` / `ra_spill_store`, and `ra_spill_direct`: x86-64 accesses a slot as a memory
operand of the instruction where one is allowed, arm64 turns a copy with one spilled side into
the load or store), and the pass after allocation that forwards spill slots kept in registers
and removes dead stores (`ra_spill_forward`): it recognises the target's spill code and
rewrites it in the target's forms (x86-64 replaces memory operands of any instruction and
also removes stores that a later one overwrites; arm64 has only loads to rewrite), so a shared
version would be little more than the per-block state (`ra_st_*`, shared).

The result (`RaResult`, in `Alloc` / `AAlloc` as `assign`) includes where each virtual
register ended up: `RaAssign` (machine register by node, or the spill slot of a register that
was spilled), built at the end of `ra_allocate`: the place for debug information on
register-allocated variables to read the assignment.

## Parallel back end

`x86_compile` and `a64_compile` (the arm64 back end) compile functions independently of each
other. With more than one CPU and enough functions (**Number of threads** below) the
compiler's thread and worker threads compile them together, on Linux and Windows alike
(`compile_spread` in `src/x86/mod.al` and `src/arm64/mod.al`, with what both share in
`src/spread.al`: `spread_run`, the reachable functions; the threads are the run-time
library's, started by `worker_start` in `src/base.al`). The functions are in one list, largest first, and every thread takes the next
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

**Number of threads** (`spread_threads` in `src/spread.al`), the compiler's thread included:
one per CPU (Linux: the CPUs of `sched_getaffinity`, limited by a cgroup quota in
`/sys/fs/cgroup/cpu.max`; Windows: `GetActiveProcessorCount`), at most 32, and at most one per
24 functions at `-O0` (where the threads also optimise them) or per 12 functions when
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

The rule gives hello world 3 threads, `clone.al` 6 at `-O0` and 6 optimised,
`index_scale.al` 5, `gen_dx12.al` 12 and 11, the compiler 12. Against the earlier fixed 6
(best of 5 to 9 runs, interleaved): hello world 10.3 → 9.4 ms at `-O0`, the compiler 132 →
122 ms at `-O0` and 922 → 905 ms optimised, generated programs of 1000 and 3000 functions 79
→ 70 and 217 → 188 ms at `-O0`; the programs with 80 to 350 functions within about 1 ms either
way, the run-to-run spread of the same thread count. The cap of 32 is not measured: there the
largest functions start to bound the gain (the compiler's largest takes 6 ms of its 255 ms
`-O0` back end) while every thread still costs 5-10 MB.

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
indirect, `spec`: no specialised copies; the loop passes of `src/opt/loop.al`: `ldelete`,
`stepexit`, `idiom` (fill / copy loops to MemSet / MemCpy), `lsr` (or its parts `widen`, `sr`;
`rebase` is off in the source), `vectorize` (the loop vectorizer, `src/opt/vec.al`: SSE2 vector
loops of 128-bit lane types `VI8`..`VF64` / `V4` and `Op.VBin`, x86-64 only), `rtunroll` (runtime unrolling), and LICM's `promote`; `checkor` (runs of checks against one power-of-two length become one check of the OR of the indices) and `checkarms` (the same check at the start of both arms of a branch moves ahead of it), both in src/opt/checkmerge.al; `selfold` (selects on negated booleans or on their own condition) and `selbr` (a select on a branch's condition is that side's value below it), src/opt/simplify.al; `recinline` (one level of a small self-recursive function inlined into itself) and `reclimit` (off: a recursive function already inlined is inlined again at the calls its copy brought, as before), src/opt/inline.al; `alignbig` (x86: a loop larger than 64 bytes keeps its header out of the last 8 bytes of a line, and no executed padding goes in front of a loop that makes calls); alias
analysis (`src/opt/alias.al`): `fresh` (allocations as objects of their own), `linaddr`
(addresses as linear forms); loadelim's `ldcarry` (loop-carried forwarding); the register
allocator's `remat` (constants and addresses repeated instead of spilled); outside the optimiser `constif`: `if` on a constant
is not decided while lowering, `deaddata`: all read-only data is linked, `backtrace`: no stack-trace table, `sinkstep`: the x86 back end leaves the step of an induction variable before the loop's compare); `ALC_STD_DIR=<dir>` reads bundled modules from
`<dir>` instead of the copies inside the compiler (such a module, except a core one, is
type-checked in full also by `alc build` / `run`, which otherwise compile only what a program
reaches of a module); `ALC_PRELUDE=<file>` reads the prelude
from `<file>` and the OS layer from `prelude_linux.al` / `prelude_windows.al` next to it (no
layer if there is none: the file is then the whole run-time library), so
`ALC_PRELUDE=src/prelude.al` tests library changes without a rebuild; `ALC_ALIGN=0` turns off the padding that keeps small innermost x86 loops inside one 32- or 64-byte block (`loop_pads` in `src/x86/emit.al`), `ALC_ALIGN=1` aligns every innermost loop to 16 instead;
`ALC_PE_BASE=<hex>` builds a Windows executable for another preferred base (for the relocation test below);
`ALC_DBGLOC=<function>` (with `-g`, optimising) prints what the variable locations of that
function are found from (src/debug.al: the values recorded by source location, the machine
code and the values each register and slot holds before every instruction).

## Windows target

`--target windows` sets `target_os` (`src/main.al`); the front end and the optimiser are the
same, the differences are:

- **Calling convention** (Microsoft x64, for every function, so that any AL function value is
  a C callback). `abi_param` / `abi_ret` (`src/lower.al`): an aggregate of 1, 2, 4 or 8 bytes
  is one integer leaf read and written as untyped memory, any other goes by reference (a copy
  the caller makes) or, as a result, through a hidden pointer that the callee also returns;
  `extern` calls take the same path as calls of AL functions, through the IAT slot. The back
  end (`params_win` and `call` in `src/x86/isel.al`) assigns registers by position, numbers
  stack arguments by position (words 0-3 are the shadow space every call reserves). A call of
  a variadic C function (`CallInd` with aux 2, set by `emit_call` in `src/lower_call.al`) also
  copies each floating-point argument of the first four slots into the slot's integer register.
  (On Linux every C call already sets `al`, aux 1; the promotions of the arguments for `...`
  are made in `vararg`, `src/lower_call.al`, for both targets.)
- **Preserved registers.** rsi, rdi (`mir_callee_saved`) and xmm6-xmm15 (`mir_xmm_saved`,
  saved in the frame) are saved by a function that writes them. Calls are still taken to
  clobber them (`CALL_CLOBBER` is the Linux set), which keeps the register allocator the same.
- **Stack probes.** A frame of 4096 bytes or more is allocated a page at a time, touching each
  page (`stack_probe` in `src/x86/emit.al`): the stack grows through a guard page.
- **Addresses.** The image is relocatable and its base is above 4 GiB, so the code holds no
  absolute address. The encoder (`src/x86/emit.al`) addresses a global, a float constant and an
  import slot relative to rip (`Rel32Global`, `Rel32FConst`; the addend counts an immediate
  that follows the displacement, `rip_end`) and loads the address of a global or function
  with `lea r, [rip + x]` where Linux has `mov r, imm32`. A rip-relative operand takes no
  base or index register: where instruction selection has folded a global with one
  (`table[i]`), `rip_legal` (`src/x86/isel.al`) first loads the global's address into a
  register (one more `lea` than on Linux; +0.0 to +0.7 % code, no measurable time). A
  thread-local global is an offset from the register of the thread block (Threads, above),
  not a field for the linker; `pe_link` checks that the code has no absolute field (`Abs32*`).
- **Linking** (`pe_link`): preferred base 0x140000000, `DYNAMIC_BASE | HIGH_ENTROPY_VA`;
  sections `.text`, `.rdata`, `.pdata`, `.idata` (import descriptors, lookup tables, the IAT,
  which holds the import slots), `.data` (with the zero data), `.rsrc` (`src/rsrc.al`: the
  manifest, the icon, the version information; a three-level directory of type, id and
  language) and `.reloc`: the base relocation table, one `DIR64` entry for every absolute
  address in the image: the pointers in global data (`Global.relocs`: strings, function
  values, the stack-trace table) and the four addresses of the TLS directory. Import, unwind
  and resource tables hold RVAs and need none. Whoever adds an absolute address to the image
  adds its RVA to `fix`. The entry point is `__entry`, stack reserve 16 MiB. A reachable
  `syscall` is an error.
- **Unwind information.** Every function with a frame gets an UNWIND_INFO (`unwind_info` in
  `src/x86/emit.al`, kept in `Code.unwind`: pushes, the allocation, the xmm saves of its
  prologue) and a `.pdata` entry, so that the system can walk the stack through AL frames
  (exception dispatch, debuggers); functions without a frame are leaf functions.
- **Run-time library.** `src/prelude_windows.al` replaces `src/prelude_linux.al` (kernel32.dll
  only); the bundled modules with Linux interfaces (`std.x11`, `std.wayland`, `std.alsa`) are
  refused (`LINUX_ONLY` in `src/main.al`; `std.libc`, `std.vk` and `std.shaderc` are not among
  them: they choose their library, `msvcrt.dll`, `vulkan-1.dll`, `shaderc_shared.dll`, with a
  `when`), and
  the modules with an OS layer include the target's one with `when TARGET_OS == ...`.
  `tests/run.sh --target windows` runs the conformance suite under Wine (skip list:
  `tests/windows.skip`).
- `tests/winabi/run.sh` checks the convention against C compiled by MinGW, under Wine;
  `tests/sys/c_variadic` checks calls of variadic C functions against the same C library built
  by clang (Linux) and MinGW (`--target windows`).
- **The image as a file**: `tests/pe/check.py` reads PE files. `reloc A.exe B.exe` applies
  the relocation table of a program built for one base and compares the result, byte for
  byte, with the same program built for another (`ALC_PE_BASE`): a missed address would still
  hold the old base. `rsrc` prints the resources after checking the directory. Both run in
  `tests/driver/pe.sh` (part of `tests/run.sh`: the compiler, two games, the options and their
  errors). `tests/pe/run.sh` runs `tests/pe/res.al` under Wine, which (from 9.x) loads a
  `DYNAMIC_BASE` image at a random address as Windows does: the program asks the system for
  its base, the manifest's settings, the icon and the version information; every program of
  `tests/run.sh --target windows` runs relocated as well. (The icon and version resources
  are byte-identical to what GNU `windres` makes from the equivalent `.rc` file.)

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

## arm64 target

`--target linux-arm64` makes an AArch64 Linux executable: static, or dynamically linked when
it calls C functions. The front end and the optimiser are the same as for x86-64 (`target_os`
is Linux); the differences are:

- **Back end** (`src/arm64/`): `mir.al` (three-address machine IR; x16, x17, x18, x29, x30
  and v31 are reserved), `isel.al` (selection from the SSA IR, one plain selection per
  operation; narrow integers extended where their upper bits matter, as on x86-64),
  `regalloc.al` (the arm64 part of the register allocator of `src/regalloc.al`: 26 general and
  31 SIMD registers; spill code is loads and stores), `emit.al` (frame record in every
  function, encoding, branch fixups, ADRP/ADD relocations, LL/SC loops for atomics), `enc.al`
  (one pure function per instruction form), `backtrace.al` (the stack-trace table in the
  format of `src/backtrace.al`), `mod.al` (driver; functions are compiled by several threads
  as on x86-64, see [parallel back end](#parallel-back-end); the source files of the compiled
  code are recorded per function before it is compiled and merged in the order of the
  functions).
- **Calling convention**: AAPCS64 for AL functions: x0-x7 / v0-v7, results in x0-x3 / v0-v3,
  further arguments in 8-byte stack words (a vector in two, as on x86-64).
  For scalars this is the C convention too, so any AL function with scalar parameters is a C
  callback as it is (x19-x28 and d8-d15 preserved, sp 16-byte aligned at calls, x18 untouched).
- **C calls** (`src/lower_ccall.al`): a call of an `extern` function is laid out by the lowering,
  where the C types are known, by the rules of AAPCS64 (integers, floats, structs by value:
  HFAs in v registers, composites of up to 16 bytes in x registers, larger ones by reference,
  "no register left" moving the argument and everything after it of its class to the stack;
  results in x0/x1, v0-v3 or memory whose address goes in x8; narrow integers extended to 32
  bits). It makes `CallInd` with aux `CCALL_AUX` (3) and k = number of x registers | number of v
  registers << 4 | an x8 pointer << 8, the arguments in that order, then the stack pieces (one
  8-byte slot each); `call` in `src/arm64/isel.al` only places them (fixed registers in the
  instruction's `xuses`, as for any call; x8 is a clobbered register the allocator knows). The
  optimiser leaves calls with aux != 0 alone (no inlining, devirtualisation, specialisation). A
  C function that takes or returns a struct cannot be a function value (a call through one has
  the AL convention). The import slot is loaded with ADRP + LDR (`LdrG`, relocation
  `AR_LDR64`).
- **Linking** (`src/elf_arm64.al`): segments aligned to 64 KiB; the entry stub of a static
  program puts the main thread's TLS block (variant I: TPIDR_EL0, a 16-byte TCB, then the block)
  below the initial stack. A program that reaches a C function is dynamically linked as on
  x86-64 (ET_EXEC at 0x400000, PT_INTERP `/lib/ld-linux-aarch64.so.1`, DT_NEEDED, undefined
  dynamic symbols, a SysV hash table, one `R_AARCH64_GLOB_DAT` per import slot, BIND_NOW, no
  PLT, DT_DEBUG; sections `.interp`, `.dynstr`, `.dynsym`, `.hash`, `.rela.dyn`, `.dynamic`);
  its entry stub only calls `__entry`: the C library's loader owns TPIDR_EL0 and gives every
  thread the executable's block at TPIDR_EL0 + 16 (glibc and musl place it there for a PT_TLS
  aligned to 16), which is what the code addresses. Run-time library layer:
  `src/prelude_linux_arm64.al` (the generic system call table). Its thread functions for a
  program that declares C functions (`__os_c_thread_create` / `__os_c_thread_join`: the C
  library's `pthread_create`, found through r_debug and DT_GNU_HASH as on x86-64) replace
  `__os_thread_create` / `__os_thread_join` by name in `program` (src/main.al), which renames
  the clone-based ones to `__os_clone_thread_*`: other programs never refer to them, so static
  programs are built exactly as before (an `if` on a constant would still have changed the
  numbering of functions at -O0 and the inlining of `__thread_main`). Stack traces stop at the
  first C frame (no CFI unwinder for arm64 yet). `TARGET_ARCH` is declared by each OS layer
  (at its end).
- **The compiler for arm64**: `alc build --target linux-arm64 -D HOST_ARM64=true src/main.al`
  (`HOST_ARM64` in `src/base.al` selects `src/host_linux_arm64.al`).
- **Tests**: `tests/unit/arm64_enc.al` (the encoder against known encodings),
  `tests/arm64/check.al` (structural check of the executables: decoding, branches, stack
  pointer, registers read before written; the dynamic section, symbols, relocations and import
  slots; the argument registers of every C call of a program whose source declares the C
  function, by the independent classifier `tests/arm64/aapcs.al`, which `tests/unit/aapcs64.al`
  checks against clang's placements), `tests/arm64/emu.al` (a user-mode emulator; the
  runner takes `--target linux-arm64 --emu build/a64emu.exe`, `tests/arm64_emu.skip` lists
  what it cannot run). The emulator is also the dynamic loader of such programs (the libraries
  of DT_NEEDED from `A64EMU_LIBRARY_PATH` / `LD_LIBRARY_PATH`, their relocations, the main
  thread's block as glibc makes it, r_debug); the runner builds the C library of a
  `tests/sys/NAME.c` with clang for it (`--target=aarch64-linux-gnu`, freestanding, ld.lld:
  `clang` in PATH or `ALTEST_CLANG`), so `tests/sys/c_abi` runs AL code against C that clang
  compiled, in both directions. What only real hardware can check: `docs/ARM64_TEST.md`.

## macOS target

`--target macos` (experimental, never run) sets `target_os` to `TargetMacOS` and `target_arch`
to arm64: the arm64 back end with these differences.

- **Linking** (`src/macho.al`): a PIE Mach-O for macOS 11+ in 16 KiB pages: `__PAGEZERO`,
  `__TEXT` (`__text`: an entry stub that dyld calls as `main`, passing argv on to `__entry`;
  `__const`), `__DATA_CONST` (`__got`, the import slots; the read-only globals that hold
  addresses), `__DATA` (`__data`, `__thread_vars`, `__thread_bss`, `__bss`), `__LINKEDIT`
  (chained fixups in format `DYLD_CHAINED_PTR_64`, the exports trie, symbols, the indirect
  symbols of `__got`, the code signature). Load commands as ld64 writes them (LC_MAIN,
  LC_LOAD_DYLINKER, LC_LOAD_DYLIB per library (libSystem first), LC_BUILD_VERSION 11.0,
  LC_UUID from the SHA-256 of the file, LC_CODE_SIGNATURE: an ad-hoc, linker-signed
  CodeDirectory over 4 KiB pages, hashed by `src/sha256.al`). Its output is the same for any
  `ALC_JOBS`; the signature's identifier is the output's file name.
- **Thread-local data**: the block of the calling thread is the result of the program's one
  thread-local variable descriptor (`Tlv` in src/arm64: `adrp`/`add x0`, `ldr x16, [x0]`,
  `blr x16`, modelled as an instruction that defines x0, as a system call does: the thunk keeps
  every other register but x16, x17, x30, which the allocator never uses). Decision: TLV
  descriptors rather than a pthread key. dyld allocates the block of every thread on its first
  use, also of threads that C libraries start (whose callbacks run AL code that allocates); a
  key would need a check and a slow path at every access for such threads, or reading Apple's
  private TSD slots directly (as Go does). TPIDR_EL0, which the Linux layer owns, is not the
  program's on Darwin. Cost: a call per access of a function's first thread-local global in a
  block, where Linux has `mrs`.
- **Calling convention**: Apple's variant for C calls (src/lower_ccall.al: stack arguments packed
  at their size, variadic arguments all on the stack) and for AL functions too (`mac_slot` in
  src/arm64/isel.al), so that AL functions stay C callbacks. Not done: narrow results of AL
  functions are not extended to 32 bits (Apple's callers expect it).
- **Run-time library**: `src/prelude_macos.al` over libSystem (`extern`s: macOS has no stable
  system call interface); error numbers mapped to Linux ones; locks with `__ulock_wait` /
  `__ulock_wake`; threads with pthreads; processes with fork / execve. `TARGET_OS == MacOS`.
- **Tests**: `tests/macho/check.al` (structural, also on a file made by ld64.lld),
  `tests/unit/aapcs64.al` (Apple's rows), llvm-objdump by hand. What only a Mac can check:
  `docs/MACOS_TEST.md`.
