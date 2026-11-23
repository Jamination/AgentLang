// y = y + a * x over f32 arrays in L1 (2 x 16 KiB)
fn saxpy(a: f32, x: []f32, y: []f32) {
    for i in 0..len(y) {
        y[i] = y[i] + a * x[i]
    }
}

fn main() {
    n := 4096
    x := alloc[f32](n)
    y := alloc[f32](n)
    seed: u32 = 7
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        x[i] = f32(seed >> 8) / 16777216.0
        seed = seed * 1664525 + 1013904223
        y[i] = f32(seed >> 8) / 16777216.0
    }
    for r in 0..800000 {
        a: f32 = if r & 1 == 0 { 0.25 } else { -0.2 }
        saxpy(a, x, y)
    }
    s: f64 = 0.0
    for i in 0..n {
        s += f64(y[i])
    }
    putf(s, 6)
    putc('\n')
}
