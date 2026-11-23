// calls in tail position that the back end makes jumps (optimised: the callee's arguments in
// registers, no locals in the caller's frame) and those it must leave calls: the results must
// be the same either way
struct Pair { a: i64, b: i64 }
struct Big { a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64 }

noinline fn ping(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { pong(n - 1, acc + 2) } }
noinline fn pong(n: i64, acc: i64) -> i64 { if n == 0 { acc } else { ping(n - 1, acc * 3 % 1000003) } }

noinline fn fsum(n: i64, x: f64) -> f64 { if n == 0 { x } else { fhalf(n - 1, x + 1.5) } }
noinline fn fhalf(n: i64, x: f64) -> f64 { if n == 0 { x } else { fsum(n - 1, x * 0.5) } }

// through a function value
noinline fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }
fn twice(x: i64) -> i64 { x * 2 }

// two results (projections)
noinline fn swap(p: Pair) -> Pair { Pair{a: p.b, b: p.a} }
noinline fn swap_twice(p: Pair, n: i64) -> Pair { if n == 0 { p } else { swap(Pair{a: p.a + n, b: p.b}) } }

// a large result
noinline fn big(x: i64) -> Big { Big{a: x, b: x + 1, c: x + 2, d: x + 3, e: x + 4, f: x + 5, g: x + 6, h: x + 7} }
noinline fn big_of(x: i64) -> Big { big(x * 10) }

// more arguments than registers: the callee's stack arguments
noinline fn many(a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64, h: i64, i: i64) -> i64 {
    a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i
}
noinline fn few(x: i64) -> i64 { many(x, x + 1, x + 2, x + 3, x + 4, x + 5, x + 6, x + 7, x + 8) }
noinline fn many_fp(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64, i: f64, j: f64) -> f64 {
    a + b * 2.0 + c * 3.0 + d * 4.0 + e * 5.0 + f * 6.0 + g * 7.0 + h * 8.0 + i * 9.0 + j * 10.0
}
noinline fn few_fp(x: f64) -> f64 { many_fp(x, x, x, x, x, x, x, x, x, x) }

// a pointer into the caller's frame
noinline fn read(p: *i64) -> i64 { *p + 1 }
noinline fn local(x: i64) -> i64 {
    y := x * 3
    read(&y)
}
noinline fn local_arr(x: i64) -> i64 {
    a := [4]i64{x, x + 1, x + 2, x + 3}
    sum_of(a[..])
}
noinline fn sum_of(s: []i64) -> i64 {
    t := 0
    for v in s { t += v }
    return t
}

// a defer runs after the call
noinline fn logged(x: i64, log: *Vec[i64]) -> i64 {
    defer { log.push(x) }
    twice(x)
}

fn main() {
    print(ping(100000, 1), fsum(1000, 0.0))
    print(apply(twice, 21), apply(fn(x: i64) -> i64 { x + 1 }, 41))
    q := swap_twice(Pair{a: 1, b: 2}, 5)
    print(q.a, q.b)
    b := big_of(3)
    print(b.a, b.d, b.h)
    print(few(1), few_fp(0.5))
    print(local(4), local_arr(10))
    log := vec[i64]()
    print(logged(7, &log), log.items())
}
