// [library] sort an array of strings with the library sort([]str) (C: qsort with a
// memcmp-based comparator)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn main() {
    n := 1000000
    seed: u64 = 31
    pool := alloc[u8](n * 24)
    a := alloc[str](n)
    off := 0
    for i in 0..n {
        seed = lcg(seed)
        l := 6 + i64((seed >> 33) % 18)
        for j in 0..l {
            seed = lcg(seed)
            pool[off + j] = u8(97 + (seed >> 33) % 4)
        }
        a[i] = pool[off..off + l]
        off += l
    }
    sort(a)
    h: u64 = 0
    for i, s in a {
        h = h * 1000003 + u64(len(s)) * 7 + u64(s[0]) + u64(s[len(s) - 1]) * 3
    }
    print(h, a[0], a[n / 2], a[n - 1])
}
