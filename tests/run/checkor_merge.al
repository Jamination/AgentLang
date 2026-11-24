// runs of checks of variable indices against one power-of-two length become one check of
// the OR of the indices (checkmerge_or): register-machine handlers, fields of a word as
// indices; a length that is no power of two, two different lengths, and a call between the
// checks keep their checks
noinline fn h(x: u32) -> u32 {
    return x
}

priv calls := 0

noinline fn g(x: u64) -> u64 {
    calls += 1
    return x * 3
}

noinline fn step(r: *[16]u64, w: u32) {
    a := (w >> 8) & 0xFF
    b := (w >> 16) & 0xFF
    c := w >> 24
    match w & 0xFF {
        0 => { r[a] = u64(w >> 16) }
        1 => { r[a] = r[b] + r[c] }
        2 => { r[a] = r[b] * r[c] - r[a] }
        3 => { r[a] = r[b] ^ (r[c] << 3) }
        4 => { r[a] = g(r[b]) }
        _ => { r[c] = r[b] }
    }
}

noinline fn odd(t: *[12]i64, q: *[8]i64, i: i64, j: i64, k: i64) -> i64 {
    // 12 is no power of two; t and q differ in length
    return t[i] + t[j] + q[k] + q[i & 7]
}

fn main() {
    r: [16]u64
    ws := []u32{0x00070100, 0x00030200, 0x01020301, 0x02010402, 0x03040503, 0x00050604, 0x07060005, 0x0F0E0D01}
    for w in ws {
        step(&r, h(w))
    }
    print(r, calls)
    t: [12]i64
    q: [8]i64
    for i in 0..12 {
        t[i] = i64(i * i)
    }
    for i in 0..8 {
        q[i] = i64(100 + i)
    }
    print(odd(&t, &q, 11, 3, 7), odd(&t, &q, 0, 0, 0))
}
