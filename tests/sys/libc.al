use std.libc
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
    n := snprintf(ptr(buf), 64, cast[*u8](ptr("%.3f|%ld\0")), 3.14159, 42)
    print(buf[..i64(n)], cosf(0.0), pow(2.0, 10.0))
    p := malloc(100)
    print(p != nil)
    free(p)
}
