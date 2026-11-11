// nested and anonymous functions: misuse
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }
fn gen[T](x: T) -> T {
    fn id[U](y: U) -> U { y }
    x
}
fn main() {
    k := 1
    fn addk(x: i64) -> i64 { x + k }
    print(apply(fn(x: i64) -> i64 { x * k }, 1))
    fn setk() { k = 2 }
    fn addk(x: i64) -> i64 { x }
    fn k() {}
    early(1)
    fn early(x: i64) { print(x) }
    fn uses_later() -> i64 { later_var + 1 }
    later_var := 5
    for i in 0..3 {
        fn brk() { break }
        g := fn() -> i64 { i }
    }
    lab: for j in 0..3 {
        fn brk2() { continue lab }
    }
    fn two(a: i64, b: i64) -> i64 { a + b }
    two(1)
    two(1, "x")
    two = two
    two[i64](1, 2)
    fn noret() -> i64 { }
    fn i64() {}
    fn calls_later() { later_fn() }
    fn later_fn() {}
    if k > 0 {
        fn local() {}
    }
    local()
    cb: fn(i64) -> i64 = fn(x: i64, y: i64) -> i64 { x }
    apply(fn(s: str) -> i64 { 0 }, 1)
    print(gen(1))
}
fn param(p: i64) -> fn() -> i64 {
    return fn() -> i64 { p }
}
