// std.libc: a few C library functions. Using any of them makes the program dynamically linked.
// Linux: glibc (libc.so.6, libm.so.6). Windows: msvcrt.dll, the C run-time library that is
// part of every Windows and exports the printf family as variadic functions (the UCRT,
// ucrtbase.dll, has them only as functions that take a va_list).
// The printf family is variadic: the arguments after the format follow the C default argument
// promotions (an untyped integer literal is an `i32`, so `%lld` wants `i64(42)`; pass strings
// as `ptr(s)` / `cstr(s)`). Output of printf / fprintf is buffered by the C library, apart
// from AL's own: `flush()` before and `fflush(nil)` after keep the order.
// The same on both systems: strlen, getenv, malloc, free, qsort, printf, fprintf, sprintf,
// sscanf, fflush, cosf, getpid, c_stdout, c_stderr. More: docs/std/libc.md.

// the C library and the maths library of each system
when TARGET_OS == Windows {
    priv const LIBC = "msvcrt.dll"
    priv const LIBM = "msvcrt.dll"
} else when TARGET_OS == MacOS {
    priv const LIBC = "/usr/lib/libSystem.B.dylib"
    priv const LIBM = "/usr/lib/libSystem.B.dylib"
} else {
    priv const LIBC = "libc.so.6"
    priv const LIBM = "libm.so.6"
}

extern LIBC fn strlen(s: *u8) -> i64
extern LIBC fn getenv(name: *u8) -> *u8
extern LIBC fn malloc(n: i64) -> *u8
extern LIBC fn free(p: *u8)
extern LIBC fn qsort(base: *u8, n: i64, size: i64, cmp: fn(*u8, *u8) -> i32)
extern LIBC fn printf(format: *u8, ...) -> i32
extern LIBC fn fprintf(stream: *u8, format: *u8, ...) -> i32
extern LIBC fn sprintf(buf: *u8, format: *u8, ...) -> i32
extern LIBC fn sscanf(s: *u8, format: *u8, ...) -> i32
extern LIBC fn fflush(stream: *u8) -> i32
extern LIBM fn cosf(x: f32) -> f32

// what differs
when TARGET_OS == Windows {
    extern "msvcrt.dll" fn _getpid() -> i32
    // not C's snprintf: no NUL when the text takes n bytes or more, and then the result is -1
    extern "msvcrt.dll" fn _snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32
    // the three standard streams, an array of FILE (48 bytes each): stdin, stdout, stderr
    extern "msvcrt.dll" fn __iob_func() -> *u8
    extern "msvcrt.dll" fn _fileno(stream: *u8) -> i32
    // _setmode(_fileno(c_stdout()), O_BINARY): the stream writes "\n" as it is, not as "\r\n"
    extern "msvcrt.dll" fn _setmode(fd: i32, mode: i32) -> i32

    const O_BINARY: i32 = 0x8000
    const O_TEXT: i32 = 0x4000

    fn getpid() -> i32 {
        return _getpid()
    }

    // C's stdout and stderr (macros there: Windows has no such variables)
    fn c_stdout() -> *u8 {
        return ptr(mkslice[u8](__iob_func(), 144)[48..])
    }

    fn c_stderr() -> *u8 {
        return ptr(mkslice[u8](__iob_func(), 144)[96..])
    }
} else when TARGET_OS == MacOS {
    extern "/usr/lib/libSystem.B.dylib" fn getpid() -> i32
    extern "/usr/lib/libSystem.B.dylib" fn dprintf(fd: i32, format: *u8, ...) -> i32
    extern "/usr/lib/libSystem.B.dylib" fn snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32
    extern "/usr/lib/libSystem.B.dylib" __stdoutp: *u8
    extern "/usr/lib/libSystem.B.dylib" __stderrp: *u8
    extern "/usr/lib/libSystem.B.dylib" fn dlopen(path: *u8, flags: i32) -> *u8
    extern "/usr/lib/libSystem.B.dylib" fn dlsym(handle: *u8, name: *u8) -> *u8
    extern "/usr/lib/libSystem.B.dylib" fn dlerror() -> *u8

    fn c_stdout() -> *u8 {
        return __stdoutp
    }

    fn c_stderr() -> *u8 {
        return __stderrp
    }
} else {
    extern "libc.so.6" fn getpid() -> i32
    extern "libc.so.6" fn dprintf(fd: i32, format: *u8, ...) -> i32
    extern "libc.so.6" fn snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32
    extern "libc.so.6" stdout: *u8
    extern "libc.so.6" stderr: *u8
    extern "libc.so.6" fn dlopen(path: *u8, flags: i32) -> *u8
    extern "libc.so.6" fn dlsym(handle: *u8, name: *u8) -> *u8
    extern "libc.so.6" fn dlerror() -> *u8

    // C's stdout and stderr, under the names that also exist on Windows
    fn c_stdout() -> *u8 {
        return stdout
    }

    fn c_stderr() -> *u8 {
        return stderr
    }
}
