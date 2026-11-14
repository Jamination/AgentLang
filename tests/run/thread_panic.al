use std.os

fn crash(n: i64) {
    if n > 2 {
        panic(fmt("bad value ", n))
    }
}

fn work(n: i64) {
    print("worker starts")
    crash(n)
}

fn main() {
    print("main")
    t, _ := thread_spawn(work, 3)
    thread_join(&t)
    print("not reached")
}
