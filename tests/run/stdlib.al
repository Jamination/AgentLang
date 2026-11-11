Pt :: struct { x: i64, y: i64 }

by_len :: (a: str, b: str) -> bool {
    len(a) < len(b)
}

main :: () {
    // Vec
    v := vec[i64]()
    for i in 0..20 {
        v.push(i * i % 7)
    }
    print(v.len, v.pop(), v.pop(), v.len, v.items()[..5])
    sort(v.items())
    print(v.items())
    names := vec[str]()
    names.push("pear")
    names.push("fig")
    names.push("banana")
    names.push("kiwi")
    sort_by(names.items(), by_len)
    print(names.items()[0], names.items()[1], names.items()[2], names.items()[3])

    // Map with integer, string and struct keys
    m := map[i64, str]()
    m.set(3, "three")
    m.set(1, "one")
    m.set(40, "forty")
    m.set(3, "THREE")
    s, ok := m.get(3)
    s2, ok2 := m.get(9)
    print(m.len, s, ok, len(s2), ok2, m.has(40), m.del(1), m.del(1), m.len, m.get_or(1, "none"))
    counts := map[str, i64]()
    words := split("the quick brown fox jumps over the lazy dog the end", ' ')
    for w in words {
        counts.set(w, counts.get_or(w, 0) + 1)
    }
    print(counts.len, counts.get_or("the", 0), counts.get_or("fox", 0), counts.get_or("cat", 0))
    grid := map[Pt, f64]()
    for i in 0..1000 {
        grid.set(Pt{i % 37, i % 11}, f64(i))
    }
    g, _ := grid.get(Pt{5, 5})
    print(grid.len, g, grid.has(Pt{36, 10}), grid.has(Pt{37, 0}))
    big := map[u64, u64]()
    x: u64 = 1
    for i in 0..5000 {
        x = x * 6364136223846793005 + 1442695040888963407
        big.set(x >> 40, u64(i))
    }
    total: u64 = 0
    ks := big.keys()
    for k in ks {
        total += big.get_or(k, 0)
    }
    print(big.len, len(ks), total)

    // equality and hashing
    a := Pt{1, 2}
    b := Pt{1, 2}
    c := Pt{2, 1}
    print(a == b, a != b, a == c, (1, "x") == (1, "x"), (1, "x") == (1, "y"), hash(a) == hash(b), hash(a) == hash(c))
    print([]i64{1, 2, 3} == []i64{1, 2, 3}, []i64{1, 2} == []i64{1, 2, 3}, [3]i64{1, 2, 3} == [3]i64{1, 2, 4}, hash("abc") == hash("abc"), hash(0.0) == hash(-0.0))

    // strings
    t := concat("foo", "bar")
    print(t, find(t, "ob"), find(t, "zz"), starts_with(t, "foo"), ends_with(t, "bar"), ends_with(t, "baz"))
    print(trim("  padded\t\n"), len(trim("   ")), cmp("abc", "abd") < 0, cmp("b", "abc") > 0, cmp("x", "x"))
    parts := split("a,b,,c", ',')
    print(len(parts), parts[0], parts[1], len(parts[2]), parts[3], len(lines("l1\nl2\n")), len(lines("")))
    n1, k1 := parse_i64("-12345")
    n2, k2 := parse_i64("12x")
    n3, k3 := parse_i64("9223372036854775807")
    print(n1, k1, n2, k2, n3, k3)
    f1, _ := parse_f64("3.25")
    f2, _ := parse_f64("-1.5e3")
    f3, _ := parse_f64("0.1")
    f4, k4 := parse_f64("abc")
    f5, _ := parse_f64("1e-3")
    print(f1, f2, f3, f4, k4, f5)
    msg := fmt("point ", a, " has ", 2, " fields; pi~", 3.14159)
    print(msg, len(msg))
    print(min(3, 9), max(2.5, 1.5), abs(-7), abs(2.5), floor(2.7), floor(-2.1), ceil(2.1), ceil(-2.9))
    p := 10
    q := 20
    swap(&p, &q)
    print(p, q)
    src := []i64{9, 8, 7}
    dst := alloc[i64](5)
    print(copy(dst, src), dst)
    fill(dst, 4)
    print(dst)
    av := args()
    print(len(av), av[1], av[2])
}
