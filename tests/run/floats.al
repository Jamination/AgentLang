fn show(x f64) {
    put(x, " ")
}
fn main() {
    nan := 0.0 / zero()
    inf := 1.0 / zero()
    print(nan == nan, nan != nan, nan < 1.0, nan > 1.0, nan <= nan, nan >= nan, 1.0 < inf, -inf < inf)
    print(nan, inf, -inf, -0.0, 0.0 == -0.0)
    a := 0.1
    b := 0.2
    print(a + b, a + b == 0.3, 1e308 * 10.0, 5e-324 / 2.0, 2.0 * 3.5, 7.0 / 2.0, -7.5 / 2.0)
    print(i64(2.9), i64(-2.9), i64(1e18), u8(200.7), i32(-1.5), f64(i64(-3)), f64(u8(255)), f64(i32(-7)))
    print(sqrt(2.0), sqrt(16.0), fabs(-3.25), fabs(3.25), sqrt(0.0))
    show(1.0); show(1.5); show(100.0); show(1e15); show(1e16); show(123456789012345680.0); show(1e21); show(1e22); print()
    show(0.001); show(0.0001); show(0.00001); show(0.000001); show(1.5e-10); show(123.456); show(0.3); print()
    putf(1.0 / 3.0, 0); putc(' '); putf(1.0 / 3.0, 5); putc(' '); putf(2.0 / 3.0, 15); putc(' '); putf(1e10, 2); putc(' '); putf(-0.0005, 3); putc(' '); putf(0.5, 0); putc(' '); putf(1.5, 0); putc('\n')
    x := 1.0
    for i in 0..60 {
        x = x * 1.5 - 0.25
    }
    putf(x, 3)
    putc('\n')
    var arr [4]f64
    for i in 0..4 {
        arr[i] = f64(i) * 1.25 - 1.0
    }
    s := 0.0
    for v in arr {
        s += v * v
    }
    print(s, arr)
    print(cast[u64](1.0), cast[f64](u64(0x4000000000000000)), cast[i64](-0.0))
    print(max(1.5, 2.5) * min(-1.0, 1.0), 3.0 > 2.0 && 2.0 > 1.0, 1.0 > 2.0 || 2.0 > 1.0)
}
noinline fn zero() f64 { 0.0 }
