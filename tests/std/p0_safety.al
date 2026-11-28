// Regression tests for P0 stdlib safety and thread-safety fixes:
// - multithreaded `crc32` table initialization race in std.image
// - NUL-byte and path-traversal rejection in std.asset
// - concurrent Region reset/region_free safety
use std.os
use std.image

struct CrcJob { data: str, out: *u32 }

fn crc_worker(j: CrcJob) {
    *j.out = crc32(0, j.data)
}

fn main() {
    // 1. Concurrent crc32 initialization from 8 threads
    sample := "hello world from agentlang p0 safety test"
    results: [8]u32
    ts: [8]Thread
    for i in 0..8 {
        t, ok := thread_spawn(crc_worker, CrcJob{data: sample, out: &results[i]})
        assert ok
        ts[i] = t
    }
    for i in 0..8 {
        thread_join(&ts[i])
        region_free(&ts[i].region)
    }
    want := crc32(0, sample)
    all_eq := true
    for i in 0..8 {
        if results[i] != want {
            all_eq = false
        }
    }
    print("crc_threads:", all_eq, hex(u64(want), 8))

    // 2. Embedded NUL and traversal rejection in std.asset
    print("nul_exists:", file_exists("README.md\0extra"))
    _, ok1 := data_dir("../escape")
    e1 := io_error()
    _, ok2 := data_dir("/abs_escape")
    e2 := io_error()
    a := assets_new(".")
    _, ok3 := a.load("../escape.txt")
    e3 := io_error()
    _, ok4 := a.load("/etc/passwd")
    e4 := io_error()
    print("traversal:", ok1, e1, ok2, e2, ok3, e3, ok4, e4)
}
