// tail recursion through the join of an if expression (the returned value is a phi), with and
// without an accumulator, and recursion that must stay recursion
struct Pair { a: i64, b: i64 }

fn fib(n: i64) -> i64 { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
fn gcd(a: i64, b: i64) -> i64 { if b == 0 { a } else { gcd(b, a % b) } }
fn digsum(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { digsum(n / 10, acc + n % 10) } }
fn fact(n: i64) -> i64 { if n <= 1 { 1 } else { n * fact(n - 1) } }
fn xsum(n: i64) -> i64 { if n == 0 { 0 } else { (n * 7) ^ xsum(n - 1) } }
// two joins: the inner if's phi feeds the outer one
fn steps(n: i64, k: i64) -> i64 {
    if n == 1 { k } else if n % 2 == 0 { steps(n / 2, k + 1) } else { steps(3 * n + 1, k + 1) }
}
fn tick(n: i64, out: *i64) {
    if n > 0 {
        *out += n
        tick(n - 1, out)
    }
}
// mutual recursion: the inliner makes it self recursion
fn is_even(n: i64) -> bool { if n == 0 { true } else { is_odd(n - 1) } }
fn is_odd(n: i64) -> bool { if n == 0 { false } else { is_even(n - 1) } }

// must not become loops: the callee reads the caller's local through a pointer
fn chain(p: *i64, n: i64) -> i64 {
    x := *p + n
    if n == 0 { x } else { chain(&x, n - 1) + 0 }
}
fn chain2(p: *i64, n: i64) -> i64 {
    x := *p * 2 + n
    if n == 0 { x } else { chain2(&x, n - 1) }
}
// a struct returned by value, built from the recursive result
fn pairs(n: i64) -> Pair {
    if n == 0 { Pair{a: 0, b: 1} } else {
        p := pairs(n - 1)
        Pair{a: p.b, b: p.a + p.b}
    }
}
// a struct argument
fn walk(p: Pair, n: i64) -> i64 {
    if n == 0 { p.a * 1000 + p.b } else { walk(Pair{a: p.b, b: p.a + 1}, n - 1) }
}
// the call is not the returned value
fn notail(n: i64) -> i64 { if n == 0 { 0 } else { notail(n - 1) - 1 } }
// a defer runs after the call
fn deferred(n: i64, log: *Vec[i64]) -> i64 {
    defer { log.push(n) }
    if n == 0 { 0 } else { deferred(n - 1, log) }
}

fn main() {
    print(fib(20), gcd(1071, 462), gcd(270, 192), digsum(987654321, 0), fact(15), xsum(1000))
    print(steps(27, 0), steps(97, 0))
    t := 0
    tick(100000, &t)
    print(t)
    print(is_even(100001), is_odd(100001), is_even(7), is_odd(8))
    s := 1
    print(chain(&s, 10), chain2(&s, 10))
    p := pairs(30)
    print(p.a, p.b, walk(Pair{a: 1, b: 2}, 11))
    print(notail(1000))
    log := vec[i64]()
    print(deferred(5, &log), log.items())
}
