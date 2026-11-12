// statements whose value is unused and that have no effect
struct P { x: i64 }
fn f() -> i64 { 1 }
fn main() {
    x := 5
    t := (1, 2)
    p := P{3}
    y := x
        - 1
    !true
    ~x
    &x
    p.x
    t.0
    (x, y)
    nil
    x
    3
    x == 4
    x + f()
    f()
    t.0 == f()
    print(y)
}
