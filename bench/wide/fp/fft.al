fn fft(re: []f64, im: []f64, twr: []f64, twi: []f64, inverse: bool) {
    n := len(re)
    // bit reversal
    j := 0
    for i in 1..n {
        bit := n >> 1
        while j & bit != 0 {
            j ^= bit
            bit >>= 1
        }
        j ^= bit
        if i < j {
            t := re[i]
            re[i] = re[j]
            re[j] = t
            t = im[i]
            im[i] = im[j]
            im[j] = t
        }
    }
    sign: f64 = if inverse { -1.0 } else { 1.0 }
    size := 2
    while size <= n {
        half := size >> 1
        step := n / size
        for start in 0..n by size {
            for k in 0..half {
                wr := twr[k * step]
                wi := sign * twi[k * step]
                a := start + k
                b := a + half
                xr := re[b] * wr - im[b] * wi
                xi := re[b] * wi + im[b] * wr
                re[b] = re[a] - xr
                im[b] = im[a] - xi
                re[a] = re[a] + xr
                im[a] = im[a] + xi
            }
        }
        size <<= 1
    }
    if inverse {
        s := 1.0 / f64(n)
        for i in 0..n {
            re[i] = re[i] * s
            im[i] = im[i] * s
        }
    }
}

fn main() {
    logn := 16
    n := 1 << logn
    // twiddle root by angle halving from pi/2: only sqrt and division
    c: f64 = 0.0
    s: f64 = 1.0
    for l in 2..logn {
        c2 := sqrt((1.0 + c) * 0.5)
        s = s / (2.0 * c2)
        c = c2
    }
    twr := alloc[f64](n / 2)
    twi := alloc[f64](n / 2)
    twr[0] = 1.0
    twi[0] = 0.0
    for k in 1..n / 2 {
        twr[k] = twr[k - 1] * c + twi[k - 1] * s
        twi[k] = twi[k - 1] * c - twr[k - 1] * s
    }
    re := alloc[f64](n)
    im := alloc[f64](n)
    for i in 0..n {
        re[i] = f64((i * 7919) % 1000) / 1000.0
        im[i] = f64((i * 104729) % 777) / 777.0
    }
    for r in 0..60 {
        fft(re, im, twr, twi, false)
        fft(re, im, twr, twi, true)
    }
    sr: f64 = 0.0
    si: f64 = 0.0
    for i in 0..n {
        sr += re[i] * f64(i % 7 + 1)
        si += im[i] * f64(i % 5 + 1)
    }
    print(cast[u64](sr), cast[u64](si), i64(sr), i64(si))
}
