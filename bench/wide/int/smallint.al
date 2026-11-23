// small integer types: u8 / u16 / i16 / i32 arithmetic with wraparound, sign and zero extension
fn main() {
    n := 1 << 16
    a := alloc[u8](n)
    b := alloc[i16](n)
    w := alloc[u16](n)
    seed: u32 = 7
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        a[i] = u8(seed >> 24)
        b[i] = i16(seed >> 8)
    }
    h: i32 = 17
    q: u16 = 1
    for r in 0..5000 {
        for i in 1..n - 1 {
            v := u16(a[i - 1]) + 2 * u16(a[i]) + u16(a[i + 1])
            w[i] = v
            nb := b[i] + i16(a[i]) * 3 - i16(v)
            b[i] = nb
            h = h * 31 + i32(nb)
            q = q * 3 + u16(a[i]) + (v >> 2)
        }
        a[r & (n - 1)] ^= u8(h)
        a[(r * 7) & (n - 1)] += u8(q)
    }
    s: i64 = 0
    for i in 0..n { s += i64(b[i]) * 3 + i64(w[i]) }
    put(h, " ", q, " ", s, "\n")
}
