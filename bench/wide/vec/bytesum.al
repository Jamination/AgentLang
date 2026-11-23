// sum of the bytes of a 1 MiB buffer (u8 widened into a u64 accumulator)
fn bytesum(b: []u8) -> u64 {
    s: u64 = 0
    for i in 0..len(b) {
        s += u64(b[i])
    }
    s
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
