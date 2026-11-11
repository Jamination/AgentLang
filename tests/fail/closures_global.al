// closures: a global cannot be initialized with a literal
var g |i64| i64 = |x i64| i64 { x }
var h |i64| i64 = two
fn two(a i64, b i64) i64 { a + b }
fn main() { print(g(1), h(1)) }
