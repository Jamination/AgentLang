// saxpy.al written with the built-in vec4 (4 x f32 per SSE register); same results lane by lane
fn saxpy4(a: f32, x: []vec4, y: []vec4) {
    av := vec4(a)
    for i in 0..len(y) {
        y[i] = y[i] + av * x[i]
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
    x4 := cast[[]vec4](x)
    y4 := cast[[]vec4](y)
    for r in 0..800000 {
        a: f32 = if r & 1 == 0 { 0.25 } else { -0.2 }
        saxpy4(a, x4, y4)
    }
    s: f64 = 0.0
    for i in 0..n {
        s += f64(y[i])
    }
    putf(s, 6)
    putc('\n')
}
