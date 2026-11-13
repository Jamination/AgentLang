// std.rand: hash-based gradient noise
fn main() {
    print(noise_hash(0, 0, 0, 0), noise_hash(1, 0, 0, 0), noise_hash(0, 1, 0, 0), noise_hash(0, 0, 1, 0), noise_hash(0, 0, 0, 1), noise_hash(-1, -1, -1, 0))

    // zero on the lattice, bounded, deterministic, uses a good part of its range
    lattice := true
    bounded := true
    repeat := true
    lo: f32 = 1.0
    hi: f32 = -1.0
    sum: f64 = 0.0
    for iy in -40..40 {
        for ix in -40..40 {
            lattice = lattice && noise2(f32(ix), f32(iy)) == 0.0 && noise3(f32(ix), f32(iy), 3.0) == 0.0
            x := f32(ix) * 0.173 + 0.05
            y := f32(iy) * 0.211 - 0.4
            v := noise2(x, y)
            repeat = repeat && v == noise2(x, y)
            bounded = bounded && v >= -1.0 && v <= 1.0
            lo = fmin(lo, v)
            hi = fmax(hi, v)
            sum += f64(v)
        }
    }
    print("lattice zero", lattice, "bounded", bounded, "deterministic", repeat)
    print("spread", lo < -0.4, hi > 0.4, "mean near 0", fabs(sum / 6400.0) < 0.05)

    // smooth: a small step changes the value only slightly
    smooth := true
    for i in 0..2000 {
        x := f32(i) * 0.01 - 7.0
        smooth = smooth && fabs(noise2(x + 0.001, 1.37) - noise2(x, 1.37)) < 0.01
        smooth = smooth && fabs(noise3(0.4, x + 0.001, 2.2) - noise3(0.4, x, 2.2)) < 0.01
    }
    print("smooth", smooth)

    // seeds select independent fields
    diff := 0
    for i in 0..100 {
        x := f32(i) * 0.37 + 0.1
        if noise2(x, 0.5, 1) != noise2(x, 0.5, 2) {
            diff += 1
        }
        if noise3(x, 0.5, 0.25, 1) != noise3(x, 0.5, 0.25, 2) {
            diff += 1
        }
    }
    print("seeded", diff > 190, noise2(0.3, 0.6) == noise2(0.3, 0.6, 0), noise3(0.3, 0.6, 0.9) == noise3(0.3, 0.6, 0.9, 0))

    // 3D noise and fbm stay in range
    ok3 := true
    okf := true
    lo3: f32 = 1.0
    hi3: f32 = -1.0
    lof: f32 = 1.0
    hif: f32 = -1.0
    for i in 0..20000 {
        x := f32(i % 200) * 0.137
        y := f32(i / 200) * 0.291
        a := noise3(x, y, x * 0.5 + y)
        b := fbm2(x, y, 5)
        ok3 = ok3 && a >= -1.0 && a <= 1.0
        okf = okf && b >= -1.0 && b <= 1.0
        lo3 = fmin(lo3, a)
        hi3 = fmax(hi3, a)
        lof = fmin(lof, b)
        hif = fmax(hif, b)
    }
    print("noise3", ok3, lo3 < -0.3, hi3 > 0.3, "fbm2", okf, lof < -0.3, hif > 0.3)
    print(fbm2(0.3, 0.7, 1) == noise2(0.3, 0.7), fbm2(0.3, 0.7, 0), fbm2(0.3, 0.7, 4) == fbm2(0.3, 0.7, 4, 0), fbm2(0.3, 0.7, 4) != fbm2(0.3, 0.7, 4, 9))
    putf(f64(noise2(0.5, 0.5)), 4)
    putc(' ')
    putf(f64(noise2(-3.25, 8.75, 42)), 4)
    putc(' ')
    putf(f64(noise3(0.5, 0.5, 0.5)), 4)
    putc(' ')
    putf(f64(fbm2(1.7, -2.3, 6)), 4)
    putc('\n')
}
