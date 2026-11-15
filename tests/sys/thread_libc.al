// threads of a dynamically linked program call the C library, which keeps state per thread
// (errno) and is thread-safe: thread_spawn makes them with pthread_create (Windows:
// CreateThread; msvcrt.dll sets up its per-thread state when a thread first needs it)
use std.os

when TARGET_OS == Windows {
    extern "msvcrt.dll" fn strlen(s: *u8) -> i64
    extern "msvcrt.dll" fn getenv(name: *u8) -> *u8
    extern "msvcrt.dll" fn sprintf(buf: *u8, f: *u8, ...) -> i32
    extern "msvcrt.dll" fn strtol(s: *u8, end: **u8, base: i32) -> i32
    extern "msvcrt.dll" fn _errno() -> *i32

    fn errno_at() -> *i32 { _errno() }
} else {
    extern "libc.so.6" fn strlen(s: *u8) -> i64
    extern "libc.so.6" fn getenv(name: *u8) -> *u8
    extern "libc.so.6" fn sprintf(buf: *u8, f: *u8, ...) -> i32
    extern "libc.so.6" fn strtol(s: *u8, end: **u8, base: i32) -> i64
    extern "libc.so.6" fn __errno_location() -> *i32

    fn errno_at() -> *i32 { __errno_location() }
}

struct Res { ok: i64, errno: i32, where: i64, path: bool }

fn work(a: (i64, *Res, *i64)) {
    k, r, ready := a
    buf: [64]u8
    for i in 0..2000 {
        x := k * 10000 + i
        n := sprintf(&buf[0], ptr("v=%lld"), x)
        if strlen(&buf[0]) == i64(n) && from_cstr(&buf[0]) == fmt("v=", x) {
            r.ok += 1
        }
    }
    // a number beyond `long`: errno of this thread becomes ERANGE (34)
    strtol(ptr("99999999999999999999999999"), nil, 10)
    r.errno = *errno_at()
    r.where = cast[i64](errno_at())
    r.path = len(from_cstr(getenv(ptr("PATH")))) > 0
    // every thread still lives when the last has its errno: one that ended could hand its on
    atomic_add(ready, 1)
    while atomic_load(ready) < 8 {
        sleep_ms(1)
    }
}

fn main() {
    rs := alloc[Res](8)
    ts := vec[Thread]()
    ready := 0
    for k in 0..8 {
        t, ok := thread_spawn(work, (k, &rs[k], &ready))
        assert ok
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    wheres := vec[i64]()
    good := 0
    for r in rs {
        if r.ok == 2000 && r.errno == 34 && r.path && !wheres.contains(r.where) {
            good += 1
        }
        wheres.push(r.where)
    }
    print(good, !wheres.contains(cast[i64](errno_at())))
}
