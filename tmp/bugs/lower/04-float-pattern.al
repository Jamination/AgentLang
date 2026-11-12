// a float matched against constant patterns was compared bitwise (integer Eq): -0.0 did not match 0.0, and at -O0 1.5 did not match 1.5
// expected: 1 1 2 3 3 / 1 1 2 3 / 1 2 3 / 1 2 3
noinline fn f5(x: f64) -> i64 {
    match x {
        0.0 => 1
        1.5 => 2
        _ => 3
    }
}
noinline fn f6(x: f32) -> i64 {
    match x { 0.0 => 1; -2.5 => 2; _ => 3 }
}
noinline fn f7(x: (f64, i64)) -> i64 {
    match x { (0.0, 1) => 1; (1.5, _) => 2; _ => 3 }
}
noinline fn f8(x: Opt[f32]) -> i64 {
    match x { Some(0.0) => 1; Some(1.5) => 2; _ => 3 }
}
fn main() {
    z: f64 = 0.0
    y: f32 = 0.0
    print(f5(z), f5(-z), f5(1.5), f5(z / z), f5(2.0))
    print(f6(y), f6(-y), f6(-2.5), f6(1.0))
    print(f7((-z, 1)), f7((1.5, 7)), f7((z / z, 1)))
    print(f8(Some(-y)), f8(Some(1.5)), f8(None))
}
