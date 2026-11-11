// std.libc: a few C library functions. Using any of them makes the program dynamically linked.
extern "libc.so.6" fn getpid() -> i32
extern "libc.so.6" fn strlen(s: *u8) -> i64
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libc.so.6" fn malloc(n: i64) -> *u8
extern "libc.so.6" fn free(p: *u8)
extern "libc.so.6" fn qsort(base: *u8, n: i64, size: i64, cmp: fn(*u8, *u8) -> i32)
extern "libc.so.6" fn snprintf(buf: *u8, n: i64, fmt: *u8, a: f64, b: i64) -> i32
extern "libc.so.6" fn dlopen(path: *u8, flags: i32) -> *u8
extern "libc.so.6" fn dlsym(handle: *u8, name: *u8) -> *u8
extern "libc.so.6" fn dlerror() -> *u8
extern "libm.so.6" fn cosf(x: f32) -> f32
extern "libm.so.6" fn pow(x: f64, y: f64) -> f64
