// Induction variable optimisations (src/opt/lsr.al): narrow counters widened to 64 bits,
// strided indices `i * m + j` as additive recurrences, and addresses re-based on an invariant
// part plus the scaled counter. The results must be those of the plain loops, also for counters
// near the ends of their types, negative strides and offsets, and element sizes that are not
// powers of two.
struct P3 {
    x: i64
    y: i64
    z: i64
}

noinline fn sum_i32(a: []i64, lo: i32, hi: i32) -> i64 {
    s := 0
    for i in lo..hi {
        s += a[i] * i64(i)
    }
    s
}

noinline fn fill_i32(a: []i32, n: i32) {
    for i in 0..n {
        a[i] = i * 3 - 7
    }
}

noinline fn sum_u32(a: []u16, lo: u32, hi: u32) -> u64 {
    s: u64 = 0
    for i in lo..hi {
        s += u64(a[i]) << u64(i & 7)
    }
    s
}

noinline fn sum_i16(a: []i64, n: i16) -> i64 {
    s := 0
    for i in i16(0)..n {
        s = s * 3 + a[i]
    }
    s
}

noinline fn strided(a: []f64, n: i64, m: i64, j: i64) -> f64 {
    s: f64 = 0.0
    for i in 0..n {
        s += a[i * m + j]
    }
    s
}

noinline fn strided_i32(a: []i64, n: i32, m: i64, j: i64) -> i64 {
    s := 0
    for i in 0..n {
        s = s * 7 + a[i64(i) * m + j]
    }
    s
}

noinline fn strided_store(a: []i32, n: i64, m: i64) {
    for i in 0..n {
        a[m * i] = i32(i)
    }
}

noinline fn relax(src: []f64, dst: []f64, n: i64) {
    for y in 1..n - 1 {
        for x in 1..n - 1 {
            i := y * n + x
            dst[i] = 0.25 * (src[i - n] + src[i + n] + src[i - 1] + src[i + 1])
        }
    }
}

noinline fn diffs(a: []u16, out: []i32, lo: i64, hi: i64) {
    for i in lo..hi {
        out[i - lo] = i32(a[i + 2]) - i32(a[i - 2]) + i32(a[3 * i - 2 * lo])
    }
}

noinline fn points(p: []P3, n: i64) -> i64 {
    s := 0
    for i in 1..n {
        s += p[i].x * p[i - 1].y - p[i].z
        p[i].z = s & 0xFFFF
    }
    s
}

fn main() {
    a := alloc[i64](300)
    for i in 0..300 {
        a[i] = i * i - 150
    }
    print("sum_i32", sum_i32(a, 0, 300), sum_i32(a, 7, 8), sum_i32(a, 9, 3), sum_i32(a, 0, 0))
    b := alloc[i32](100)
    fill_i32(b, 100)
    fill_i32(b, -3)
    print("fill_i32", b[0], b[50], b[99])
    w := alloc[u16](70000)
    for i in 0..len(w) {
        w[i] = u16(i * 7)
    }
    print("sum_u32", sum_u32(w, 0, 70000), sum_u32(w, 65530, 65540), sum_u32(w, 5, 2))
    print("sum_i16", sum_i16(a, 300), sum_i16(a, 0), sum_i16(a, -9))
    f := alloc[f64](1000)
    for i in 0..1000 {
        f[i] = f64(i) * 0.5 - 10.0
    }
    print("strided", strided(f, 10, 7, 3), strided(f, 30, 33, 0), strided(f, 20, -40, 900), strided(f, 50, 0, 17), strided(f, 0, 5, 5))
    print("strided_i32", strided_i32(a, 30, 9, 2), strided_i32(a, 20, -11, 280), strided_i32(a, 1, 1000, 1))
    s := alloc[i32](100)
    strided_store(s, 10, 9)
    strided_store(s, 12, 0)
    strided_store(s, 33, 3)
    print("strided_store", s[0], s[9], s[27], s[81], s[96])
    n := 12
    src := alloc[f64](n * n)
    dst := alloc[f64](n * n)
    for i in 0..n * n {
        src[i] = f64(i % 7) - f64(i % 5) * 0.5
    }
    relax(src, dst, n)
    relax(dst, src, n)
    t: f64 = 0.0
    for i in 0..n * n {
        t += src[i] * f64(i + 1)
    }
    print("relax", t)
    out := alloc[i32](100)
    diffs(w, out, 10, 40)
    diffs(w, out, 2, 3)
    print("diffs", out[0], out[1], out[29], out[30])
    pts := alloc[P3](50)
    for i in 0..50 {
        pts[i] = P3{x: i, y: 50 - i, z: i * i}
    }
    print("points", points(pts, 50), points(pts, 1), pts[49].z, pts[10].z)
}
