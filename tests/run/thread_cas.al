// compare-and-swap loops: a lock-free stack of nodes allocated by the threads (read after the
// joins), a counter, and bits set with atomic_or / atomic_xor
use std.os

struct Node { value: i64, next: *Node }

struct Shared { head: *Node, counter: i64, bits: u32 }

fn push(s: *Shared, v: i64) {
    n := new[Node]()
    n.value = v
    loop {
        old := atomic_load(&s.head)
        n.next = old
        _, ok := atomic_cas(&s.head, old, n)
        if ok {
            break
        }
    }
}

fn worker(a: (*Shared, i64)) {
    s, k := a
    for i in 0..1000 {
        push(s, k * 1000 + i)
        loop {
            c := atomic_load(&s.counter)
            _, ok := atomic_cas(&s.counter, c, c + 2)
            if ok {
                break
            }
        }
    }
    atomic_or(&s.bits, u32(1) << u32(k))
    atomic_xor(&s.bits, u32(1) << u32(k + 16))
}

fn main() {
    s: Shared
    ts := vec[Thread]()
    for k in 0..8 {
        t, _ := thread_spawn(worker, (&s, k))
        ts.push(t)
    }
    for i in 0..ts.len {
        thread_join(&ts[i])
    }
    n := 0
    sum := 0
    seen := vec_fill(8000, false)
    p := s.head
    while p != nil {
        n += 1
        sum += p.value
        seen[p.value] = true
        p = p.next
    }
    print(n, sum, s.counter, hex(u64(s.bits)), !seen.contains(false))
    print(atomic_and(&s.bits, 0xFF), hex(u64(s.bits)))
    old, ok := atomic_cas(&s.counter, 1, 5)
    print(old, ok)
    for i in 0..ts.len {
        region_free(&ts[i].region)
    }
}
