// [codegen] substring search: naive and Boyer-Moore-Horspool, counting all occurrences of
// 12 patterns in an 8 MB text over an 8-letter alphabet (same loops in C)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn naive_count(s: []u8, p: []u8) -> i64 {
    n := len(s)
    m := len(p)
    c := 0
    for i in 0..n - m + 1 {
        j := 0
        while j < m && s[i + j] == p[j] { j += 1 }
        if j == m { c += 1 }
    }
    c
}

fn bmh_count(s: []u8, p: []u8) -> i64 {
    n := len(s)
    m := len(p)
    shift: [256]i64
    for k in 0..256 { shift[k] = m }
    for k in 0..m - 1 { shift[p[k]] = m - 1 - k }
    last := p[m - 1]
    c := 0
    i := 0
    while i + m <= n {
        x := s[i + m - 1]
        if x == last {
            j := 0
            while j < m - 1 && s[i + j] == p[j] { j += 1 }
            if j == m - 1 { c += 1 }
        }
        i += shift[x]
    }
    c
}

fn main() {
    n := 8 << 20
    s := alloc[u8](n)
    seed: u64 = 3
    for i in 0..n {
        seed = lcg(seed)
        s[i] = u8(97 + (seed >> 61))
    }
    a := 0
    b := 0
    for q in 0..24 {
        seed = lcg(seed)
        m := 3 + q % 12
        at := i64((seed >> 33) % u64(n - m))
        p := s[at..at + m]
        a = a * 31 + naive_count(s, p)
        b = b * 31 + bmh_count(s, p)
    }
    print(a, b)
}
