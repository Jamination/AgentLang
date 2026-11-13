fn mm_init(n: i64) -> [][]f64 {
    m := alloc[[]f64](n)
    for i in 0..n {
        m[i] = alloc[f64](n)
    }
    m
}

fn mm_gen(n: i64, seed: f64) -> [][]f64 {
    a := mm_init(n)
    tmp := seed / f64(n) / f64(n)
    for i in 0..n {
        for j in 0..n {
            a[i][j] = tmp * f64(i - j) * f64(i + j)
        }
    }
    a
}

fn mm_mul(n: i64, a: [][]f64, b: [][]f64) -> [][]f64 {
    m := mm_init(n)
    c := mm_init(n)
    for i in 0..n {
        for j in 0..n {
            c[i][j] = b[j][i]
        }
    }
    for i in 0..n {
        p := a[i]
        q := m[i]
        for j in 0..n {
            t: f64 = 0.0
            r := c[j]
            for k in 0..n {
                t += p[k] * r[k]
            }
            q[j] = t
        }
    }
    m
}

fn main() {
    n := 800
    a := mm_gen(n, 1.0)
    b := mm_gen(n, 2.0)
    m := mm_mul(n, a, b)
    trace: f64 = 0.0
    for i in 0..n {
        trace += m[i][i]
    }
    putf(m[n / 2][n / 2], 9)
    putc('\n')
    putf(trace, 9)
    putc('\n')
}
