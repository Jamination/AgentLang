// every form of the declaration syntax of earlier versions: one error each, with the new spelling
struct Item { name str, hp i64 }
struct Stack[T] {
    buf []T
    top i64
}
enum Shape { Circle(f64), Rect(f64, f64) }
enum Maybe[T] { Just(T), Nothing }
type Reg = i64
type Cb = fn(i64) bool
const N = 5
const LIMIT i64 = 100
var counter i64
var ratio f64 = 0.5
var table = [2]i64{1, 2}
fn area(s Shape) f64 { 1.0 }
fn apply[T, U](x T, f fn(T) U) U { f(x) }
priv inline fn helper() { }
extern "libc.so.6" fn getpid() i32
fn pair(x i64) (i64, bool) { (x, true) }

New :: struct { a: i64, b i64 }
newer :: (x: i64, y i64) -> i64 { x }
arrowless :: (x: i64) i64 { x }
cb: fn(i64)
cb2: fn(i64, i64) bool = nil
cb3: (i64) bool = nil

main :: () {
    var x i64 = 5
    var y i64
    var z = 7
    const K = 3
    fn keep(it Item, n *i64) bool { it.hp > 1 }
    h := fn(v i64) i64 { v * v }
    k := fn() { }
    fs := []fn(i64) i64{h}
    vs := vec[fn(i64)]()
    w := (a i64) -> i64 { a }
    struct Local { a: i64 }
    let q = 5
    print(x, y, z)
}
func other() { }
