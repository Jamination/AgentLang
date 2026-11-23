// min and max of an i32 array in L1/L2 (64 KiB)
fn minmax(a: []i32) -> (i32, i32) {
    lo := a[0]
    hi := a[0]
    for i in 1..len(a) {
        lo = min(lo, a[i])
        hi = max(hi, a[i])
    }
    (lo, hi)
}

fn main() {
    n := 1 << 14
    mask := n - 1
    a := alloc[i32](n)
    seed: u32 = 77
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        a[i] = i32(seed)
    }
    total: i64 = 0
    for r in 0..120000 {
        lo, hi := minmax(a)
        total += i64(hi) - i64(lo) + i64(r & 7)
        seed = seed * 1664525 + 1013904223
        a[(r * 7919) & mask] = i32(seed) >> 1
    }
    put(total, "\n")
}
