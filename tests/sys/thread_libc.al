// threads of a dynamically linked program call the C library, which keeps state per thread
// (errno) and is thread-safe: thread_spawn makes them with pthread_create
use std.os

extern "libc.so.6" fn strlen(s: *u8) -> i64
extern "libc.so.6" fn getenv(name: *u8) -> *u8
extern "libc.so.6" fn snprintf(buf: *u8, n: i64, f: *u8, x: i64) -> i32
extern "libc.so.6" fn __errno_location() -> *i32
extern "libc.so.6" fn close(fd: i32) -> i32

struct Res { ok: i64, errno: i32, where: i64, path: bool }

fn work(a: (i64, *Res)) {
    k, r := a
    buf: [64]u8
    for i in 0..2000 {
        x := k * 10000 + i
        n := snprintf(&buf[0], 64, ptr("v=%ld"), x)
        if strlen(&buf[0]) == i64(n) && from_cstr(&buf[0]) == fmt("v=", x) {
            r.ok += 1
        }
    }
    close(-1)
    r.errno = *__errno_location()
    r.where = cast[i64](__errno_location())
    r.path = len(from_cstr(getenv(ptr("PATH")))) > 0
}

fn main() {
    rs := alloc[Res](8)
    ts := vec[Thread]()
    for k in 0..8 {
        t, ok := thread_spawn(work, (k, &rs[k]))
        assert ok
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    wheres := vec[i64]()
    good := 0
    for r in rs {
        if r.ok == 2000 && r.errno == 9 && r.path && !wheres.contains(r.where) {
            good += 1
        }
        wheres.push(r.where)
    }
    print(good, !wheres.contains(cast[i64](__errno_location())))
}
