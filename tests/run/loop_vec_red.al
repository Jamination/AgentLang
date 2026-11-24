// Reductions in the loop vectorizer (src/opt/vec.al): wrapping integer sums, products of
// lanes summed, &, |, ^, signed and unsigned min / max of every lane size, with start values
// other than the identity, for every trip count 0..40 and odd starting offsets; and float sums,
// which must stay in order (their results depend on it).

priv seed: u64

fn rnd() -> u64 {
    seed = seed * 6364136223846793005 + 1442695040888963407
    return seed >> 29
}

fn fill_rand(b: []u8) {
    for i in 0..len(b) {
        r := rnd()
        b[i] = match r % 7 {
            0 => 0
            1 => 0xFF
            2 => 0x80
            3 => 0x7F
            _ => u8(r >> 8)
        }
    }
}

noinline fn sum_u8(a: []u8, n: i64, s0: u8) -> u8 {
    s := s0
    for i in 0..n {
        s += a[i]
    }
    s
}

noinline fn sum_i16(a: []i16, n: i64, s0: i16) -> i16 {
    s := s0
    for i in 0..n {
        s -= a[i]
    }
    s
}

noinline fn dot_u32(a: []u32, b: []u32, n: i64) -> u32 {
    s: u32 = 0
    for i in 0..n {
        s += a[i] * b[i]
    }
    s
}

noinline fn dot_i16(a: []i16, b: []i16, n: i64) -> i16 {
    s: i16 = 3
    for i in 0..n {
        s += a[i] * b[i] + 1
    }
    s
}

noinline fn sum_i64(a: []i64, n: i64, s0: i64) -> i64 {
    s := s0
    for i in 0..n {
        s += a[i] ^ 0x55
    }
    s
}

noinline fn bits_u32(a: []u32, n: i64) -> u32 {
    x: u32 = 0x12345678
    o: u32 = 0
    m: u32 = 0xFFFF_FFFF
    for i in 0..n {
        x ^= a[i]
        o |= a[i] >> 3
        m &= a[i] | 0x0100_0001
    }
    x + o * 3 + m * 7
}

noinline fn bits_u8(a: []u8, n: i64) -> u64 {
    x: u8 = 0
    o: u8 = 0
    m: u8 = 0xFF
    for i in 0..n {
        x ^= a[i]
        o |= a[i] & 0x81
        m &= a[i] | 0x10
    }
    u64(x) | u64(o) << 8 | u64(m) << 16
}

noinline fn minmax_i32(a: []i32, n: i64) -> i64 {
    lo := a[0]
    hi := a[0]
    for i in 1..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    i64(lo) * 3 + i64(hi)
}

noinline fn minmax_u32(a: []u32, n: i64) -> u64 {
    lo: u32 = 0xFFFF_FFFF
    hi: u32 = 5
    for i in 0..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    u64(lo) << 32 | u64(hi)
}

noinline fn minmax_i8(a: []i8, n: i64) -> i64 {
    lo: i8 = 100
    hi: i8 = -100
    for i in 0..n {
        if a[i] < lo {
            lo = a[i]
        }
        if a[i] > hi {
            hi = a[i]
        }
    }
    i64(lo) * 1000 + i64(hi)
}

noinline fn minmax_u8(a: []u8, n: i64) -> u64 {
    lo: u8 = 0xFF
    hi: u8 = 0
    for i in 0..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    u64(lo) << 8 | u64(hi)
}

noinline fn minmax_i16(a: []i16, n: i64) -> i64 {
    lo: i16 = 0
    hi: i16 = 0
    for i in 0..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    i64(lo) * 100000 + i64(hi)
}

noinline fn minmax_u16(a: []u16, n: i64) -> u64 {
    lo: u16 = 0xFFFF
    hi: u16 = 0
    for i in 0..n {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    u64(lo) << 16 | u64(hi)
}

// a reduction and a map in one loop
noinline fn map_sum_i32(d: []i32, a: []i32, n: i64) -> i32 {
    s: i32 = -7
    for i in 0..n {
        x := a[i] * 3
        d[i] = x
        s += x
    }
    s
}

// counts of a compare (a sum of 0 / 1)
noinline fn count_gt(a: []i32, n: i64, t: i32) -> i64 {
    c := 0
    for i in 0..n {
        if a[i] > t {
            c += 1
        }
    }
    c
}

// float sums stay in order: a big value cancels only at its own position
noinline fn sum_f64(a: []f64, n: i64) -> f64 {
    s: f64 = 0.0
    for i in 0..n {
        s += a[i]
    }
    s
}

noinline fn dot_f32(a: []f32, b: []f32, n: i64) -> f32 {
    s: f32 = 0.0
    for i in 0..n {
        s += a[i] * b[i]
    }
    s
}

fn main() {
    seed = 99
    buf := alloc[u8](8 * 48)
    h: u64 = 0
    for n in 0..41 {
        for off in 0..4 {
            fill_rand(buf)
            a8 := buf[off..]
            a16 := cast[[]i16](buf[2 * off..2 * off + 2 * 44])
            u16s := cast[[]u16](buf[2 * off..2 * off + 2 * 44])
            a32 := cast[[]i32](buf[4 * off..4 * off + 4 * 44])
            u32s := cast[[]u32](buf[4 * off..4 * off + 4 * 44])
            b32 := cast[[]u32](buf[4 * (off + 1)..4 * (off + 1) + 4 * 44])
            a64 := cast[[]i64](buf[8 * off..8 * off + 8 * 44])
            i8s := cast[[]i8](buf[off + 5..])
            r := [16]u64{
                u64(sum_u8(a8, n, u8(n))),
                u64(sum_i16(a16, n, -3)),
                u64(dot_u32(u32s, b32, n)),
                u64(dot_i16(a16, cast[[]i16](buf[2 * off + 6..2 * off + 6 + 88]), n)),
                u64(sum_i64(a64, n, 1 << 62)),
                u64(bits_u32(u32s, n)),
                bits_u8(a8, n),
                u64(minmax_i32(a32, max(n, 1))),
                minmax_u32(u32s, n),
                u64(minmax_i8(i8s, n)),
                minmax_u8(a8, n),
                u64(minmax_i16(a16, n)),
                minmax_u16(u16s, n),
                u64(map_sum_i32(cast[[]i32](buf[200..]), a32, n)),
                u64(count_gt(a32, n, 1 << 20)),
                0,
            }
            for x in r {
                h = (h ^ x) * 1099511628211
            }
            if n == 40 && off == 1 {
                print(r)
            }
        }
    }
    print("hash", h)
    f := alloc[f64](40)
    g := alloc[f32](40)
    g2 := alloc[f32](40)
    for i in 0..40 {
        f[i] = if i % 7 == 3 { 1.0e17 } else if i % 7 == 4 { -1.0e17 } else { f64(i) + 0.125 }
        g[i] = if i % 5 == 2 { 3.0e7 } else { f32(i) * 0.3 }
        g2[i] = if i % 5 == 3 { -1.0 } else { 1.0 / f32(i + 1) }
    }
    for n in [6]i64{0, 3, 8, 17, 33, 40} {
        print(n, sum_f64(f, n), dot_f32(g, g2, n))
    }
}
