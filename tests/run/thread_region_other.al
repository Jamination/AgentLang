use std.os

shared: Region

fn work(n: i64) {
    enter(&shared)
    leave()
}

fn main() {
    enter(&shared)
    t, _ := thread_spawn(work, 0)
    thread_join(&t)
    leave()
}
