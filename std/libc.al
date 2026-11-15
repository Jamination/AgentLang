// std.libc: a few C library functions. Using any of them makes the program dynamically linked.
// The printf family is variadic: the arguments after the format follow the C default argument
// promotions (an untyped integer literal is an `i32`, so `%ld` wants `i64(42)`; pass strings
// as `ptr(s)` / `cstr(s)`). Output of printf / fprintf is buffered by the C library, apart
// from AL's own: `flush()` before and `fflush(nil)` after keep the order.
extern "libc.so.6" fn getpid() -> i32
extern "libc.so.6" fn strlen(s: *u8) -> i64
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libc.so.6" fn malloc(n: i64) -> *u8
extern "libc.so.6" fn free(p: *u8)
extern "libc.so.6" fn qsort(base: *u8, n: i64, size: i64, cmp: fn(*u8, *u8) -> i32)
extern "libc.so.6" fn printf(format: *u8, ...) -> i32
extern "libc.so.6" fn fprintf(stream: *u8, format: *u8, ...) -> i32
extern "libc.so.6" fn dprintf(fd: i32, format: *u8, ...) -> i32
extern "libc.so.6" fn sprintf(buf: *u8, format: *u8, ...) -> i32
extern "libc.so.6" fn snprintf(buf: *u8, n: i64, format: *u8, ...) -> i32
extern "libc.so.6" fn sscanf(s: *u8, format: *u8, ...) -> i32
extern "libc.so.6" fn fflush(stream: *u8) -> i32
extern "libc.so.6" stdout: *u8
extern "libc.so.6" stderr: *u8
extern "libc.so.6" fn dlopen(path: *u8, flags: i32) -> *u8
extern "libc.so.6" fn dlsym(handle: *u8, name: *u8) -> *u8
extern "libc.so.6" fn dlerror() -> *u8
extern "libm.so.6" fn cosf(x: f32) -> f32
