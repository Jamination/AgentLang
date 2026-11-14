// a Map shared by many threads, every update under a Mutex; try_lock
use std.os

struct Ctx { m: *Map[str, i64], mu: *Mutex }

fn worker(c: Ctx) {
    for i in 0..2000 {
        key := fmt("k", i % 100)
        lock(c.mu)
        c.m.set(key, c.m.get_or(key, 0) + 1)
        unlock(c.mu)
    }
}

fn try_it(a: (*Mutex, *bool)) {
    got := try_lock(a.0)
    if got {
        unlock(a.0)
    }
    *a.1 = got
}

fn main() {
    m := map[str, i64]()
    mu: Mutex
    ts := vec[Thread]()
    for k in 0..8 {
        t, _ := thread_spawn(worker, Ctx{&m, &mu})
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    bad := 0
    for k in m.keys() {
        if m.get_or(k, 0) != 160 {
            bad += 1
        }
    }
    print(m.len, bad, m.get_or("k7", 0))
    got := true
    lock(&mu)
    t, _ := thread_spawn(try_it, (&mu, &got))
    thread_join(&t)
    print("while locked:", got)
    unlock(&mu)
    t2, _ := thread_spawn(try_it, (&mu, &got))
    thread_join(&t2)
    print("after unlock:", got, try_lock(&mu), try_lock(&mu))
    unlock(&mu)
}
