// byte histogram of a 4 MiB buffer (scalar for both compilers: a store-dependent gather)
fn main() {
    n := 1 << 22
    b := alloc[u8](n)
    seed: u32 = 1234
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        // skewed distribution: many repeats of a few values
        b[i] = u8((seed >> 24) & (seed >> 16))
    }
    hist: [256]u32
    check: u64 = 0
    for r in 0..300 {
        for i in 0..256 {
            hist[i] = 0
        }
        for i in 0..n {
            hist[b[i]] += 1
        }
        for i in 0..256 {
            check = check * 31 + u64(hist[i])
        }
        b[r] = u8(r)
    }
    put(check, "\n")
}
