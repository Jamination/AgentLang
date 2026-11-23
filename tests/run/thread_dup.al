// jump threading past a block that does more than branch on a phi: the block's instructions are
// copied onto the threaded edge and the values it defines meet their copies in new phis (Opt
// tags and (value, ok) flags of inlined callees re-tested by the caller, compares of a phi with
// a constant, values used after the branch and in later loop iterations)
fn digit(c: u8) -> (i64, bool) {
    if c >= '0' && c <= '9' { return (i64(c - '0'), true) }
    (0, false)
}

fn half(x: i64) -> Opt[i64] {
    if x & 1 != 0 { return None }
    Some(x / 2)
}

noinline fn parse(s: str) -> (i64, i64) {
    acc := 0
    bad := 0
    for i in 0..len(s) {
        d, ok := digit(s[i])
        if !ok { bad += 1; continue }
        acc = acc * 10 + d
        if acc > 1000000 { acc = acc % 1000 }
    }
    (acc, bad)
}

noinline fn halves(n: i64) -> (i64, i64, i64) {
    s := 0
    none := 0
    last := -1
    for i in 0..n {
        match half(i * 3 + 1) {
            Some(v) => { s += v; last = v }
            None => { none += 1 }
        }
    }
    (s, none, last)
}

// a block that computes a value (k + 1) used after the join, branching on a compare of a phi
noinline fn tagged(xs: []i64) -> i64 {
    t := 0
    for x in xs {
        tag := 0
        if x > 10 { tag = 2 } else if x < -10 { tag = 1 }
        k := x * 7
        m := k + 1
        if tag == 2 {
            t += m
        } else if tag == 1 {
            t -= m
        } else {
            t ^= m
        }
        t += m & 3
    }
    t
}

fn main() {
    print(parse("12x4,567;89a0123456789"), parse(""), parse("zz"))
    print(halves(10), halves(1000), halves(0))
    xs := [9]i64{5, 20, -30, 0, 11, -11, 10, -10, 1000}
    print(tagged(xs[..]), tagged(xs[2..5]))
}
