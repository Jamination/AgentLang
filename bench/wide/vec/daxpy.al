// y += a * x over f64 arrays that fit in L1/L2 (2 x 32 KiB)
fn daxpy(a: f64, x: []f64, y: []f64) {
    for i in 0..len(y) {
        y[i] = y[i] + a * x[i]
    }
}

fn main() {
    n := 4096
    x := alloc[f64](n)
    y := alloc[f64](n)
    seed: u32 = 1
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        x[i] = f64(seed >> 8) / 16777216.0
        seed = seed * 1664525 + 1013904223
        y[i] = f64(seed >> 8) / 16777216.0
    }
    for r in 0..400000 {
        a: f64 = if r & 1 == 0 { 0.25 } else { -0.2 }
        daxpy(a, x, y)
    }
    s: f64 = 0.0
    for i in 0..n {
        s += y[i]
    }
    putf(s, 6)
    putc('\n')
}
