// f32 semantics checked against C: prints the same bytes as tests/c/f32.c built with clang -O2.
state: u32 = 12345

next :: () -> u32 {
    state = state * 1664525 + 1013904223
    return state
}

bits :: (x: f32) -> str {
    return hex(u64(cast[u32](x)))
}

b01 :: (c: bool) -> i64 {
    if c { 1 } else { 0 }
}

main :: () {
    vals := [12]f32{0.0, 1.0, -1.0, 0.1, 3.14159274, 1e-20, 1e20, 16777216.0, 16777217.0, 0.333333343, -2.5, 123456.789}
    for i in 0..12 {
        for j in 0..12 {
            a := vals[i]
            b := vals[j]
            q: f32 = 0.0
            if b != 0.0 {
                q = a / b
            }
            put(bits(a + b), " ", bits(a - b), " ", bits(a * b), " ", bits(q), " ")
            put(b01(a < b), b01(a <= b), b01(a > b), b01(a >= b), b01(a == b), b01(a != b), "\n")
        }
    }
    for i in 0..12 {
        a := vals[i]
        putf(f64(a), 6)
        put(" ")
        putf(f64(a), 9)
        put(" ", bits(-a), " ", bits(fabs(a)), " ", bits(sqrt(fabs(a))), "\n")
    }
    ints := [8]i64{0, 1, -1, 7, 16777217, -123456789, 2147483647, 9007199254740993}
    for i in 0..8 {
        f := f32(ints[i])
        put(bits(f), " ")
        putf(f64(f), 1)
        put("\n")
    }
    u32s := [4]u32{0, 1, 4294967295, 2147483648}
    for i in 0..4 {
        print(bits(f32(u32s[i])))
    }
    ds := [6]f64{0.1, 1.0 / 3.0, 1e40, -1e-50, 16777217.0, 2.5}
    for i in 0..6 {
        f := f32(ds[i])
        print(bits(f), 1)
    }
    fs := [6]f32{0.0, 0.99, -0.99, 2.5, -2.5, 1e9}
    for i in 0..6 {
        print(i64(fs[i]), i32(fs[i]))
    }
    acc: u32 = 0
    sum: f32 = 0.0
    for i in 0..20000 {
        a := cast[f32](next() & 0x7fffffff)
        b := cast[f32](next())
        if a != a || b != b || a > 3.0e38 || b > 3.0e38 || b < -3.0e38 {
            continue
        }
        acc = acc * 31 + cast[u32](a + b)
        acc = acc * 31 + cast[u32](a - b)
        acc = acc * 31 + cast[u32](a * b)
        if b != 0.0 {
            q := a / b
            if q == q {
                acc = acc * 31 + cast[u32](q)
            }
        }
        acc = acc * 31 + cast[u32](sqrt(a))
        acc = acc * 31 + u32(b01(a < b)) + 2 * u32(b01(a == b))
        small := cast[f32]((next() & 0x007fffff) | 0x3f000000)
        sum = sum * 0.999 + small
    }
    put(hex(u64(acc)), " ", bits(sum), " ")
    putf(f64(sum), 6)
    put("\n")
    h: f32 = 0.0
    for i in 1..=100000 {
        h += 1.0 / f32(i)
    }
    hd := 0.0
    for i in 1..=100000 {
        hd += f64(1.0 / f32(i))
    }
    putf(f64(h), 9)
    put(" ")
    putf(hd, 12)
    put(" ", bits(f32(hd)), "\n")
}
