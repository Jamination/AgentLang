// Runtime unrolling (src/opt/unroll.al, unroll_runtime): loops with trip counts unknown at
// compile time are unrolled with a remainder loop, and integer reductions keep several
// partial results. The results must be those of the plain loops for every trip count around
// the unroll factors, empty and reversed ranges, narrow and unsigned counters, counting down,
// values used after the loop, and reductions that must not be split (floating point, values
// seen by the body, a partial result used later).

noinline fn sum_u8(b: []u8, lo: i64, hi: i64) -> u64 {
    s: u64 = 0
    for i in lo..hi {
        s += u64(b[i])
    }
    s
}

noinline fn dot_u32(x: []u32, y: []u32, n: i32) -> u32 {
    s: u32 = 0
    for i in 0..n {
        s += x[i] * y[i]
    }
    s
}

noinline fn sub_i16(a: []i16, n: i64) -> i16 {
    s: i16 = 1000
    for i in 0..n {
        s -= a[i]
    }
    s
}

noinline fn prod(a: []u64, n: i64) -> u64 {
    p: u64 = 1
    for i in 0..n {
        p *= a[i] | 1
    }
    p
}

noinline fn bits(a: []u32, n: i64) -> (u32, u32, u32) {
    x: u32 = 0
    o: u32 = 0
    an: u32 = 0xFFFFFFFF
    for i in 0..n {
        x ^= a[i]
        o |= a[i] & 0x10101
        an &= a[i] | 0x0F0F0F0F
    }
    (x, o, an)
}

noinline fn minmax_i32(a: []i32, n: i64) -> (i32, i32) {
    lo := a[0]
    hi := a[0]
    for i in 1..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    (lo, hi)
}

noinline fn minmax_u64(a: []u64, n: i64) -> (u64, u64) {
    lo: u64 = 0xFFFFFFFFFFFFFFFF
    hi: u64 = 0
    for i in 0..n {
        if a[i] < lo {
            lo = a[i]
        }
        if a[i] > hi {
            hi = a[i]
        }
    }
    (lo, hi)
}

noinline fn count_if(a: []i32, t: i32) -> i64 {
    c := 0
    for x in a {
        if x > t {
            c += 1
        }
    }
    c
}

noinline fn cond_sum(a: []i64, n: i64) -> i64 {
    s := 0
    for i in 0..n {
        x := a[i]
        if x & 1 == 0 {
            s += x
        } else {
            s -= x >> 1
        }
    }
    s
}

// not a reduction: the partial values are stored
noinline fn prefix(a: []u64, n: i64) {
    acc: u64 = 0
    for i in 0..n {
        acc += a[i]
        a[i] = acc
    }
}

// floating point: the order of the additions stays
noinline fn fsum(a: []f64, n: i64) -> f64 {
    s: f64 = 0.0
    for i in 0..n {
        s += a[i]
    }
    s
}

// the counter and a partial value are used after the loop
noinline fn find_first(a: []i32, n: i64, t: i32) -> (i64, i64) {
    i := 0
    s := 0
    while i < n {
        s += i64(a[i])
        if a[i] == t {
            break
        }
        i += 1
    }
    (i, s)
}

noinline fn last_values(a: []i64, n: i64) -> (i64, i64, i64) {
    s := 0
    prev := 0
    k := 0
    for i in 0..n {
        prev = s
        s += a[i]
        k = i
    }
    (s, prev, k)
}

// counting down
noinline fn down(a: []i32, n: i64) -> i64 {
    s := 0
    i := n - 1
    while i >= 0 {
        s = s * 3 + i64(a[i])
        i -= 1
    }
    s
}

noinline fn down_u(a: []i32, n: u32) -> i64 {
    s := 0
    if n == 0 {
        return s
    }
    for i in n - 1..=u32(0) by -1 {
        s = s * 5 + i64(a[i])
    }
    s
}

// narrow and unsigned counters
noinline fn sum_i8_counter(a: []i64, lo: i8, hi: i8) -> i64 {
    s := 0
    for i in lo..hi {
        s += a[i64(i) + 128] * i64(i)
    }
    s
}

noinline fn sum_u16_counter(a: []i64, lo: u16, hi: u16) -> i64 {
    s := 0
    for i in lo..hi {
        s += a[i]
    }
    s
}

