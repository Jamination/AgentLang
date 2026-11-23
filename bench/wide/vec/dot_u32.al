// integer dot product (wrapping u32), arrays in L1/L2 (2 x 32 KiB)
fn dot(x: []u32, y: []u32) -> u32 {
    s: u32 = 0
    for i in 0..len(x) {
        s += x[i] * y[i]
    }
    s
}

fn main() {
    n := 8192
    mask := n - 1
    x := alloc[u32](n)
    y := alloc[u32](n)
    seed: u32 = 11
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        x[i] = seed >> 4
        seed = seed * 1664525 + 1013904223
        y[i] = seed >> 4
    }
    total: u64 = 0
    for r in 0..300000 {
        total += u64(dot(x, y))
        x[(r * 7919) & mask] += 1
    }
    put(total, "\n")
}
