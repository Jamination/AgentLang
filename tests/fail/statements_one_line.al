// Two statements on one line without `;`: the error says so. The hint about a struct literal in
// a header comes only where the braces could hold a literal's fields.
struct Point { x: i64, y: i64 }
fn one() { x := 1; if x > 0 { print(x) x = 2 } }
fn two(n: i64) {
    x := 1
    if x > n { print(x) x = 2 }
}
fn three(p: Point) {
    if p == Point {1, 2} {
        print(1)
    }
}
fn four(n: i64) {
    while n > 0 { print(n) return }
}
fn five() {
    a := 1 b := 2
}
