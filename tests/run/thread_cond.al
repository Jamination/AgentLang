// producers and consumers on a bounded queue with a Mutex and two condition variables
use std.os

struct Queue {
    mu: Mutex
    not_empty: Cond
    not_full: Cond
    items: [16]i64
    head: i64
    n: i64
}

fn put_item(q: *Queue, x: i64) {
    lock(&q.mu)
    while q.n == 16 {
        wait(&q.not_full, &q.mu)
    }
    q.items[(q.head + q.n) % 16] = x
    q.n += 1
    signal(&q.not_empty)
    unlock(&q.mu)
}

fn take_item(q: *Queue) -> i64 {
    lock(&q.mu)
    while q.n == 0 {
        wait(&q.not_empty, &q.mu)
    }
    x := q.items[q.head]
    q.head = (q.head + 1) % 16
    q.n -= 1
    signal(&q.not_full)
    unlock(&q.mu)
    return x
}

fn producer(a: (*Queue, i64)) {
    for i in 1..=1000 {
        put_item(a.0, a.1 * 10000 + i)
    }
}

fn consumer(a: (*Queue, *i64)) {
    loop {
        x := take_item(a.0)
        if x < 0 {
            return
        }
        atomic_add(a.1, x)
    }
}

fn main() {
    q: Queue
    sum: i64 = 0
    ps := vec[Thread]()
    cs := vec[Thread]()
    for k in 0..4 {
        t, _ := thread_spawn(producer, (&q, k))
        ps.push(t)
    }
    for k in 0..3 {
        t, _ := thread_spawn(consumer, (&q, &sum))
        cs.push(t)
    }
    for i in 0..ps.len {
        thread_join(&ps[i])
    }
    for i in 0..cs.len {
        put_item(&q, -1)
    }
    for i in 0..cs.len {
        thread_join(&cs[i])
    }
    print(sum, q.n)
    // a wait with a time limit that nobody signals
    c: Cond
    lock(&q.mu)
    print(wait(&c, &q.mu, 2000000))
    unlock(&q.mu)
    broadcast(&c)
}
