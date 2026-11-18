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

Results there (2026-11-17, after the merge of release 0.4.0): the suite under the emulator
`conformance: 754 passed, 0 failed, 81 skipped` in 138 s with `-j 4` (35 need something of the
machine, 30 are built but not run because the emulator lacks processes, /proc or file maps or
is too slow for the 60 s limit, 16 are C-library, x86-64-only, `-g`, std.net or gamepad tests);
built only, `840 passed, 0 failed, 51 skipped`; the structural check `505 executables, 0
problems`; the compiler for linux-arm64 built by the x86-64 compiler (stage 1), by stage 1
under the emulator (stage 2, 187 s) and by stage 2 (stage 3, 191 s): byte-identical.
Refused for linux-arm64 with a message (not wrong code): `-g` and code of the bundled modules
that make system calls by their x86-64 numbers (std.net, the gamepads of std.input).

C functions (`extern`, since 2026-11-18): a program that calls one is a dynamically linked
executable (src/elf_arm64.al) and its C calls follow AAPCS64 (src/lower_ccall.al). No dynamic
loader or arm64 C library exists on the machine where this was written, so what was checked
there is: the emulator acting as the loader for libraries that clang 19 (Visual Studio's LLVM,
`--target=aarch64-linux-gnu`, freestanding, linked by ld.lld) built from C (`tests/sys/c_abi.c`:
every kind of argument and result in both directions, callbacks, preserved registers, the
stack alignment, a variable of the library, variadic calls; it passes, and the same test passes
on Windows against MinGW); the dynamic section, symbols, hash table, relocations and import
slots of every such executable (`tests/arm64/check.al`, and `llvm-readobj` by hand); every C
call site of `tests/sys/c_abi.al` against an independent classifier (`tests/arm64/aapcs.al`,
itself checked against clang's placements in `tests/unit/aapcs64.al`). What never ran: the
real `ld-linux-aarch64.so.1`, glibc or musl, `pthread_create` (threads of a dynamically linked
program), C libraries that use thread-local data or initialisers. Section 5 below.
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

## 5. C libraries and dynamic linking
Nothing of this ran against a real loader or C library (see the top). In order, each step
assuming the ones before it work:
1. A program with one C call starts at all:
   ```
   extern "libc.so.6" fn getpid() -> i32
   fn main() { print(getpid() > 0) }
   ```
   `readelf -lhd prog` shows PT_INTERP `/lib/ld-linux-aarch64.so.1`, PT_DYNAMIC, DT_NEEDED
   `libc.so.6`, FLAGS BIND_NOW; `readelf -r prog` one `R_AARCH64_GLOB_DAT getpid`. A crash
   before `main` points at the entry stub (`start_stub_dyn` in src/elf_arm64.al) or the import
   slot (`ldd prog`, `LD_DEBUG=all ./prog`). Also on a musl system (Alpine): the interpreter
   path differs there (`/lib/ld-musl-aarch64.so.1`), so it is expected to fail with "not found"
   unless a link is made; note it.
2. Thread-local data under the C library's loader: `print` (the output buffer is
   thread-local), `alloc` (the arena): `./alc-arm64 run examples/hello.al` with an `extern`
   added. A fault on the first output means the thread block is not at TPIDR_EL0 + 16 (glibc
   puts the executable's block at the 16-byte TCB rounded up to PT_TLS's alignment, 16).
3. `tests/sys/c_abi.al` against its C library built by the system's C compiler (gcc, then
   clang): `gcc -O2 -shared -fPIC -o libc_abi.so tests/sys/c_abi.c`, then
   `LD_LIBRARY_PATH=. ./c_abi a1 b2` must print `tests/sys/c_abi.out`, in all three build
   modes (`-O0`, `--unchecked`). This is the full check of the calling convention in both
   directions (structs by value, HFAs, x8 results, variadic calls, callbacks, x19-x28 and
   d8-d15 preserved, 16-byte stack alignment at calls).
4. The test runner: `./altest ./alc-arm64 sys/` runs the C-library tests the emulator could not:
   sys/c_variadic (glibc's `sprintf` too), sys/thread_libc (threads of a dynamically linked
   program: `pthread_create` looked up through the loader's r_debug, the C library's errno per
   thread), sys/thread_ccb and thread_ccb_panic (a C library's own thread calls the program:
   the thread block of a thread the program did not make), and the library tests of
   tests/sys with a NAME.need (Vulkan, X11, Wayland, ALSA, shaderc: whatever the machine has).
5. Stack traces through C frames are not implemented for arm64 (sys/backtrace_c_callback,
   backtrace_c_fault): the trace ends at the first C frame. Check that it ends cleanly (the
   message and the frames of the program up to the C frame, status 1, no second fault).
6. A program that declares C functions but calls none is static: `thread_spawn` must still work
   (clone).
