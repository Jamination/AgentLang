enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum Color { Red, Green, Blue }
struct P { x: i64, y: i64 }
enum W { A(P), B(i64, str), C }
const K = 3
fn main() {
    s := Circle(1.0)
    w := B(1, "x")
    lim := 5
    n := 3
    t := (1, 2)
    match s {
        &x => {}
        Circle => {}
        Rect(a) => {}
        Square(q) => {}
        Color.Red => {}
        Shape.Oval(z) => {}
        Empty(e) => {}
        _ => {}
    }
    match w {
        B(lim + 1, _) => {}
        B(n, n) => {}
        A(P{1, 2}) => {}
        A(3) => {}
        B("s", _) => {}
        B(a, b), C => {}
        B(a, _), A(a) => {}
        C(1) => {}
        7 => {}
        _ => {}
    }
    match t {
        (a, b, c) => {}
        (1, "x") => {}
        Circle(r) => {}
        5 => {}
        _ => {}
    }
    match n {
        (a, b) => {}
        Some(x) => {}
        1 if n => {}
        k if k > 1 => {}
        _ => {}
    }
    match Red {
        Rod => {}
        _ => {}
    }
    p := P{1, 2}
    match p {
        _ => {}
    }
    ps := &s
    match ps {
        Circle(r) => {}
        _ => {}
    }
    // not exhaustive as values
    q1 := match w {
        A(_) => 1
        B(0, _) => 2
        C if n > 1 => 3
    }
    q2 := match (s, n > 1) {
        (Circle(_), true) => 1
        (Rect(_, _), _) => 2
        (Empty, _) => 3
    }
    o: Opt[Color] = None
    q3 := match o {
        Some(Red) => 1
        Some(Green) => 2
        None => 3
    }
    q4 := match n {
        0 => 1
        _ if n > 3 => 2
    }
    q5 := match n > 1 {
        true => 1
    }
    q7 := match ps {
        Circle(_) => 1
        Rect(_, 0.0) => 2
        Empty => 3
    }
    q6 := match s {
        Circle(r) if r > 1.0 => 1
        Rect(_, _) => 2
    }
}
