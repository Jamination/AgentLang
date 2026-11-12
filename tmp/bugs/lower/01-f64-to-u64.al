// u64(x) for a float x >= 2^63 gave 9223372036854775808 (cvttsd2si saturation)
// expected: 15000000000000000000 15000000520515485696
noinline fn id[T](x: T) -> T { x }
fn main() {
    a: f64 = 1.5e19
    b: f32 = 1.5e19
    print(u64(id(a)), u64(id(b)))
}
