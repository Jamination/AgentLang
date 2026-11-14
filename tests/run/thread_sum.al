// parallel sum: every thread adds its part with atomic_add; the total is read after the joins
use std.os

struct Part { lo: i64, hi: i64, total: *i64, done: *i32 }

fn add_part(p: Part) {
    s := 0
    for i in p.lo..p.hi {
        s += i
    }
    atomic_add(p.total, s)
    atomic_add(p.done, 1)
}

// many threads increment one counter: a lost update would show
fn bump(c: *u64) {
    for i in 0..100000 {
        atomic_add(c, 1)
    }
    for i in 0..1000 {
        atomic_sub(c, 1)
    }
}

fn main() {
    total: i64 = 0
    done: i32 = 0
    ts := vec[Thread]()
    for k in 0..16 {
        t, ok := thread_spawn(add_part, Part{k * 100000, (k + 1) * 100000, &total, &done})
        assert ok
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
        region_free(&ts[i].region)
    }
    print(total, done, total == 1600000 * 1599999 / 2, cpu_count() >= 1)
    c: u64 = 0
    bs := vec[Thread]()
    for k in 0..8 {
        t, _ := thread_spawn(bump, &c)
        bs.push(t)
    }
    for i in 0..bs.len {
        thread_join(&bs[i])
    }
    print(c, atomic_load(&c))
}
