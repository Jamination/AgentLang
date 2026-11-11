// nested and anonymous functions: misuse
apply :: (f: (i64) -> i64, x: i64) -> i64 { f(x) }
gen[T] :: (x: T) -> T {
    id[U] :: (y: U) -> U { y }
    x
}
main :: () {
    k := 1
    addk :: (x: i64) -> i64 { x + k }
    print(apply((x: i64) -> i64 { x * k }, 1))
    setk :: () { k = 2 }
    addk :: (x: i64) -> i64 { x }
    k :: () {}
    early(1)
    early :: (x: i64) { print(x) }
    uses_later :: () -> i64 { later_var + 1 }
    later_var := 5
    for i in 0..3 {
        brk :: () { break }
        g := () -> i64 { i }
    }
    lab: for j in 0..3 {
        brk2 :: () { continue lab }
    }
    two :: (a: i64, b: i64) -> i64 { a + b }
    two(1)
    two(1, "x")
    two = two
    two[i64](1, 2)
    noret :: () -> i64 { }
    i64 :: () {}
    calls_later :: () { later_fn() }
    later_fn :: () {}
    if k > 0 {
        local :: () {}
    }
    local()
    cb: (i64) -> i64 = (x: i64, y: i64) -> i64 { x }
    apply((s: str) -> i64 { 0 }, 1)
    print(gen(1))
}
param :: (p: i64) -> () -> i64 {
    return () -> i64 { p }
}
