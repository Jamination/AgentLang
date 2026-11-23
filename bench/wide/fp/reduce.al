// strict-order floating-point reductions: plain sum, dot product, Kahan sum (no reassociation allowed)
fn kahan(a: []f64) -> f64 {
    sum: f64 = 0.0
    c: f64 = 0.0
    for x in a {
        y := x - c
        t := sum + y
        c = (t - sum) - y
        sum = t
    }
    sum
}

fn dot(a: []f64, b: []f64) -> f64 {
    s: f64 = 0.0
    for i in 0..len(a) {
        s += a[i] * b[i]
    }
    s
}

fn total(a: []f64) -> f64 {
    s: f64 = 0.0
    for x in a {
        s += x
    }
    s
}

fn main() {
    n := 1 << 20
    a := alloc[f64](n)
    b := alloc[f64](n)
    for i in 0..n {
        a[i] = 1.0 / f64(i + 1) + f64(i % 3) * 1e8
        b[i] = f64(i % 17) * 0.125 - 1.0
    }
    s1: f64 = 0.0
    s2: f64 = 0.0
    s3: f64 = 0.0
    for r in 0..60 {
        s1 += total(a)
        s2 += dot(a, b)
        s3 += kahan(a)
        a[r] = a[r] + 1.0
    }
    print(cast[u64](s1), cast[u64](s2), cast[u64](s3))
}
