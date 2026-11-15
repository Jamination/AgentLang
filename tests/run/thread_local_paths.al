// The thread's own data (arena, regions, I/O state) on many paths through a function: in
// both arms of a branch and after it, first inside nested loops, in a loop that may not run,
// in loops one after the other, behind calls, in every arm of a match, in a recursion. The
// main thread and 8 threads at once must get the same results. (Windows: the address of the
// thread's block is set where a function first needs it, before a loop that needs it.)
use std.os

struct Node { next: *Node, v: i64 }

fn list_sum(p: *Node) -> i64 {
    s := 0
    while p != nil {
        s += p.v
        p = p.next
    }
    s
}

// both arms allocate, the code after them too
fn arms(n: i64) -> i64 {
    head: *Node = nil
    for i in 0..n {
        if i % 3 == 0 {
            head = &Node{head, i}
        } else {
            head = &Node{head, -i}
            head = &Node{head, 2 * i}
        }
        head = &Node{head, 1}
    }
    list_sum(head)
}

// the first allocation is three loops deep, in one arm only
fn deep(n: i64, on: bool) -> i64 {
    s := n
    if on {
        for a in 0..n {
            for b in 0..3 {
                for c in 0..3 {
                    p := &Node{nil, a + b + c}
                    s += p.v
                }
            }
        }
    }
    s
}

// a loop that may not run at all, with the allocation behind a condition
fn maybe(n: i64) -> i64 {
    head: *Node = nil
    i := 0
    while i < n {
        if i & 1 == 1 {
            head = &Node{head, i}
        }
        i += 1
    }
    list_sum(head)
}

// loops one after the other: the first one leaves through a `break`
fn twice(n: i64) -> i64 {
    head: *Node = nil
    i := 0
    loop {
        if i >= n {
            break
        }
        head = &Node{head, i}
        i += 1
    }
    while i > 0 {
        head = &Node{head, -1}
        i -= 2
    }
    list_sum(head)
}

// marks and regions around calls that allocate
fn scoped(n: i64) -> i64 {
    r := region()
    s := 0
    for i in 0..n {
        m := mark()
        v := vec[i64]()
        for k in 0..=i {
            v.push(k)
        }
        enter(&r)
        w := clone(v)
        leave()
        s += w.len + v[i]
        if i % 4 == 3 {
            reset(&r)
        }
        release(m)
    }
    s += used(&r)
    region_free(&r)
    s
}

// every arm of a match allocates something else
fn kinds(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        match i % 4 {
            0 => {
                s += len(fmt("k", i))
            }
            1 => {
                p := &Node{nil, i}
                s += p.v
            }
            2 => {
                a := alloc[i64](i + 1)
                a[i] = 3
                s += a[i] + len(a)
            }
            _ => {
                s -= 1
            }
        }
    }
    s
}

fn tree(d: i64) -> *Node {
    if d == 0 {
        return &Node{nil, 1}
    }
    &Node{tree(d - 1), list_sum(tree(d - 1))}
}

// a failed call sets the thread's io_error on one path only
fn missing(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        _, ok := read_file(fmt("tests/run/no-such-file-", i))
        if !ok && io_error() != 0 {
            s += 1
        }
    }
    s
}

fn all() -> i64 {
    m := mark()
    s := arms(100) + 3 * deep(20, true) + 5 * deep(20, false) + 7 * maybe(0) + 11 * maybe(51)
    s += 13 * twice(40) + 17 * scoped(30) + 19 * kinds(64) + 23 * list_sum(tree(10)) + 29 * missing(3)
    release(m)
    s
}

fn work(a: (i64, *i64)) {
    k, out := a
    s := 0
    for round in 0..20 {
        s = all()
    }
    *out = s + k
}

fn main() {
    want := all()
    print(want, arms(100), deep(20, true), maybe(51), twice(40), scoped(30), kinds(64), list_sum(tree(10)), missing(3))
    outs := alloc[i64](8)
    ts := vec[Thread]()
    for k in 0..8 {
        t, ok := thread_spawn(work, (k, &outs[k]))
        assert ok
        ts.push(t)
    }
    good := 0
    for k in 0..ts.len {
        thread_join(&ts[k])
        if outs[k] == want + k {
            good += 1
        }
    }
    print(good, all() == want)
}
