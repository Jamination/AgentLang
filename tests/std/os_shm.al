// std.os shared memory: an anonymous file, two shared mappings of it, a read-only private one;
// file descriptors; failures through io_error().
use std.os

fn why() -> str { error_text(io_error()) }

fn main() {
    fd, ok := shm_create(8192)
    print("shm_create:", ok, fd > 2, io_error())
    a, ok_a := map_shared(fd, 8192)
    b, ok_b := map_shared(fd, 8192)
    print("map_shared:", ok_a, ok_b, len(a), len(b), ptr(a) != ptr(b), a[0], a[8191])
    // two mappings, one memory
    for i in 0..len(a) { a[i] = u8(i % 251) }
    sum := 0
    for x in b { sum += i64(x) }
    print("shared:", b[1], b[250], b[251], b[8191], sum)
    words := mkslice[u32](cast[*u32](ptr(b)), 2048)
    words[7] = 0xA1B2C3D4
    print("as u32:", a[28], a[31])
    r, ok_r := map_readonly(fd, 4096)
    print("map_readonly:", ok_r, len(r), r[28], r[100])
    // the descriptor can be closed; the mappings stay
    print("close_fd:", close_fd(fd), "again:", close_fd(fd), why())
    a[100] = 7
    print("after close:", b[100])
    print("unmap:", unmap(a), unmap(b), unmap(r), io_error())

    // failures
    _, bad1 := map_shared(fd, 4096)
    print("closed descriptor:", bad1, why())
    fd2, _ := shm_create(16)
    _, bad2 := map_shared(fd2, 0)
    print("size 0:", bad2, why())
    _, bad3 := shm_create(-1)
    print("negative size:", bad3, why())
    close_fd(fd2)
    // many in a row: nothing leaks
    for i in 0..200 {
        f, okf := shm_create(65536)
        m, okm := map_shared(f, 65536)
        if !okf || !okm { print("failed at", i, why()); break }
        m[65535] = 1
        close_fd(f)
        unmap(m)
    }
    print("done")
}
