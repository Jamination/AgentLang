// [codegen] hand-written top-down merge sort of strings with a hand-written byte compare
// (same algorithm in C on {ptr, len} pairs)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn less(a: str, b: str) -> bool {
    n := min(len(a), len(b))
    for i in 0..n {
        if a[i] != b[i] { return a[i] < b[i] }
    }
    len(a) < len(b)
}

fn msort(a: []str, tmp: []str) {
    n := len(a)
    if n < 2 { return }
    mid := n / 2
    msort(a[..mid], tmp[..mid])
    msort(a[mid..], tmp[mid..])
    i := 0
    j := mid
    k := 0
    while i < mid && j < n {
        if less(a[j], a[i]) {
            tmp[k] = a[j]
            j += 1
        } else {
            tmp[k] = a[i]
            i += 1
        }
        k += 1
    }
    while i < mid {
        tmp[k] = a[i]
        i += 1
        k += 1
    }
    while j < n {
        tmp[k] = a[j]
        j += 1
        k += 1
    }
    for t in 0..n { a[t] = tmp[t] }
}

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
    msort(a, alloc[str](n))
    h: u64 = 0
    for i, s in a {
        h = h * 1000003 + u64(len(s)) * 7 + u64(s[0]) + u64(s[len(s) - 1]) * 3
    }
    print(h, a[0], a[n / 2], a[n - 1])
}
