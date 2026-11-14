use std.os

fn main() {
    t, _ := thread_spawn(fn(n: i64) {}, 0)
    t2 := t
    thread_join(&t)
    print("joined")
    thread_join(&t2)
}