// a loop with a check in the body and a store
noinline fn scatter(a: []i64, idx: []i64, n: i64) {
    for k in 0..n {
        a[idx[k]] += k
    }
}

// a body of several blocks
noinline fn collatz_steps(a: []i64, n: i64) -> i64 {
    t := 0
    for i in 0..n {
        x := a[i]
        if x % 2 == 0 {
            t += x / 2
        } else {
            t += 3 * x + 1
        }
    }
    t
}

fn main() {
    b := alloc[u8](3000)
    for i in 0..len(b) {
        b[i] = u8(i * 37 + i / 7)
    }
    trips := []i64{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 31, 33, 1000, 2999}
    for n in trips {
        print("sum_u8", n, sum_u8(b, 0, n), sum_u8(b, 1, 1 + n), sum_u8(b, n, 0))
    }
    x := alloc[u32](1100)
    y := alloc[u32](1100)
    for i in 0..len(x) {
        x[i] = u32(i * 2654435761)
        y[i] = u32(i * 40503 + 17)
    }
    for n in trips {
        if n <= 1100 {
            print("dot", n, dot_u32(x, y, i32(n)))
        }
    }
    print("dot negative", dot_u32(x, y, -4))
    h := alloc[i16](100)
    q := alloc[u64](100)
    w := alloc[u32](100)
    m := alloc[i32](100)
    u := alloc[u64](100)
    l := alloc[i64](100)
    f := alloc[f64](100)
    for i in 0..100 {
        h[i] = i16(i * 1311 - 20000)
        q[i] = u64(i) * 0x9E3779B97F4A7C15
        w[i] = u32(i * 2246822519)
        m[i] = i32(i * 1103515245) >> 3
        u[i] = u64(i) * 0xC2B2AE3D27D4EB4F
        l[i] = i * i * 31 - 777
        f[i] = if i % 3 == 0 { 1.0e16 } else if i % 3 == 1 { 1.0 } else { -1.0e16 }
    }
    for n in trips {
        if n > 100 {
            continue
        }
        x1, o1, a1 := bits(w, n)
        print("sub", n, sub_i16(h, n), "prod", prod(q, n), "bits", x1, o1, a1)
        if n > 0 {
            lo, hi := minmax_i32(m, n)
            print("minmax_i32", n, lo, hi)
        }
        lo2, hi2 := minmax_u64(u, n)
        print("minmax_u64", n, lo2, hi2, "count", count_if(m[..n], 1000), count_if(m[..n], -1000))
        print("cond_sum", n, cond_sum(l, n), "fsum", fsum(f, n))
        i1, s1 := find_first(m, n, m[n / 2])
        i2, s2 := find_first(m, n, 12345)
        s3, p3, k3 := last_values(l, n)
        print("exit values", n, i1, s1, i2, s2, s3, p3, k3)
        print("down", n, down(m, n), down_u(m, u32(n)))
    }
    pa := alloc[u64](40)
    for n in []i64{0, 1, 3, 4, 5, 9, 40} {
        for i in 0..40 {
            pa[i] = u64(i * 3 + 1)
        }
        prefix(pa, n)
        print("prefix", n, pa[0], pa[n / 2], pa[39])
    }
    big := alloc[i64](300)
    for i in 0..300 {
        big[i] = i * 7 - 1000
    }
    print("i8 counter", sum_i8_counter(big, -128, 127), sum_i8_counter(big, -3, 4), sum_i8_counter(big, 5, -5), sum_i8_counter(big, 100, 105))
    print("u16 counter", sum_u16_counter(big, u16(0), u16(299)), sum_u16_counter(big, u16(7), u16(8)), sum_u16_counter(big, u16(9), u16(2)))
    sa := alloc[i64](64)
    idx := alloc[i64](64)
    for i in 0..64 {
        idx[i] = (i * 29) % 64
    }
    for n in []i64{0, 1, 2, 5, 63, 64} {
        scatter(sa, idx, n)
        print("scatter", n, sa[0], sa[29], sa[58], sa[63])
    }
    print("collatz", collatz_steps(l, 0), collatz_steps(l, 1), collatz_steps(l, 7), collatz_steps(l, 100))
}
