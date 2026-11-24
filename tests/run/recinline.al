// one level of a small self-recursive function inlined into itself (inline_recursive):
// fib after tail recursion elimination, ackermann, a recursion that prints in pre- and
// post-order (the order stays), one whose argument is an aggregate, and one through a
// function value; a large recursive function is left as it is
fn fib(n: i64) -> i64 {
    if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn ack(m: i64, n: i64) -> i64 {
    if m == 0 { return n + 1 }
    if n == 0 { return ack(m - 1, 1) }
    ack(m - 1, ack(m, n - 1))
}

fn walk(n: i64) {
    if n == 0 { return }
    put(n, "<")
    walk(n - 1)
    put(">", n, " ")
}

struct P {
    a: i64
    b: i64
    c: i64
}

fn psum(p: P, d: i64) -> i64 {
    if d == 0 { return p.a + p.b + p.c }
    q := P{a: p.b, b: p.c, c: p.a + d}
    return psum(q, d - 1) * 2 - p.a
}

fn big(n: i64, s: str) -> i64 {
    if n <= 0 { return len(s) }
    t := 0
    for i in 0..n {
        t += i * i % 7 + len(s) * (i & 3) - (i ^ n) % 5 + (t >> 3) % 11
    }
    return t + big(n / 2, s) - big(n / 3, s)
}

fn main() {
    print(fib(20), fib(1), fib(0))
    print(ack(2, 3), ack(3, 3), ack(0, 0))
    walk(4)
    put("\n")
    print(psum(P{a: 1, b: 2, c: 3}, 5))
    f := fib
    print(f(15))
    print(big(40, "abc"))
}
