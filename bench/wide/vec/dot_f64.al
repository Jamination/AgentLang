// f64 dot product, strict left-to-right order (clang does not vectorize it without -ffast-math)
fn dot(x: []f64, y: []f64) -> f64 {
    s: f64 = 0.0
    for i in 0..len(x) {
        s += x[i] * y[i]
    }
    s
}

fn main() {
    n := 4096
    mask := n - 1
    x := alloc[f64](n)
    y := alloc[f64](n)
    seed: u32 = 5
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        x[i] = f64(seed >> 8) / 16777216.0 - 0.5
        seed = seed * 1664525 + 1013904223
        y[i] = f64(seed >> 8) / 16777216.0 - 0.5
    }
    total: f64 = 0.0
    for r in 0..200000 {
        total += dot(x, y)
        j := (r * 7919) & mask
        x[j] = -x[j]
    }
    putf(total, 4)
    putc('\n')
}
