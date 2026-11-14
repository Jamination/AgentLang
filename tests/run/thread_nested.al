// nested and anonymous functions as thread functions; generic contexts; a stack size
use std.os

struct Pair[A, B] { a: A, b: B }

fn start_all[T](xs: []T, f: fn(T)) {
    ts := vec[Thread]()
    for x in xs {
        t, ok := thread_spawn(f, x)
        assert ok
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
}

fn main() {
    total: i64 = 0
    fn add(a: (*i64, i64)) {
        atomic_add(a.0, a.1)
    }
    t1, _ := thread_spawn(add, (&total, 5))
    t2, _ := thread_spawn(fn(a: (*i64, []i64)) {
        for x in a.1 {
            atomic_add(a.0, x)
        }
    }, (&total, []i64{1, 2, 3}))
    thread_join(&t1)
    thread_join(&t2)
    print(total)
    n: i64 = 0
    start_all([]Pair[*i64, str]{Pair[*i64, str]{&n, "ab"}, Pair[*i64, str]{&n, "cde"}}, fn(p: Pair[*i64, str]) {
        atomic_add(p.a, len(p.b))
    })
    print(n)
    big: [64]i64
    t3, ok := thread_spawn(fn(p: *[64]i64) {
        fn depth(k: i64) -> i64 {
            pad: [32]i64
            pad[k % 32] = k
            return if k == 0 { 0 } else { depth(k - 1) + 1 + pad[0] * 0 }
        }
        p[0] = depth(5000)
        p[1] = thread_id()
    }, &big, 4 << 20)
    thread_join(&t3)
    print(ok, big[0], big[1], t3.id, thread_id())
}
