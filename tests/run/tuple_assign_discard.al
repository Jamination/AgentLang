// `_` discards a part in a tuple assignment to existing places, as with `:=`
struct P { x: i64, y: i64 }
fn pair() -> (i64, bool) { (7, true) }
fn three() -> (i64, str, f64) { (1, "two", 3.5) }
fn main() {
    n := 0
    n, _ = pair()
    p := P{x: 0, y: 0}
    _, p.y = (100, 5)
    s := ""
    _, s, _ = three()
    v := []i64{0, 0}
    v[1], _ = pair()
    print(n, p, s, v)
}
