# Testing the arm64 target on real hardware

`--target linux-arm64` (src/arm64, src/elf_arm64.al, src/prelude_linux_arm64.al) was written on
an x86-64 Windows machine without any arm64 hardware, WSL or QEMU. What was checked there:

- the encoder, word by word, against known encodings (`tests/unit/arm64_enc.al`);
- every executable the suite builds, structurally (`tests/arm64/check.al`: ELF headers, every
  word decodes, branch and ADRP targets, the stack pointer on every path, no register read
  before every path writes it);
- the suite run under `tests/arm64/emu.al`, a user-mode emulator written for this purpose
  (`tests/run.sh --target linux-arm64 --emu build/a64emu`), and the compiler built for
  linux-arm64 compiling itself under it.

The emulator was written by the same hands as the back end: a misreading of the architecture
that both share (a flag of a compare, the extension of a load, the order of a pair) would not
show. These are the checks only a real machine (or QEMU, which is independent) can do. Run them
on a 64-bit Arm Linux (Raspberry Pi 4/5 with a 64-bit OS, AWS Graviton, an Ampere machine, or
`qemu-aarch64` user mode on an x86-64 Linux) and note any that fail, with the exact output.

## Setup
1. On an x86-64 Linux machine with the repository: `./build.sh`, then
   `./build/alc build --target linux-arm64 -D HOST_ARM64=true src/main.al -o alc-arm64`
   (the compiler for arm64) and copy the repository and `alc-arm64` to the arm64 machine. Or,
   with QEMU: `qemu-aarch64 ./alc-arm64 ...` for every command below (binfmt_misc makes that
   implicit).
2. `./alc-arm64 build examples/hello.al` then `./hello`: prints `hello from AL 42`.

## 1. The start of a program
1. `hello` runs at all: the entry stub, TPIDR_EL0 set by `msr` in user mode, the thread block
   below the initial stack. A crash here (SIGILL at the entry, SIGSEGV on the first thread-local
   access) points at `start_stub` in src/elf_arm64.al.
2. On a kernel with 16 KiB or 64 KiB pages (Apple silicon under Asahi Linux: 16 KiB; some
   server kernels: 64 KiB) the program loads: the segments are aligned to 64 KiB.
3. `readelf -lh hello`: machine AArch64, two LOAD segments, TLS, GNU_STACK; `objdump -d hello`
   disassembles without `.inst` words in the functions.

## 2. The test suite
1. Build the runner for arm64: `./alc-arm64 build tests/run.al -o altest`, then
   `./altest ./alc-arm64` (all tests, the programs built for the machine itself and run). Note
   the summary line, every `FAIL` and every `SKIP`.
2. Stack traces (src/arm64/backtrace.al: every function keeps a frame record, the prelude's
   walk finds the saved x30 at a fixed offset): tests/run/backtrace_*, thread_panic,
   thread_nil, thread_overflow, check_memory_frame, std/backtrace_module print the same
   frames as on x86-64. A stack overflow faults in the callee (BL does not touch the stack):
   the first frame of the trace is the callee's line, then the calls as on x86-64.
3. The tests the emulator could not run (tests/arm64_emu.skip: processes, /proc, /dev/full,
   ALC_CHECK_MEMORY page protection, memfd) run here for the first time: os, os_run,
   os_spawn, os_shm, portable_launch, portable_process, lib_stdout_errors, lib_alloc_limits,
   check_memory_stale, time_huge, thread_print, asset_cloexec, the unit tests with failing
   `test` blocks (unit/basic, unit/priv_tests: `__os_test` forks).
4. Faults: `tests/run/backtrace_nil.al`, `backtrace_overflow.al`: the program ends with
   status 1 and `panic: ... memory fault` / stack overflow messages (the SIGSEGV handler on
   the alternate stack reads the signal context at the offsets of the arm64 kernel:
   `uc_mcontext` at byte 176, pc at 176 + 8 + 256). Run them three times.
5. Threads: tests/run/thread_* and std/os_spawn_threads: clone with CLONE_SETTLS (the thread
   pointer of a new thread), futexes, the exclusive-access loops of atomics on a machine with
   several cores (the emulator ran threads one at a time: races only show here). Run
   `./altest -j 1 ./alc-arm64 thread` ten times.

## 3. The compiler on arm64
1. `./alc-arm64 build -D HOST_ARM64=true src/main.al -o alc2` then
   `./alc2 build -D HOST_ARM64=true src/main.al -o alc3`: `cmp alc2 alc3` (and both equal to
   `alc-arm64` built by the x86-64 compiler: the back ends are the same code).
2. `./alc-arm64 build --target linux src/main.al -o alc-x86` on arm64 is byte-identical to
   `./build/alc build --target linux src/main.al` on x86-64 (and `--target windows`).
3. Time `./alc2 build src/main.al` and `-O0`, for the record (x86-64: 0.9 s and 0.13 s on 12
   threads).

## 4. Numbers that differ by design from x86-64
- Floating-point to integer conversions out of range or of NaN give 0x8000... as on x86-64
  (src/arm64/emit.al, `Fcvtzs`): `print(i64(1e30), i32(0.0 / 0.0))` prints the same on both.
- Integer division by zero faults on both, also in `--unchecked` code: arm64 has no such
  fault, so the code tests the divisor (`cbnz`) and executes `brk #1`, whose SIGTRAP the run-time
  library reports as the arithmetic fault (`tests/run/backtrace_div.al --unchecked`). Check
  that the kernel delivers SIGTRAP for `brk` to the handler. `INT_MIN / -1` in `--unchecked`
  code faults on x86-64 and gives INT_MIN on arm64; checked code panics on both.
