// `alc test` optimises: recursion in tail position, also through the join of an if expression
// and between two functions the inliner merges, runs in constant stack at depths that would
// overflow the stack as real calls (tests/run/tailrec_join.al checks the results in every mode)

fn down(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { down(n - 1, acc + n) } }
fn total(n: i64) -> i64 { if n == 0 { 0 } else { n + total(n - 1) } }
fn divs(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { divs(n - 1, acc + 1000000 / n) } }
fn ev(n: i64) -> bool { if n == 0 { true } else { od(n - 1) } }
fn od(n: i64) -> bool { if n == 0 { false } else { ev(n - 1) } }
fn mark(n: i64, out: *i64) {
    if n > 0 {
        *out += 1
        mark(n - 1, out)
    }
}

const DEEP = 50000000

test "accumulator through a join" {
    assert down(DEEP, 0) == DEEP * (DEEP + 1) / 2
    assert total(DEEP) == DEEP * (DEEP + 1) / 2
}

test "local of a check's failure path" {
    s := 0
    for i in 1..=DEEP { s += 1000000 / i }
    assert divs(DEEP, 0) == s
}

test "mutual recursion" {
    assert ev(DEEP)
    assert od(DEEP + 1)
}

test "no result" {
    c := 0
    mark(DEEP, &c)
    assert c == DEEP
}

// sibling calls: the back end jumps to a callee in tail position (not inlined: noinline, or
// through a function value)
noinline fn ping(n: i64, k: i64) -> i64 { if n == 0 { k } else { pong(n - 1, k + 1) } }
noinline fn pong(n: i64, k: i64) -> i64 { if n == 0 { -k } else { ping(n - 1, k) } }
noinline fn fping(n: i64, x: f64) -> f64 { if n == 0 { x } else { fpong(n - 1, x + 1.0) } }
noinline fn fpong(n: i64, x: f64) -> f64 { if n == 0 { -x } else { fping(n - 1, x) } }
step: fn(i64) -> i64
noinline fn via(n: i64) -> i64 { if n == 0 { 7 } else { step(n - 1) } }

test "sibling calls" {
    assert ping(DEEP, 0) == DEEP / 2
    assert fping(DEEP + 1, 0.0) == -f64(DEEP / 2 + 1)
    step = via
    assert via(DEEP) == 7
}
