use std.os

fn deep(n: i64) -> i64 {
    a: [64]i64
    a[n % 64] = n
    return deep(n + 1) + a[3]
}

fn main() {
    t, _ := thread_spawn(fn(n: i64) { print(deep(n)) }, 0, 256 << 10)
    thread_join(&t)
}
