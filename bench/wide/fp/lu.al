fn lu(a: []f64, n: i64, piv: []i64) -> f64 {
    det: f64 = 1.0
    for k in 0..n {
        p := k
        best := fabs(a[k * n + k])
        for i in k + 1..n {
            v := fabs(a[i * n + k])
            if v > best {
                best = v
                p = i
            }
        }
        piv[k] = p
        if p != k {
            det = -det
            for j in 0..n {
                t := a[k * n + j]
                a[k * n + j] = a[p * n + j]
                a[p * n + j] = t
            }
        }
        pivot := a[k * n + k]
        det *= pivot
        rk := a[k * n..k * n + n]
        for i in k + 1..n {
            ri := a[i * n..i * n + n]
            f := ri[k] / pivot
            ri[k] = f
            for j in k + 1..n {
                ri[j] -= f * rk[j]
            }
        }
    }
    det
}

fn main() {
    n := 400
    a := alloc[f64](n * n)
    piv := alloc[i64](n)
    seed: u64 = 12345
    total: f64 = 0.0
    psum := 0
    for rep in 0..60 {
        for i in 0..n * n {
            seed = seed * 6364136223846793005 + 1442695040888963407
            a[i] = f64(i64(seed >> 33) % 2001 - 1000) / 1000.0
        }
        det := lu(a, n, piv)
        total += a[(rep * 37) % (n * n)] + (if det < 0.0 { -1.0 } else { 1.0 })
        for i in 0..n {
            psum += piv[i] * (i + 1)
        }
        s: f64 = 0.0
        for i in 0..n * n {
            s += a[i]
        }
        total += s
    }
    print(cast[u64](total), psum, i64(total * 1000.0))
}
