// bytesum.al unrolled by hand: 4 accumulators (what clang does by itself)
fn bytesum(b: []u8) -> u64 {
    s0: u64 = 0
    s1: u64 = 0
    s2: u64 = 0
    s3: u64 = 0
    n := len(b)
    i := 0
    while i + 4 <= n {
        s0 += u64(b[i])
        s1 += u64(b[i + 1])
        s2 += u64(b[i + 2])
        s3 += u64(b[i + 3])
        i += 4
    }
    while i < n {
        s0 += u64(b[i])
        i += 1
    }
    (s0 + s1) + (s2 + s3)
}

fn main() {
    n := 1 << 20
    mask := n - 1
    b := alloc[u8](n)
    seed: u32 = 99
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        b[i] = u8(seed >> 24)
    }
    total: u64 = 0
    for r in 0..6000 {
        total += bytesum(b) * u64(r + 1)
        b[(r * 7919) & mask] += 1
    }
    put(total, "\n")
}
