// float -> u64 for values >= 2^63 (regression: they saturated at 2^63)
noinline fn id[T](x: T) -> T { x }
fn main() {
    a: f64 = 1.5e19
    b: f32 = 1.5e19
    print(u64(a), u64(id(a)), u64(id(b)), u64(1.5e19))
    print(u64(id(9223372036854775808.0)), u64(id(9.2e18)), u64(id(0.9)), u64(id(18446744073709549568.0)))
    print(u32(id(3.99e9)), u64(f32(id(2.5))))
}
