// nested and anonymous functions: declarations that are not allowed
fn main() {
    inline fn a() {}
    noinline fn b() {}
    priv fn c() {}
    extern "libc.so.6" fn getpid() -> i32
    f := fn[T](x: T) -> T { x }
    g := fn(i64, i64) -> bool { true }
    const K = 5
    struct P { x: i64 }
    enum E { A }
    type R = i64
}
