noinline fn id[T](x: T) -> T { x }
const A: u64 = 0x8000008000000001
const B = f32(A)
fn main() {
    print(f64(f32(id(A))), f64(B), f64(f32(A)), f32(id(u64(5))), f64(id(A)))
}
