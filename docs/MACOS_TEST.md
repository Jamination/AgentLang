# Testing the macOS target on a real Mac

`--target macos` (arm64: src/arm64, src/macho.al, src/prelude_macos.al) was written on an x86-64
Windows machine. **Nothing of it has ever run on macOS.** What was checked there:

- every program of tests/run, tests/std and examples that builds for macOS (514 executables,
  by default and -O0) by `tests/macho/check.al`: every load command, segment and section
  alignment (16 KiB pages), the chained fixups walked page by page (binds against the imports,
  rebases inside the image, every `__got` slot bound, the thread-local variable descriptor bound
  to `__tlv_bootstrap`), the symbol table against LC_DYSYMTAB and the indirect symbols, the
  exports trie, and the ad-hoc code signature with every page hash recomputed by an SHA-256
  independent of the compiler's. The same check passes on an executable that LLVM's Mach-O
  linker (ld64.lld 19, `-fixup_chains`) made from C, so it does not merely mirror src/macho.al;
- `llvm-objdump --macho --private-headers / --chained-fixups / --dyld-info / --exports-trie /
  --indirect-symbols -d` parse the files and agree (by hand, on hello and std.metal's triangle);
- the C calling convention: `tests/unit/aapcs64.al` (Apple's variant: stack arguments packed by
  size, variadic arguments on the stack) against clang's `--target=arm64-apple-macos11`
  placements, and the lowering's stores compared with clang's by hand for the same signatures.
  The arm64 code itself is the linux-arm64 back end, which runs under the project's emulator.

Run the steps in order on a Mac with Apple silicon (macOS 11 or later); each assumes the
earlier ones pass. Note every failure with the exact output. Build on any machine:
`alc build --target macos prog.al -o prog`, copy to the Mac.

## 1. Does it start
1. `examples/hello.al`: `./hello` prints `hello from AL 42`. If the kernel kills it at once
   ("Killed: 9"), the code signature is rejected: `codesign -v -v ./hello` says why;
   `codesign -d -v -v -v ./hello` shows the CodeDirectory (expect `flags=0x20002(adhoc,linker-signed)`,
   `hashes=N+0`, `CDHash=...`, Page size 4096). Re-signing with `codesign -s - -f ./hello`
   and running again tells a signature problem from a loading problem.
2. If dyld refuses it: `DYLD_PRINT_APIS=1 ./hello`, and `otool -l ./hello` (every load command:
   compare with the same for a C hello linked by Apple's ld), `dyld_info -fixups ./hello`
   (each `__got` slot bound to a libSystem symbol, `__thread_vars` to `__tlv_bootstrap`, the
   rebases of `__DATA_CONST,__const` and `__data`), `dyld_info -exports ./hello`.
3. `vmmap ./hello` while it runs (add a `sleep` to a test): __TEXT r-x, __DATA_CONST r--
   after start, __DATA rw-.

## 2. The run-time library (src/prelude_macos.al)
1. Thread-local data: `print` and `alloc` use it (the descriptor's thunk returns the thread's
   block; the code assumes the thunk keeps every register but x0, x16, x17 and x30). A crash in
   the first `print` points at `Tlv` in src/arm64 or at the descriptor in src/macho.al.
2. Arguments and environment: `tests/run/args*.al`, `env_get` (dyld passes argv to the entry
   stub, the environment follows it).
3. Files and directories: tests/std/asset*.al, os_files.al (stat layout, dirent layout,
   O_CLOEXEC = 0x1000000, the error numbers mapped to Linux ones by `linux_errno`).
4. Faults: tests/run/backtrace_nil.al, backtrace_overflow.al, backtrace_div.al: the signal
   handler reads the ucontext (mcontext pointer at byte 48, pc at 16 + 8 * 32) and si_addr at
   byte 24; expect the same panic messages and stack traces as on Linux. Division by zero is
   `brk #1` (SIGTRAP).
5. Threads: tests/run/thread_*.al (pthread_create; locks and condition variables with
   __ulock_wait / __ulock_wake). Run them ten times.
6. Processes: tests/std/os_run.al, os_spawn.al, portable_process.al (fork, execve, pipes made
   close-on-exec with fcntl, waitpid; `wait_ns` polls every millisecond: no pidfd on macOS).
7. Shared memory: tests/std/os_shm.al (shm_open with a unique name, unlinked at once).
8. Time: tests/std/time*.al (CLOCK_MONOTONIC is 6 on macOS).
9. The whole suite: the runner does not know `--target macos` yet; build each test with
   `alc build --target macos` and compare its output with NAME.out by hand or with a small
   script.

## 3. C libraries
1. `tests/sys/c_abi.al` with its C library built by Apple's clang:
   `clang -O2 -shared -o libc_abi.dylib tests/sys/c_abi.c` (change the library constant of the
   test to `"libc_abi.dylib"` for macOS, or use an absolute path), `DYLD_LIBRARY_PATH=. ./c_abi
   a1 b2` must print tests/sys/c_abi.out. This checks Apple's variant of the convention:
   variadic arguments on the stack, stack arguments packed, narrow arguments extended by the
   caller.
2. Known gaps to confirm or refute: an AL callback that returns an `i8`, `u8`, `i16`, `u16` or
   `bool` does not extend it to 32 bits (Apple's callers expect it: call_narrow of c_abi may
   fail here); calls through C function values (std.metal's `msg_*` through `objc_msgSend`)
   have the AL convention, which does not extend narrow arguments. AL functions on macOS take
   their stack arguments packed as Apple's convention does (src/arm64/isel.al, `mac_slot`):
   call_ints and call_mixed of c_abi check that.
3. std.metal: `tests/check/metal_triangle.al` builds for macOS (AppKit, QuartzCore, Metal and
   libobjc are linked); run it: a window with a triangle.

## 4. Numbers for the record
`ls -l` and `time ./prog` for hello, and the compile time of the compiler for macOS
(`alc build --target macos src/main.al` does not make a compiler that runs on macOS: there is no
host layer for macOS yet).
