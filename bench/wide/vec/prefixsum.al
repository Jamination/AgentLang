// in-place inclusive prefix sum over u64 (serial dependency: not vectorizable as written)
fn scan(a: []u64) {
    acc: u64 = 0
    for i in 0..len(a) {
        acc += a[i]
        a[i] = acc
    }
}

fn main() {
    n := 1 << 16
    a := alloc[u64](n)
    seed: u32 = 2024
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        a[i] = u64(seed >> 8)
    }
    check: u64 = 0
    for r in 0..30000 {
        scan(a)
        check = check * 31 + a[n - 1] + a[(r * 7919) & (n - 1)]
        a[r & (n - 1)] = u64(r)
    }
    put(check, "\n")
}
