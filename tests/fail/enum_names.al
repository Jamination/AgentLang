enum Color { Red, Green, Blue }
enum Light { Red, Amber, Green }
enum Maybe[T] { Some(T), None }
fn f(c Color) str { "color" }
fn f(l Light) str { "light" }
fn Blue2() i64 { 1 }
enum Bad { Blue2, f }
enum Dup { X, Y, X }
struct Red2 { x i64 }
enum Bad2 { Red2 }
struct Node { next *Node }
fn main() {
    print(f(Red))
    a := Red
    b := Color.Purple
    c := Maybe.Some
    d := Maybe[i64, i64].None
    e := Opt.Nothing(1)
    g := Color.Red(3)
    h := Light
    i := Colour.Red
    var j Color = Amber
    k := Maybe[i64].Some("x")
    l := Maybe[i64].Some(1, 2)
    m := None
    var n Opt[i64] = Maybe.None
    var o *Node = None
    p := (Green, 1)
    q := Green == Green
    var r Opt[i64] = Some(1)
    var s Maybe[i64] = Some(1)
    t := r == s
    u := is_some(s)
}
