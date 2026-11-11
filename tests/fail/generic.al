struct Box[T] { v: T }
enum Opt[T] { Some(T), None }
fn ident[T](x: T) -> T { x }
fn make[T]() -> Box[T] { Box[T]{v: 0} }
fn pick[T](a: T, b: T) -> T { a }
fn area(s: Shape) -> f64 {
    match s {
        Circle(r) => r * r
    }
}
enum Shape { Circle(f64), Square(f64) }
fn main() {
    a := make()
    b := pick(1, "x")
    o: Opt = None
    c := None
    d := Box{v: 1}
    e := ident[i64, i64](1)
    f := undefined_fn(1)
    g := Box[i64]{w: 1}
    h := 5
    h()
    i := h.x
    j: [3]i64
    j[5] = 1
    k := j + 1
    break
    1 + 2
    m := &5
}
