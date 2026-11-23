// branchy float code: clamp, abs, sign, select (min/max/blend territory)
fn clamp_f(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo { lo } else if x > hi { hi } else { x }
}

fn step(x: f64) -> f64 {
    c := clamp_f(x, -1.5, 1.5)
    ax := if x < 0.0 { -x } else { x }
    s: f64 = if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 }
    m := if ax > 0.75 { ax - 0.75 } else { 0.75 - ax }
    r := c * 1.9 - s * m * 0.6
    if r > 2.0 { r - 4.0 } else if r < -2.0 { r + 4.0 } else { r }
}

fn main() {
    n := 1 << 16
    a := alloc[f64](n)
    for i in 0..n {
        a[i] = f64(i % 4001) / 1000.0 - 2.0
    }
    for pass in 0..4000 {
        for i in 0..n {
            a[i] = step(a[i])
        }
    }
    s: f64 = 0.0
    for i in 0..n {
        s += a[i]
    }
    print(cast[u64](s))
}
