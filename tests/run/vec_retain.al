// retain: both forms, element types of several sizes, method syntax, nested and anonymous
// functions as keep, a context that counts and records the calls, and 10,000 random vectors
// compared with a reference loop

struct Unit {
    name: str,
    hp: i64,
    tags: Vec[str],
}

struct Big {
    a: [5]i64,
    b: u8,
}

struct Calls {
    n: i64,
    seen: Vec[i64],
}

fn odd(x: i64) -> bool {
    return x % 2 != 0
}

fn counted(c: *Calls, x: i64) -> bool {
    c.n += 1
    c.seen.push(x)
    return x % 3 == 0
}

seed: u64 = 0x9E3779B97F4A7C15

fn rnd(n: i64) -> i64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return i64(seed % u64(n))
}

fn main() {
    // empty
    e := vec[i64]()
    e.retain(odd)
    print("empty:", e.len)
    calls := Calls{}
    e.retain(&calls, counted)
    print("empty with ctx:", e.len, calls.n)

    // keep none, keep all, alternating
    v := vec_of([]i64{1, 2, 3, 4, 5, 6, 7})
    w := clone(v)
    v.retain(fn(x: i64) -> bool { false })
    print("none:", v.len, v[..])
    w.retain(fn(x: i64) -> bool { true })
    print("all:", w.len, w[..])
    w.retain(odd)
    print("odd:", w[..])
    retain(&w, fn(x: i64) -> bool { x != 3 })
    print("plain call:", w[..])

    // the context counts the calls and sees every element once, in order
    c := vec_of([]i64{9, 1, 6, 4, 3, 3, 0, 8})
    calls = Calls{}
    c.retain(&calls, counted)
    print("ctx:", c[..], "calls", calls.n, "seen", calls.seen[..])

    // a context by value
    lim := vec_of([]i64{5, 12, 7, 30, 1})
    lim.retain(10, fn(limit: i64, x: i64) -> bool { x < limit })
    print("below 10:", lim[..])

    // a nested function
    fn short(s: str) -> bool {
        return len(s) <= 3
    }
    words := vec_of([]str{"a", "bbbb", "cc", "ddddd", "eee"})
    words.retain(short)
    print("short:", words[..])

    // element types of several sizes
    bytes := vec_of([]u8{1, 200, 3, 255, 0})
    bytes.retain(fn(b: u8) -> bool { b < 128 })
    print("u8:", bytes.len, bytes[0], bytes[1], bytes[2])
    halves := vec_of([]i16{-3, 4, -5, 6})
    halves.retain(fn(h: i16) -> bool { h > 0 })
    print("i16:", halves[..])
    fl := vec_of([]f64{0.5, -1.5, 2.25, -0.0})
    fl.retain(fn(x: f64) -> bool { x >= 0.0 })
    print("f64:", fl[..])
    pairs := vec_of([](i32, u8){(1, 'a'), (2, 'b'), (3, 'c')})
    pairs.retain(fn(p: (i32, u8)) -> bool { p.0 != 2 })
    print("tuples:", pairs[..])
    bigs := vec[Big]()
    for i in 0..6 {
        bigs.push(Big{a: [5]i64{i, i * 10, i * 100, i * 1000, i * 10000}, b: u8(i)})
    }
    bigs.retain(fn(b: Big) -> bool { b.a[2] % 200 == 0 })
    print("big:", bigs.len, bigs[0].a, bigs[1].a[4], bigs[2].b)

    // structs with Vec fields: the kept ones keep their own Vecs
    units := vec[Unit]()
    for i in 0..5 {
        u := Unit{name: fmt("u", i), hp: i - 2}
        for k in 0..i {
            u.tags.push(fmt("t", k))
        }
        units.push(u)
    }
    units.retain(fn(u: Unit) -> bool { u.hp > 0 })
    for u in units {
        print("unit:", u.name, u.hp, u.tags[..])
    }
    units[0].tags.push("new")
    print("unit after push:", units[0].tags[..], units[1].tags.len)

    // the capacity stays; slots past the new length are not cleared (as with truncate)
    big := vec[i64]()
    for i in 0..100000 {
        big.push(i)
    }
    cap := len(big.buf)
    big.retain(fn(x: i64) -> bool { x % 1000 == 999 })
    print("large:", big.len, big[0], big[99], len(big.buf) == cap, big.buf[100] == 100)
    sum := 0
    for x in big {
        sum += x
    }
    print("large sum:", sum)

    // retain as a function value
    f := retain[i64]
    g := vec_of([]i64{1, 2, 3})
    f(&g, odd)
    print("value:", g[..])

    // 10,000 random vectors against a reference loop
    bad := 0
    total := 0
    for round in 0..10000 {
        n := rnd(40)
        r := vec[i64]()
        for _ in 0..n {
            r.push(rnd(100))
        }
        // even rounds: the context form, odd rounds: the plain form with `odd`
        m := if round % 2 == 0 { rnd(5) + 1 } else { 2 }
        ref := vec[i64]()
        for x in r {
            if x % m != 0 {
                ref.push(x)
            }
        }
        if round % 2 == 0 {
            r.retain(m, fn(m: i64, x: i64) -> bool { x % m != 0 })
        } else {
            r.retain(odd)
        }
        if r[..] != ref[..] {
            bad += 1
        }
        total += r.len
    }
    print("random: mismatches", bad, "kept", total)
}
