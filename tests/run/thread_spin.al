// spin-waits on atomic_load: the loads must not be hoisted out of the loops
use std.os

struct Msg { flag: *i64, data: *i64 }

fn producer(m: Msg) {
    *m.data = 42
    atomic_store(m.flag, 1)
}

fn pong(turn: *i64) {
    for i in 0..2000 {
        while atomic_load(turn) != 1 {}
        atomic_store(turn, 0)
    }
}

flag: bool

fn waiter(n: i64) {
    while !atomic_load(&flag) {}
    print("flag seen", n)
}

fn main() {
    f: i64 = 0
    d: i64 = 0
    t, ok := thread_spawn(producer, Msg{&f, &d})
    while atomic_load(&f) == 0 {}
    print(ok, d)
    thread_join(&t)
    turn: i64 = 0
    t2, _ := thread_spawn(pong, &turn)
    for i in 0..2000 {
        while atomic_load(&turn) != 0 {}
        atomic_store(&turn, 1)
    }
    thread_join(&t2)
    print("ping-pong", turn)
    t3, _ := thread_spawn(waiter, 7)
    atomic_store(&flag, true)
    thread_join(&t3)
}
