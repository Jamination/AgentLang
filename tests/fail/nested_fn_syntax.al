// nested and anonymous functions: declarations that are not allowed
main :: () {
    inline a :: () {}
    noinline b :: () {}
    priv c :: () {}
    extern "libc.so.6" getpid :: () -> i32
    f := [T](x: T) -> T { x }
    g := (i64, i64) -> bool { true }
    K :: 5
    L : i64 : 5
    P :: struct { x: i64 }
}
