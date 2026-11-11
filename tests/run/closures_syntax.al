// closure types and literals: forms of the syntax
struct S {
    a |i64|
    b || i64
    c ||
    d | |i64| i64, i64| i64
    e i64
}
var gv ||
var gw |i64|
const K = 3

fn dbl(x i64) i64 { x * 2 }
fn hof(f | |i64||, n i64) { f(|x i64| { print("inner", x + n) }) }
fn ret_cl() || i64 { || i64 { 7 } }
fn ret_cl2() |i64| |i64| i64 {
    |a i64| |i64| i64 { |b i64| i64 { a + b } }
}
fn takes_fn_in_bars(f |fn(i64) i64, i64| i64) i64 { f(dbl, 5) }
fn cond(f || bool) bool { f() }
fn three(f || i64) i64 { f() }
// `|` and `||` stay operators after an operand, also at the end of a line
fn flags() i64 {
    a := 1
    b := 2
    c := a |
        b |
        4
    d := a > 5 ||
        b > 1
    if d { return c }
    0
}

fn main() {
    var s S
    var cnt i64
    s.a = |x i64| { cnt += x }
    s.b = || i64 { cnt * 2 }
    s.c = || { cnt += 100 }
    s.d = |f |i64| i64, x i64| i64 { f(x) + 1 }
    s.a(5)
    s.c()
    print(s.b(), s.d(dbl, 4), s.e)
    var l1 |i64|
    var l2 ||
    l1 = s.a
    l2 = s.c
    l1(1)
    l2()
    gv = l2
    gw = l1
    gv()
    gw(3)
    print(cnt)
    hof(|g |i64|| { g(1); g(2) }, 10)
    print(ret_cl()(), ret_cl2()(3)(4))
    print(takes_fn_in_bars(|f fn(i64) i64, x i64| i64 { f(x) + K }))
    // closure types as type arguments
    v := vec[|i64| bool]()
    v.push(|x i64| bool { x > K })
    w := vec[|| i64]()
    w.push(|| i64 { cnt })
    print(v.buf[0](4), w.buf[0](), flags())
    z := alloc[|i64|](2)
    z[0] = s.a
    z[0](1000)
    print(cnt, len(z))
    t := || || i64 { || i64 { 9 } }
    e := || {}
    e()
    k := | | i64 { 1 }
    o := (1 | 2) > 0 || false
    print(t()(), k(), o)
    // a literal whose last parameter is a closure without result: `||` closes both lists
    g := |x i64, f |i64|| { f(x) }
    out := 0
    g(5, |y i64| { out = y * 2 })
    print(out)
    // literals inside the headers of if / for / while / match
    xs := []i64{1, 2, 3, 4}
    if xs.any(|x i64| bool { x > 3 }) {
        print("any")
    }
    for x in xs.filter(|x i64| bool { x % 2 == 0 }) {
        put(x, " ")
    }
    print("")
    n := 0
    while cond(|| bool { n < 3 }) {
        n += 1
    }
    match three(|| i64 { n }) {
        3 => print("three")
        _ => print("other")
    }
    h := |a i64,
          b i64| i64 {
        a * b
    }
    print(h(6, 7))
}
