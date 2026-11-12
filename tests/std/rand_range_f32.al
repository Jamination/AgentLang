// range with f32 bounds never returns hi, also where lo + (hi - lo) * x rounds up to it
fn main() {
    r := rng(1)
    hits := 0
    for i in 0..400000 {
        if r.range(f32(100.0), f32(101.0)) >= 101.0 { hits += 1 }
    }
    r2 := rng(5)
    h2 := 0
    lo2 := 0
    for i in 0..10000 {
        v := r2.range(f32(-1.0), f32(-0.99999994))
        if v >= -0.99999994 { h2 += 1 }
        if v == -1.0 { lo2 += 1 }
    }
    rand_seed(3)
    h3 := 0
    for i in 0..10000 {
        if rand_range(f32(1.0), f32(1.0000001)) >= 1.0000001 { h3 += 1 }
    }
    // an empty range gives lo, as before
    print(hits, h2, lo2 == 10000, h3, r.range(f32(2.0), f32(2.0)))
}
