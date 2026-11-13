// std.rand: generator, distributions, default generator
fn near(x: f64, target: f64, tol: f64) -> bool {
    return fabs(x - target) <= tol
}

fn main() {
    // exact sequence of xoshiro256** seeded through splitmix64
    r := rng(0)
    print(r.next_u64(), r.next_u64(), r.next_u64())
    r = rng(12345)
    print(r.next_u64(), r.next_u32(), r.range(0, 1000), r.below(10))
    a := rng(99)
    b := rng(99)
    c := rng(100)
    same := true
    differ := false
    for i in 0..1000 {
        x := a.next_u64()
        same = same && x == b.next_u64()
        differ = differ || x != c.next_u64()
    }
    print("reproducible", same, "seed matters", differ)

    // uniform floats
    n := 200000
    sum32: f64 = 0.0
    sum64: f64 = 0.0
    in_range := true
    for i in 0..n {
        f := r.next_f32()
        d := r.next_f64()
        in_range = in_range && f >= 0.0 && f < 1.0 && d >= 0.0 && d < 1.0
        sum32 += f64(f)
        sum64 += d
    }
    print("floats in [0,1)", in_range, "means", near(sum32 / f64(n), 0.5, 0.005), near(sum64 / f64(n), 0.5, 0.005))

    // integer ranges: every value, nothing else, flat histogram
    hist: [6]i64
    for i in 0..60000 {
        hist[r.range(-2, 4) + 2] += 1
    }
    flat := true
    for h in hist {
        flat = flat && h > 9500 && h < 10500
    }
    print("range histogram flat", flat)
    lo := 1 << 62
    hi := -(1 << 62)
    big_ok := true
    for i in 0..1000 {
        x := r.range(-(1 << 62), 1 << 62)
        big_ok = big_ok && x >= -(1 << 62) && x < (1 << 62)
        lo = min(lo, x)
        hi = max(hi, x)
    }
    print("wide range", big_ok, lo < -(1 << 61), hi > (1 << 61), r.range(7, 8), r.below(1))
    fr_ok := true
    for i in 0..1000 {
        f := r.range(-2.0, 3.0)
        fr_ok = fr_ok && f >= -2.0 && f < 3.0
    }
    print("f32 range", fr_ok)

    hits := 0
    for i in 0..100000 {
        if r.chance(0.25) {
            hits += 1
        }
    }
    print("chance", near(f64(hits) / 100000.0, 0.25, 0.01), r.chance(0.0), r.chance(1.0))

    // shuffle and pick
    xs := alloc[i64](10)
    for i in 0..10 {
        xs[i] = i
    }
    r.shuffle(xs)
    print(xs)
    sorted := alloc[i64](10)
    copy(sorted, xs)
    sort(sorted)
    print(sorted)
    first: [10]i64
    for i in 0..50000 {
        for k in 0..10 {
            xs[k] = k
        }
        r.shuffle(xs)
        first[xs[0]] += 1
    }
    fair := true
    for f in first {
        fair = fair && f > 4600 && f < 5400
    }
    names := []str{"orc", "elf", "imp"}
    print("shuffle fair", fair, "pick", r.pick(names), r.pick(names), r.pick(names), r.pick(names))

    // geometry
    unit := true
    inside := true
    sx: f64 = 0.0
    sz: f64 = 0.0
    half2 := 0
    half3 := 0
    for i in 0..50000 {
        u := r.unit_vec2()
        v := r.unit_vec3()
        unit = unit && near(f64(u.x * u.x + u.y * u.y), 1.0, 0.0001) && near(f64(v.x * v.x + v.y * v.y + v.z * v.z), 1.0, 0.0001)
        sx += f64(u.x)
        sz += f64(v.z)
        p := r.in_circle()
        q := r.in_sphere()
        d2 := p.x * p.x + p.y * p.y
        d3 := q.x * q.x + q.y * q.y + q.z * q.z
        inside = inside && d2 < 1.0 && d3 < 1.0
        if d2 < 0.25 {
            half2 += 1
        }
        if d3 < 0.25 {
            half3 += 1
        }
    }
    print("unit", unit, "centered", near(sx / 50000.0, 0.0, 0.02), near(sz / 50000.0, 0.0, 0.02))
    print("inside", inside, "uniform", near(f64(half2) / 50000.0, 0.25, 0.01), near(f64(half3) / 50000.0, 0.125, 0.01))

    // gaussian
    s1: f64 = 0.0
    s2: f64 = 0.0
    within := 0
    for i in 0..n {
        g := f64(r.normal(5.0, 2.0))
        s1 += g
        s2 += (g - 5.0) * (g - 5.0)
        if fabs(g - 5.0) < 2.0 {
            within += 1
        }
    }
    print("normal mean", near(s1 / f64(n), 5.0, 0.03), "stddev", near(sqrt(s2 / f64(n)), 2.0, 0.03), "68%", near(f64(within) / f64(n), 0.6827, 0.01))

    // default generator: starts as rng(0), reseedable
    z := rng(0)
    print(rand_u64() == z.next_u64(), rand_f32() == z.next_f32(), rand_range(0, 100) == z.range(0, 100))
    rand_seed(7)
    z = rng(7)
    print(rand_u64() == z.next_u64(), rand_range(10, 20), rand_range(0.0, 1.0) < 1.0)
}
