// sort_by with function values whose target is known: sort_by is too big to inline, so the
// optimiser specialises it for each comparison (named, nested, anonymous; with and without a
// context value); the order (stable) must be the same as without
struct P {
    key: i64
    seq: i64
}

fn by_key(a: P, b: P) -> bool {
    return a.key < b.key
}

fn desc(a: i64, b: i64) -> bool {
    return a > b
}

fn by_rank(rank: []i64, a: i64, b: i64) -> bool {
    return rank[a] < rank[b]
}

fn show(ps: []P) {
    for p in ps {
        put(p.key, "/", p.seq, " ")
    }
    put("\n")
}

fn data(n: i64) -> Vec[i64] {
    v := vec[i64]()
    seed: u64 = 12345
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        v.push(i64(seed >> 40) % 1000)
    }
    return v
}

fn main() {
    ps := vec[P]()
    for i in 0..12 {
        ps.push(P{key: (i * 5) % 4, seq: i})
    }
    sort_by(ps.items(), by_key)
    show(ps.items())
    sort_by(ps.items(), fn(a: P, b: P) -> bool { a.seq % 3 < b.seq % 3 })
    show(ps.items())
    fn later_first(a: P, b: P) -> bool {
        return a.seq > b.seq
    }
    sort_by(ps.items(), later_first)
    show(ps.items())
    v := data(15)
    sort_by(v.items(), desc)
    print(v.items())
    // with a context value
    rank := []i64{5, 3, 9, 1, 7, 0, 2}
    idx := vec[i64]()
    for i in 0..len(rank) {
        idx.push(i)
    }
    sort_by(idx.items(), rank, by_rank)
    print(idx.items())
    sort_by(idx.items(), 3, fn(m: i64, a: i64, b: i64) -> bool { a % m < b % m })
    print(idx.items())
    // the same comparison from two places (one specialised copy serves both)
    w := data(9)
    sort_by(w.items(), desc)
    print(w.items())
    // large: sorted, and the same sum
    big := data(200000)
    sum := 0
    for x in big {
        sum += x
    }
    sort_by(big.items(), fn(a: i64, b: i64) -> bool { a < b })
    ok := true
    s2 := 0
    for i in 0..big.len {
        s2 += big[i]
        if i > 0 && big[i - 1] > big[i] {
            ok = false
        }
    }
    print(ok, s2 == sum)
    strs := vec_of([]str{"pear", "fig", "apple", "kiwi", "banana"})
    sort(strs.items())
    print(strs.items())
    sort_by(strs.items(), fn(a: str, b: str) -> bool { len(a) < len(b) })
    print(strs.items())
}
