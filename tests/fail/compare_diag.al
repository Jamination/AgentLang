// Comparisons that are not defined say why; an ambiguous variant as the value of a match arm
// is reported once, at the name.
struct S { a: i64 }
enum Shape { Circle(f64), Empty }
enum A { X(i64), Y }
enum B { X(i64), Y, Z }
fn nothing() {}
fn main() {
    a := "a" < "b"
    s := S{1}
    b := s <= s
    c := Empty > Circle(1.0)
    d := nothing() == nothing()
    e := true < false
    u := A.Y
    f := u == Z
    n := 1
    g := match n {
        0 => X(1)
        1 => Y
        _ => X(2)
    }
    h := match n {
        0 => Y
        _ => 5
    }
}
