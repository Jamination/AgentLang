use std.libc
extern "libc.so.6" fn pipe(fds: *i32) -> i32
extern "libc.so.6" fn read(fd: i32, buf: *u8, n: i64) -> i64
extern "libc.so.6" fn close(fd: i32) -> i32

fn cmp_i32(a: *u8, b: *u8) -> i32 {
    x := cast[*i32](a)[0]
    y := cast[*i32](b)[0]
    if x < y { return -1 }
    if x > y { return 1 }
    return 0
}
fn main() {
    print(getpid() > 0, strlen(cast[*u8](ptr("hello\0"))))
    a: [6]i32
    for i in 0..6 { a[i] = i32((i * 7 + 3) % 6) }
    qsort(cast[*u8](ptr(a)), 6, 4, cmp_i32)
    print(a)
    buf: [64]u8
    n := snprintf(ptr(buf), 64, cast[*u8](ptr("%.3f|%ld\0")), 3.14159, i64(42))
    print(buf[..i64(n)], cosf(0.0), pow(f64(2.0), 10.0))
    p := malloc(100)
    print(p != nil)
    free(p)

    // variadic: snprintf with the usual conversions
    big: [256]u8
    u: u8 = 200
    n = snprintf(&big[0], 256, ptr("%d %ld %u %f %s %p %p %c %hhu %.2e"), -7, i64(-1) << 40, u32(3000000000), f32(0.25),
        ptr("str"), cast[*u8](0xbeef), nil, 'Q', u, 1234.5)
    print(n, from_cstr(&big[0]))
    // printf to standard output, ordered with AL's own output
    print("before")
    flush()
    printf(ptr("printf: %d %s %.1f\n"), 1, ptr("two"), 3.0)
    fflush(stdout)
    fprintf(stdout, ptr("fprintf: %lu\n"), u64(18446744073709551615))
    fflush(nil)
    print("after")
    // dprintf into a pipe, read back
    fds: [2]i32
    assert pipe(&fds[0]) == 0
    w := dprintf(fds[1], ptr("%d-%d-%d %x %o %5s|"), 1, 2, 3, 255, 8, ptr("ab"))
    close(fds[1])
    got := read(fds[0], &big[0], 256)
    close(fds[0])
    print(w, got, big[..got])
    // sscanf: pointers only
    x: i32
    y: f64
    word: [16]u8
    m := sscanf(ptr("12 2.5 abc"), ptr("%d %lf %15s"), &x, &y, &word[0])
    print(m, x, y, from_cstr(&word[0]))
}
