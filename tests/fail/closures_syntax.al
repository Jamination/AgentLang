// closures: syntax errors
fn takes(f |a i64| i64) i64 { f(1) }
fn main() {
    f := |a, b| { a < b }
    h := |x i64| x * 2
    w := fn(a i64) i64 { a }
    x := true
        || false
}
