// abs(-0.0) is 0.0; floor and ceil keep the sign of a zero result like C (ceil(-0.5) is -0.0)
fn main() {
    print(abs(f64(-0.0)), abs(f64(-2.5)), abs(i8(-128)), abs(-7), abs(f32(-0.0)))
    print(floor(f64(-0.0)), floor(f64(0.0)), floor(f64(-0.5)), floor(f64(0.5)), floor(f64(-1.5)))
    print(ceil(f64(-0.0)), ceil(f64(0.0)), ceil(f64(-0.5)), ceil(f64(0.5)), ceil(f64(-1.5)), ceil(f64(-1.0)))
}
