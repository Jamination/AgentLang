// abs(-0.0) is 0.0; floor and ceil keep the sign of a zero result like C (ceil(-0.5) is -0.0)
fn main() {
    print(abs(-0.0), abs(-2.5), abs(i8(-128)), abs(-7), abs(f32(-0.0)))
    print(floor(-0.0), floor(0.0), floor(-0.5), floor(0.5), floor(-1.5))
    print(ceil(-0.0), ceil(0.0), ceil(-0.5), ceil(0.5), ceil(-1.5), ceil(-1.0))
}
