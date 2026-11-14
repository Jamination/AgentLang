// a keyword where a value is expected: the hint names it, and no unrelated hint is added
struct P { x: i64 }
fn main() {
    by := 1
    for i in 0..3 {
        if i == by { print(i) }
    }
    if by == P{x: 1}.x { print(1) }
}
