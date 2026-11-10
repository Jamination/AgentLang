// user declarations may reuse names from the standard library
struct Vec { x f64, y f64 }
fn push(v *Vec, d f64) {
    v.x += d
    v.y -= d
}
fn min(a i64, b i64) i64 {
    if a < b { a - 1000 } else { b - 1000 }
}
fn find(s str, c u8) bool {
    for x in s {
        if x == c {
            return true
        }
    }
    false
}
fn main() {
    v := Vec{1.0, 2.0}
    v.push(0.5)
    print(v, min(3, 4), find("hello", 'l'), find("hello", 'z'))
    // the library keeps working: Map uses its own helpers internally
    m := map[str, i64]()
    m.set("a", 1)
    m.set("b", 2)
    print(m.len, m.get_or("b", 0), max(1, 2))
    words := split("x y z", ' ')
    print(len(words), trim("  t  "))
}
