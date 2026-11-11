// nested functions: declarations that are not allowed
fn main() {
    inline fn a() {}
    noinline fn b() {}
    priv fn c() {}
    extern "libc.so.6" fn getpid() i32
    f := fn(x i64) i64 { x }
}
