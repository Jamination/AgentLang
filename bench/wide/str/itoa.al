// [codegen] hand-written integer formatting (itoa) and parsing (atoi) round trip
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

// writes the decimal digits of v into buf, returns the length
fn itoa(v: i64, buf: []u8) -> i64 {
    tmp: [24]u8
    neg := v < 0
    u := if neg { u64(0) - u64(v) } else { u64(v) }
    k := 0
    loop {
        tmp[k] = u8(48 + u % 10)
        k += 1
        u = u / 10
        if u == 0 { break }
    }
    n := 0
    if neg {
        buf[0] = '-'
        n = 1
    }
    while k > 0 {
        k -= 1
        buf[n] = tmp[k]
        n += 1
    }
    n
}

fn atoi(s: []u8) -> i64 {
    i := 0
    neg := false
    if len(s) > 0 && s[0] == '-' {
        neg = true
        i = 1
    }
    v: u64 = 0
    while i < len(s) {
        d := s[i] - '0'
        if d > 9 { break }
        v = v * 10 + u64(d)
        i += 1
    }
    if neg { i64(u64(0) - v) } else { i64(v) }
}

fn main() {
    buf: [32]u8
    seed: u64 = 1
    sum := 0
    lens := 0
    for i in 0..15000000 {
        seed = lcg(seed)
        x := i64(seed) >> i64((seed >> 20) % 63)
        n := itoa(x, buf[..])
        lens += n
        y := atoi(buf[..n])
        sum += y ^ i
    }
    print(lens, sum)
}
