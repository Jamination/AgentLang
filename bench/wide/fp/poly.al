// Horner evaluation, Chebyshev (Clenshaw) and Taylor series loops
const COEF = [16]f64{1.0, -0.5, 0.25, -0.125, 0.0625, 0.3, -0.7, 0.11, 0.013, -0.21, 0.17, -0.019, 0.0023, 0.31, -0.29, 0.07}

fn horner(c: []f64, x: f64) -> f64 {
    r: f64 = 0.0
    for i in 0..len(c) {
        r = r * x + c[len(c) - 1 - i]
    }
    r
}

fn clenshaw(c: []f64, x: f64) -> f64 {
    b1: f64 = 0.0
    b2: f64 = 0.0
    x2 := 2.0 * x
    for i in 0..len(c) - 1 {
        t := x2 * b1 - b2 + c[len(c) - 1 - i]
        b2 = b1
        b1 = t
    }
    x * b1 - b2 + c[0]
}

// exp(x) by Taylor series until the term is negligible
fn taylor_exp(x: f64) -> f64 {
    sum: f64 = 1.0
    term: f64 = 1.0
    n: f64 = 1.0
    while fabs(term) > 1e-16 * fabs(sum) {
        term = term * x / n
        sum += term
        n += 1.0
    }
    sum
}

fn main() {
    cheb := alloc[f64](24)
    for i in 0..24 {
        cheb[i] = 1.0 / f64(i * i + 1)
    }
    coef := COEF
    m := 6000000
    ys := alloc[f64](m)
    for i in 0..m {
        ys[i] = f64(i) / f64(m) * 2.0 - 1.0
    }
    sh: f64 = 0.0
    sc: f64 = 0.0
    st: f64 = 0.0
    for i in 0..m {
        x := ys[i]
        sh += horner(coef[..], x)
        sc += clenshaw(cheb, x)
    }
    for i in 0..m / 4 {
        st += taylor_exp(ys[i * 4] * 3.0)
    }
    print(cast[u64](sh), cast[u64](sc), cast[u64](st))
}
