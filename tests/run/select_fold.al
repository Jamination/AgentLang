// selects left by if-conversion inside inlined `(T, bool)` functions: a select on a negated
// boolean, a select whose arm selects on the same condition (selfold), and a select on a
// branch's condition used under one side of that branch (selbr); `1 - x` of a non-boolean
// x and a select used after the branch joins keep their meaning
fn digit(c: u8) -> (i64, bool) {
    if c >= '0' && c <= '9' { return (i64(c - '0'), true) }
    (0, false)
}

fn mul_add(acc: i64, d: i64) -> (i64, bool) {
    if acc > 92233720368547757 { return (0, false) }
    (acc * 10 + d, true)
}

noinline fn parse(s: str) -> (i64, i64, bool) {
    acc := 0
    n := 0
    ok := true
    for c in s {
        d, good := digit(c)
        if !good { ok = false; continue }
        v, fits := mul_add(acc, d)
        if !fits { ok = false; continue }
        acc = v
        n += 1
    }
    (acc, n, ok)
}

noinline fn not_bool(x: i64, a: i64, b: i64) -> i64 {
    // 1 - x is no negation when x is 2
    return if 1 - x != 0 { a } else { b }
}

noinline fn after_join(c: bool, a: i64, b: i64) -> i64 {
    s := if c { a } else { b }
    t := 0
    if c {
        t = s + 1
    } else {
        t = s * 2
    }
    return t + s
}

fn main() {
    print(parse("12345"), parse("12x45"), parse("99999999999999999999"), parse(""))
    print(not_bool(0, 1, 2), not_bool(1, 1, 2), not_bool(2, 1, 2))
    print(after_join(true, 3, 4), after_join(false, 3, 4))
}
