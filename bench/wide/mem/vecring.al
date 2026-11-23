// Vec push / pop in a hot loop (amortized growth from empty) and a ring-buffer queue
struct Ring { buf: []i64, head: i64, tail: i64 }

fn ring_push(r: *Ring, x: i64) {
    r.buf[r.tail & (len(r.buf) - 1)] = x
    r.tail += 1
}

fn ring_pop(r: *Ring) -> i64 {
    x := r.buf[r.head & (len(r.buf) - 1)]
    r.head += 1
    x
}

fn main() {
    seed: u64 = 77
    total: u64 = 0
    for round in 0..60 {
        m := mark()
        v := vec[i64]()
        for i in 0..1000000 {
            v.push(i * 3)
            if i & 7 == 7 {
                // a stack pattern: pop a couple, push back their sum
                a := v.pop()
                b := v.pop()
                v.push(a + b)
            }
        }
        s: u64 = 0
        while v.len > 0 {
            s = s * 31 + u64(v.pop())
        }
        total += s
        release(m)
    }
    r := Ring{buf: alloc[i64](1 << 12), head: 0, tail: 0}
    for i in 0..1024 {
        ring_push(&r, i)
    }
    for i in 0..150000000 {
        x := ring_pop(&r)
        seed = seed * 6364136223846793005 + 1442695040888963407
        ring_push(&r, x + i64(seed >> 60))
        total += u64(x)
    }
    put(total, "\n")
}
