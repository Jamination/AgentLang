// iteration abstractions: for-in over Vec / slices / ranges with steps, and custom iterators

struct Stride { cur: i64, end: i64, step: i64 }

fn next(it: *Stride) -> (i64, bool) {
    if it.cur >= it.end { return (0, false) }
    v := it.cur
    it.cur += it.step
    (v, true)
}

struct Words { s: str, pos: i64 }

fn next(it: *Words) -> (str, bool) {
    n := len(it.s)
    while it.pos < n && it.s[it.pos] == ' ' { it.pos += 1 }
    if it.pos >= n { return ("", false) }
    start := it.pos
    while it.pos < n && it.s[it.pos] != ' ' { it.pos += 1 }
    (it.s[start..it.pos], true)
}

fn main() {
    n := 1000000
    v := vec[i64]()
    seed: u64 = 5
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        v.push(i64(seed >> 40))
    }
    text := alloc[u8](n)
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        text[i] = if (seed >> 60) < 3 { ' ' } else { u8('a' + (seed >> 33) % 26) }
    }
    s1 := 0
    s2 := 0
    s3 := 0
    s4 := 0
    s5 := 0
    for r in 0..60 {
        for x in v { s1 = s1 * 31 + x }
        for i, x in v {
            if x & 1 == 0 { s2 += x * i }
        }
        for i in r..n by 3 { s3 += v[i] ^ i }
        for x in v[100..n - 100] {
            if x > s4 & 0xFFFFFF { s4 += 1 } else { s4 += 3 }
        }
        it := Stride{r, n, 7}
        loop {
            k, ok := it.next()
            if !ok { break }
            s4 += v[k] & 255
        }
        w := Words{text, 0}
        loop {
            word, ok := w.next()
            if !ok { break }
            s5 = s5 * 31 + len(word) * i64(word[0])
        }
    }
    put(s1, " ", s2, " ", s3, " ", s4, " ", s5, "\n")
}
