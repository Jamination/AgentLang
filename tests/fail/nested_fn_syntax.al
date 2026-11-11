// nested and anonymous functions: declarations that are not allowed
main :: () {
    inline fn a() {}
    noinline fn b() {}
    priv fn c() {}
    extern "libc.so.6" fn getpid() i32
    f := fn[T](x T) T { x }
}
