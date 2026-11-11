Color :: enum { Red, Green, Blue }
Shape :: enum { Circle(f64), Rect(f64, f64), Empty }
Opt[T] :: enum { Some(T), None }

divmod :: (a: i64, b: i64) -> (i64, i64) {
    (a / b, a % b)
}
area :: (s: Shape) -> f64 {
    match s {
        Circle(r) => 3.0 * r * r
        Rect(w, h) => w * h
        Empty => 0.0
    }
}
find :: (a: []i64, x: i64) -> Opt[i64] {
    for i, v in a {
        if v == x {
            return Some(i)
        }
    }
    None
}
name :: (c: Color) -> str {
    match c { Red => "red"; Green => "green"; _ => "other" }
}
main :: () {
    q, r := divmod(17, 5)
    print(q, r, divmod(9, 4))
    t := (1, "two", 3.0)
    print(t.0, t.1, t.2, t)
    c := Green
    print(c, name(c), name(Blue), c == Green, i64(Blue))
    shapes := []Shape{Circle(1.0), Rect(2.0, 3.5), Empty}
    for s in shapes {
        put(area(s), " ")
    }
    print()
    print(shapes[1], shapes[2])
    a := []i64{5, 8, 13}
    match find(a, 13) {
        Some(i) => print("found at", i)
        None => print("missing")
    }
    r2 := find(a, 99)
    print(r2)
    n := 3
    w := match n { 1 => "one"; 2, 3 => "few"; _ => "many" }
    print(w)
    o: Opt[f64] = Some(2.5)
    match o { Some(v) => print(v * 2.0); None => {} }
    q, r = divmod(100, 7)
    print(q, r)
}
