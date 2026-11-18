// a keyword where a value is expected: the hint names it, and no unrelated hint is added
struct P { x: i64 }
fn main() {
    use := 1
    for i in 0..3 {
        if i == use { print(i) }
    }
    if use == P{x: 1}.x { print(1) }
}
