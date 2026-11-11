// nested functions: misuse
fn apply(f fn(i64) i64, x i64) i64 { f(x) }
fn gen[T](x T) T {
    fn id[U](y U) U { y }
    x
}
fn main() {
    k := 1
    fn addk(x i64) i64 { x + k }
    print(apply(addk, 1))
    g := addk
    fn addk(x i64) i64 { x }
    fn k() {}
    early(1)
    fn early(x i64) { print(x) }
    fn uses_later() i64 { later_var + 1 }
    later_var := 5
    fn sets_later() { later2 = 1 }
    later2 := 0
    for i in 0..3 {
        fn brk() { break }
        brk()
    }
    lab: for i in 0..3 {
        fn brk2() { continue lab }
        brk2()
    }
    fn two(a i64, b i64) i64 { a + b + k }
    two(1)
    two(1, "x")
    addk = two
    addk[i64](1)
    fn noret() i64 { }
    fn fwd(x i64) i64 { addk(x) + two(x, x) }
    var cb fn(i64) i64 = fwd
    print(gen(1), uses_later(), noret())
    fn i64() {}
    fn calls_later() { later_fn() }
    fn later_fn() {}
    j := 2
    fn both(x i64) i64 { x + j + k }
    print(both)
    if k > 0 {
        fn local() {}
    }
    local()
}
