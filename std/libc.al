// std.libc: a few C library functions. Using any of them makes the program dynamically linked.
extern "libc.so.6" getpid :: () -> i32
extern "libc.so.6" strlen :: (s: *u8) -> i64
extern "libc.so.6" getenv :: (name: *u8) -> *u8
extern "libc.so.6" malloc :: (n: i64) -> *u8
extern "libc.so.6" free :: (p: *u8)
extern "libc.so.6" qsort :: (base: *u8, n: i64, size: i64, cmp: (*u8, *u8) -> i32)
extern "libc.so.6" snprintf :: (buf: *u8, n: i64, fmt: *u8, a: f64, b: i64) -> i32
extern "libc.so.6" dlopen :: (path: *u8, flags: i32) -> *u8
extern "libc.so.6" dlsym :: (handle: *u8, name: *u8) -> *u8
extern "libc.so.6" dlerror :: () -> *u8
extern "libm.so.6" cosf :: (x: f32) -> f32
extern "libm.so.6" pow :: (x: f64, y: f64) -> f64
