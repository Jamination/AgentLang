// range(r, lo: f32, hi: f32) is documented as uniform in [lo, hi), but lo + (hi - lo) * next_f32
// rounds up to hi: range(100.0, 101.0) returned 101.0 78 times in 20M draws (first at draw 323243),
// and a range one ulp wide returned hi half of the time.
// expected: 0 0   actual (before the fix): 78 500650
fn main() {
    r := rng(1)
    hits := 0
    for i in 0..20000000 {
        if r.range(f32(100.0), f32(101.0)) >= 101.0 { hits += 1 }
    }
    r2 := rng(5)
    h2 := 0
    for i in 0..1000000 {
        if r2.range(f32(-1.0), f32(-0.99999994)) >= -0.99999994 { h2 += 1 }
    }
    print(hits, h2)
}
