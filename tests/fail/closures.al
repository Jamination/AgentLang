// closures: misuse
struct S { f |i64| i64 }
fn call_fn(f fn(i64) i64, x i64) i64 { f(x) }
fn takes(f |i64, i64| bool) bool { f(1, 2) }
fn pick(f |i64| i64) i64 { f(1) }
fn pick(f |str| i64) i64 { f("a") }
fn gen[T](x T, f |T| T) T { f(x) }
fn leak() fn(i64) i64 {
    base := 1
    |x i64| i64 { x + base }
}
fn main() {
    k := 1
    print(takes(|a i64, b f64| bool { a < 2 }))
    print(call_fn(|x i64| i64 { x + k }, 1))
    c := |x i64| i64 { x + k }
    print(c(1, 2))
    print(c == c)
    print(hash(c))
    for i in 0..3 {
        e := || { break }
        e()
    }
    g := |x i64| { x * 2 }
    var fp fn(i64) i64 = c
    var s S
    print(s == s)
    var t |i64| i64 = takes
    j := || i64 { }
    print(pick(|x f64| i64 { 1 }))
    z := |x i64| i64 { later }
    later := 5
    takes(|a i64, b i64| bool { return 5 })
    var u |i64| = |x i64| i64 { x }
    print(gen("a", takes))
    x := |i64| i64
    print(c == nil)
    c("one")
    nope := |q i64| i64 { q }
    nope.missing = 1
}
