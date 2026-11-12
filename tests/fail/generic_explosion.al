// regression: generics that instantiate themselves with ever larger types hung the compiler
enum L[T] { N(*L[[]T]), E }
fn g[T](x: T, n: i64) -> i64 {
    if n == 0 { return 0 }
    return h((x, x), n - 1)
}
fn h[T](x: T, n: i64) -> i64 { g(&x, n) }
fn main() { l: L[i64]; print(g(1, 3), l) }
fn f[T](x: T) { f([]T{x}) }
struct B[T] { x: *B[(T, T)] }
fn k() { f(1); b: B[i64] }
