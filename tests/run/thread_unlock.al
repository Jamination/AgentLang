use std.os

fn main() {
    mu: Mutex
    lock(&mu)
    t, _ := thread_spawn(fn(m: *Mutex) {
        unlock(m)
    }, &mu)
    thread_join(&t)
}
