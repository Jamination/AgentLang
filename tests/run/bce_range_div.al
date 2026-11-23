// a division whose divisor a branch tested, but not against 0: the check must still fail
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn f(a: i64, b: i64) -> i64 {
    if b == 1 {
        return a
    }
    return a / b
}

noinline fn g(a: u64, b0: u64) -> u64 {
    b := b0
    s: u64 = 0
    while b != 1 {
        s += a % b
        b = b >> 1
    }
    return s
}

fn main() {
    print(f(h(7), h(1)), f(h(7), h(2)), g(100, 12))
    print(g(100, 2), g(100, 3))
    print(f(h(7), h(0)))
    print("not reached")
}
