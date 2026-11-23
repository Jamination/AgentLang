// Small innermost loops padded so that they do not straddle a 32- or 64-byte block (x86
// emit.al, loop_pads): padding that is never executed (after a jump), padding in front of the
// header that is (nops, or a jump over it), several loops in one function, and the functions
// placed at multiples of 64 for it. The results must not change, and a failure inside such a
// loop must still be traced to its lines (src/backtrace.al places the functions the same way).

noinline fn sums(a: []i64, k: i64) -> i64 {
    s := 0
    for i in 0..len(a) {
        s += a[i]
    }
    t := 0
    for i in 0..len(a) {
        t ^= a[i] * k
    }
    u := 1
    if k > 3 {
        for i in 0..len(a) by 2 {
            u += a[i] & 7
        }
    } else {
        for i in 1..len(a) by 3 {
            u -= a[i] | 1
        }
    }
    return s * 7 + t + u
}

noinline fn scale(a: []f64, f: f64) -> f64 {
    s: f64 = 0.0
    for i in 0..len(a) {
        a[i] = a[i] * f + 1.0
    }
    for x in a {
        s += x
    }
    return s
}

noinline fn nested(n: i64) -> i64 {
    c := 0
    for i in 0..n {
        j := i
        while j > 0 {
            c += j & 1
            j >>= 1
        }
    }
    return c
}

noinline fn check_all(a: []i64, limit: i64) -> i64 {
    m := 0
    for i in 0..len(a) {
        assert a[i] <= limit, fmt("element ", i, " is over the limit")
        m = max(m, a[i])
    }
    return m
}

noinline fn run(a: []i64, limit: i64) -> i64 {
    t := 0
    for k in 0..3 {
        t += check_all(a, limit) + k
    }
    return t
}

fn main() {
    a := alloc[i64](1000)
    for i in 0..len(a) {
        a[i] = i * 31 % 97
    }
    f := alloc[f64](100)
    for i in 0..len(f) {
        f[i] = f64(i) * 0.25
    }
    print(sums(a, 2), sums(a, 5), sums(a[..7], 9), sums(a[..0], 1))
    print(i64(scale(f, 1.5) * 100.0), nested(1000), nested(0))
    print(run(a, 100))
    print(run(a, 90))
}
