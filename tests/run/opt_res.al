// Opt[T] and Res[T] of the standard library.
Account :: struct { id: i64, owner: str }

find :: (a: []i64, x: i64) -> Opt[i64] {
    for i, v in a {
        if v == x {
            return Some(i)
        }
    }
    None
}

parse :: (s: str) -> Res[i64] {
    v, ok := parse_i64(s)
    if !ok {
        return Err(fmt("not a number: ", s))
    }
    Ok(v)
}

half :: (n: i64) -> Res[i64] {
    if n % 2 != 0 {
        return Err("odd")
    }
    return Ok(n / 2)
}

quarter :: (s: str) -> Res[i64] {
    match parse(s) {
        Ok(n) => {
            match half(n) {
                Ok(h) => half(h)
                Err(e) => Err(concat("first half: ", e))
            }
        }
        Err(e) => Err(e)
    }
}

lookup :: (accounts: []Account, id: i64) -> Opt[*Account] {
    for i in 0..len(accounts) {
        if accounts[i].id == id {
            return Some(&accounts[i])
        }
    }
    return None
}

first[T] :: (xs: []T) -> Opt[T] {
    if len(xs) == 0 {
        return None
    }
    Some(xs[0])
}

describe :: (o: Opt[Res[i64]]) -> str {
    match o {
        Some(Ok(0)) => "zero"
        Some(Ok(n)) => fmt("ok ", n)
        Some(Err(e)) => fmt("error ", e)
        None => "none"
    }
}

main :: () {
    a := []i64{5, 8, 13}
    r := find(a, 8)
    q := find(a, 9)
    print(r, is_some(r), r.is_none(), r.unwrap(), r.or(-1))
    print(q, q.is_some(), is_none(q), q.or(-1), unwrap(find(a, 13)))
    p := parse("42")
    e := parse("x1")
    print(p, e, p.is_ok(), e.is_ok(), p.is_err(), e.is_err())
    print(p.unwrap(), e.or(7), p.or(7), error(e), len(p.error()))
    print(quarter("40"), quarter("6"), quarter("3"), quarter("z"))
    match parse("17") {
        Ok(n) if n > 10 => print("big", n)
        Ok(n) => print("small", n)
        Err(msg) => print("error:", msg)
    }
    // construction: inferred from the payload, from the expected type, or written out
    o: Opt[str] = None
    o = Some("text")
    x := Some(2.5)
    y := Opt[u8].Some(7)
    z := Res[bool].Err("no")
    w: Res[(i64, str)] = Ok((1, "one"))
    print(o, x, y, z, w, Opt.Some(1), Res[i64].Ok(2))
    // generic code, pointers, nesting
    print(first([]str{"a", "b"}), first(a[..0]), first([]f64{1.5}).or(0.0))
    accounts := []Account{Account{1, "ann"}, Account{2, "bob"}}
    match lookup(accounts, 2) {
        Some(acc) => { acc.owner = "bea" }
        None => {}
    }
    print(accounts[1].owner, lookup(accounts, 3).is_none())
    print(describe(Some(Ok(0))), describe(Some(Ok(4))), describe(Some(Err("bad"))), describe(None))
    // in a Vec and a Map
    v := vec[Opt[i64]]()
    v.push(Some(1))
    v.push(None)
    n := 0
    for it in v.items() {
        n += it.or(10)
    }
    m := map[str, Res[i64]]()
    m.set("a", parse("5"))
    m.set("b", parse("?"))
    got, _ := m.get("b")
    print(n, v.items(), m.get_or("a", Err("missing")), got.is_err())
}
