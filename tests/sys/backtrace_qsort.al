// a panic in a comparison that the C library's qsort called: the trace shows the frames of qsort
// (glibc, built by GCC) between those of the program
use std.libc

fn check(x: i32) {
    assert x != 3, "comparing 3"
}

fn by_value(a: *u8, b: *u8) -> i32 {
    x := cast[*i32](a)[0]
    check(x)
    return x - cast[*i32](b)[0]
}

noinline fn sort(a: *[6]i32) {
    qsort(cast[*u8](ptr(*a)), 6, 4, by_value)
}

fn main() {
    a: [6]i32
    for i in 0..6 {
        a[i] = i32((i * 7 + 3) % 6)
    }
    print("start")
    sort(&a)
    print(a)
}
