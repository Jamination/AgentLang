struct Heap { a: []i64, n: i64 }

fn push(h: *Heap, x: i64) {
    i := h.n
    h.n += 1
    while i > 0 {
        p := (i - 1) / 2
        if h.a[p] <= x {
            break
        }
        h.a[i] = h.a[p]
        i = p
    }
    h.a[i] = x
}

fn pop(h: *Heap) -> i64 {
    top := h.a[0]
    h.n -= 1
    x := h.a[h.n]
    n := h.n
    i := 0
    loop {
        c := 2 * i + 1
        if c >= n {
            break
        }
        if c + 1 < n && h.a[c + 1] < h.a[c] {
            c += 1
        }
        if x <= h.a[c] {
            break
        }
        h.a[i] = h.a[c]
        i = c
    }
    h.a[i] = x
    top
}

fn main() {
    n := 1000000
    h := Heap{a: alloc[i64](n), n: 0}
    seed: u64 = 99
    check: u64 = 0
    for r in 0..3 {
        for i in 0..n {
            seed = seed * 6364136223846793005 + 1442695040888963407
            h.push(i64(seed >> 20))
        }
        // mixed phase: pop one, push one
        for i in 0..n {
            x := h.pop()
            check = check * 31 + u64(x)
            seed = seed * 6364136223846793005 + 1442695040888963407
            h.push(x + i64(seed >> 30))
        }
        prev := 0
        while h.n > 0 {
            x := h.pop()
            if x < prev {
                put("bad\n")
            }
            prev = x
            check = check * 31 + u64(x)
        }
    }
    put(check, "\n")
}
