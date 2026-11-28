# std.libc: a few functions of the C library

`use std.libc`. Source: `std/libc.al`. Raw declarations of C library functions, for programs
that talk to C code: the printf family (variadic), `qsort` with an AL function as its callback,
`malloc` / `free` for memory that a C library takes over, `strlen`, `getenv`. AL's own
library needs none of them; a program that calls one is linked against the C library
(Linux: a dynamically linked executable; Windows: one more DLL in its import table).

| | Linux | Windows | macOS |
|---|---|---|---|
| library | glibc: `libc.so.6` (`cosf`: `libm.so.6`) | `msvcrt.dll` | `/usr/lib/libSystem.B.dylib` |

Anything else of the C library is declared the same way in the program itself
(`extern "msvcrt.dll" fn strtol(s: *u8, end: **u8, base: i32) -> i32`), inside
`when TARGET_OS == Windows { ... } else { ... }` if it is for both systems
([C interop](../DETAILS.md#c-interop)).

## Declarations

On both systems, with the same meaning:

| Declaration | C |
|-------------|---|
| `strlen(s: *u8) -> i64` | length of a C string |
| `getenv(name: *u8) -> *u8` | an environment variable, `nil` if it is not set (read it with `from_cstr`). Windows: text in the code page of the process, which is UTF-8 on Windows 10 1903 and later (the executable's manifest asks for it) and the system's code page before: `env_get` of the core library is UTF-8 everywhere |
| `malloc(n: i64) -> *u8`, `free(p: *u8)` | memory of the C library's heap |
| `qsort(base: *u8, n: i64, size: i64, cmp: fn(*u8, *u8) -> i32)` | sorts `n` elements of `size` bytes; `cmp` is any AL function with that signature, also a nested or anonymous one |
| `printf(format: *u8, ...) -> i32` | to the C library's standard output |
| `fprintf(stream: *u8, format: *u8, ...) -> i32` | to a `FILE*`: `c_stdout()`, `c_stderr()` |
| `sprintf(buf: *u8, format: *u8, ...) -> i32` | into a buffer that must be large enough |
| `sscanf(s: *u8, format: *u8, ...) -> i32` | reads values from a C string; every further argument is a pointer |
| `fflush(stream: *u8) -> i32` | writes what the stream has buffered; `fflush(nil)`: every stream |
| `c_stdout() -> *u8`, `c_stderr() -> *u8` | C's `stdout` and `stderr` |
| `getpid() -> i32` | the process id (`process_id()` of std.os needs no C library) |
| `cosf(x: f32) -> f32` | (the math functions of AL are built in: [math](math.md)) |

Only one of the two systems has these:

| Linux only | Instead, on Windows |
|------------|---------------------|
| `snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32` | `_snprintf` (below), or `sprintf` into a buffer that is large enough, or AL's `fmt` / `fmtf` |
| `dprintf(fd: i32, format: *u8, ...) -> i32` | none (`fprintf` to a stream) |
| `stdout: *u8`, `stderr: *u8` (C variables) | `c_stdout()`, `c_stderr()`: in the Windows C library `stdout` is a macro, there is no such variable |
| `dlopen`, `dlsym`, `dlerror` | `LoadLibraryW`, `GetProcAddress` of kernel32.dll, declared by the program |

| Windows only | |
|--------------|---|
| `_snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32` | **not C's `snprintf`**: writes at most `n` bytes; when the text has `n` bytes or more there is **no NUL** at the end, and when it has more the result is -1 (C: the length the text needs) |
| `_getpid() -> i32` | what `getpid()` calls |
| `__iob_func() -> *u8` | the array of the three standard streams (48 bytes each): what `c_stdout()` / `c_stderr()` index |
| `_fileno(stream: *u8) -> i32`, `_setmode(fd: i32, mode: i32) -> i32`, `O_BINARY`, `O_TEXT` | the mode of a stream: see [Standard output](#standard-output-of-c-and-of-al) |

## Variadic functions and formats

The arguments after the format are passed as C passes them
([default argument promotions](../DETAILS.md#c-interop)): `i8`, `i16`, `u8`, `u16`, `bool`
arrive as an `int`, `f32` as a `double`; an untyped integer literal is an `i32` if it fits.
Strings are passed as `ptr("literal")` or `cstr(s)`, never as a `str`. Nothing checks that the
arguments fit the format.

The two C libraries do not read every format alike. The same on both:

| Format | Argument |
|--------|----------|
| `%d`, `%u`, `%x`, `%o`, `%c` | `i32` / `u32` (or anything narrower) |
| `%lld`, `%llu`, `%llx` | `i64` / `u64`: `printf(ptr("%lld"), i64(n))` |
| `%f`, `%.2f`, `%g` | `f64`, `f32` |
| `%s` | `*u8` |
| width, precision, flags: `%5d`, `%-5d`, `%05.1f`, `%5s` | |

Different:

| Format | Linux (glibc) | Windows (msvcrt.dll) |
|--------|---------------|----------------------|
| `%ld`, `%lu` | `long` has 64 bits: an `i64` | `long` has 32 bits: an `i32`. For 64 bits `%lld` works on both (`%I64d` is the old Windows spelling) |
| `%p` | `0xbeef`, `(nil)` | `000000000000BEEF`, `0000000000000000` |
| `%e`, and `%g` when it uses an exponent | `1.23e+03` | `1.23e+003` (three digits) |
| `%zu`, `%hhd`, `%jd`, `%td` (C99 sizes) | yes | not part of msvcrt.dll: convert to `i32` / `i64` and use `%d` / `%lld` |
| `sscanf` `%ld` | fills an `i64` | fills an `i32`; `%lld` fills an `i64` on both |

## Standard output of C and of AL

The C library buffers what `printf` and `fprintf` write, and AL buffers what `print` and
`put` write: two buffers for the same file, each written when it is full or flushed.

- **Order.** `flush()` before C output and `fflush(nil)` (or `fflush(c_stdout())`) after it:
  then the lines appear in the order of the program. Without them AL's lines and C's lines
  each stay in order, but not with each other.
- **At the end of the program** call `fflush(nil)` if C output may still be buffered. A
  program ends with the exit system call, not with C's `exit`: on Linux the C library never
  writes what it still holds (after a panic too); msvcrt.dll writes it when the process ends,
  after AL's own output.
- **Standard error.** C's `stderr` is not buffered; `eprint` / `eput` write at once too (after
  flushing AL's standard output), so `flush()` before `fprintf(c_stderr(), ...)` is all it
  takes.
- **Line ends (Windows).** The streams of msvcrt.dll start in text mode: every `"\n"` is
  written as `"\r\n"`, while AL writes bytes as they are. `_setmode(_fileno(c_stdout()),
  O_BINARY)` once at the start makes the stream write `"\n"` (the same for `c_stderr()`).
- **Text (Windows).** AL strings are UTF-8. The C library passes bytes through to a file or
  pipe unchanged, but writes to a console in the console's code page: non-ASCII text shows
  correctly only if that is UTF-8 (`chcp 65001`). `print` always shows UTF-8 correctly. C
  functions that take file names or return text (`fopen`, `getenv`) use the code page of the
  process: UTF-8 on Windows 10 1903 and later, through the executable's manifest.

```
use std.libc

fn main() {
    when TARGET_OS == Windows { _setmode(_fileno(c_stdout()), O_BINARY) }
    print("from AL")
    flush()                                             // AL's buffer first
    printf(ptr("from C: %d %s %.2f %lld\n"), 42, ptr("text"), 2.5, i64(1) << 40)
    fflush(nil)                                         // then C's
    buf: [64]u8
    n := sprintf(&buf[0], ptr("%05.1f|%-4d|"), 3.14159, 7)
    print(buf[..i64(n)])                                // 003.1|7   |
}
```

## Why msvcrt.dll

Windows has two C run-time libraries that a program can count on. What each exports was read
from the DLLs of Wine 11 and from the import libraries of mingw-w64 (made from the export
tables of Windows):

| | `msvcrt.dll` | UCRT (`ucrtbase.dll`, `api-ms-win-crt-*.dll`) |
|---|---|---|
| there on | every Windows | Windows 10 and later (older: with an update) |
| `printf`, `fprintf`, `sprintf`, `sscanf` | exported, variadic | **not exported**: only `__stdio_common_vfprintf(options, stream, format, locale, va_list)` and its relatives; `printf` is an inline function of the C headers around them |
| `snprintf` | no (`_snprintf`, `_vsnprintf`) | no (`__stdio_common_vsprintf`) |
| `qsort`, `strlen`, `getenv`, `malloc`, `free`, `fflush` | yes | yes |
| `stdout`, `stderr` | `__iob_func()` (also the data `_iob`): an array of `FILE` | `__acrt_iob_func(i)` |
| math | C89 with the `f` variants (`cos`, `cosf`, `pow`, `fmod`, ...); no `round`, `trunc`, `cbrt`, `log2`, `fma` | C99 complete |
| format strings | C89 with `ll` and `I64`; `long` is 32 bits | C99 |

A variadic `extern` declaration needs a variadic function in the DLL, and AL cannot define
one itself (nor build a `va_list`), so the printf family (the reason this module has variadic
declarations at all) can only come from `msvcrt.dll`. It is also there on every Windows
version without installing anything. The price is the older format language above. The math
functions it lacks are built into AL. A program that wants the UCRT declares what it needs:
`extern "ucrtbase.dll" fn round(x: f64) -> f64`.

**Threads.** Both C libraries are thread-safe and keep `errno` per thread (`__errno_location()`
of glibc, `_errno()` of msvcrt.dll); threads started with `thread_spawn` may call them
([os](os.md#threads)).

**Stack traces** go through frames of the C library: `  at msvcrt.dll qsort`
([DETAILS.md](../DETAILS.md#stack-traces)).
