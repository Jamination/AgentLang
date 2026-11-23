// f32 arithmetic and f32 <-> f64 <-> int conversions in a loop
fn main() {
    n := 1 << 20
    a := alloc[f32](n)
    for i in 0..n {
        a[i] = f32(i % 1000) * 0.01
    }
    isum := 0
    for pass in 0..160 {
        for i in 0..n {
            x := a[i]
            y := x * 1.37 + f32(i & 255)
            d := f64(y) * 0.731
            k := i64(d)
            isum += k
            a[i] = f32(d - f64(k)) + f32(k & 15) * 0.25
        }
    }
    fsum: f64 = 0.0
    for i in 0..n {
        fsum += f64(a[i])
    }
    print(isum, cast[u64](fsum))
}
