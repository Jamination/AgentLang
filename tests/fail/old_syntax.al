// the declaration syntax of earlier versions: each form is an error that says how it is
// written now

// `name :: ...` declarations
N :: 5
LIMIT : i64 : 100
TABLE :: [4]i64{1, 2, 4, 8}
GROUPED :: (N + 1) * 2
Item :: struct { name: str, hp: i64 }
Stack[T] :: struct {
    buf: []T
    top: i64
}
Shape :: enum { Circle(f64), Rect(f64, f64) }
Maybe[T] :: enum { Just(T), Nothing }
Reg :: type i64
Cb :: type (i64) -> bool
area :: (s: Shape) -> f64 { 1.0 }
apply[T, U] :: (x: T, f: (T) -> U) -> U { f(x) }
nothing :: () { }
priv inline helper :: () -> i64 { 1 }
extern "libc.so.6" getpid :: () -> i32
hook: (i64) -> () = nil
hooks: [2](i64, i64) -> bool

// `var`, types without `:`, results without `->`
var counter i64
var ratio f64 = 0.5
var table = [2]i64{1, 2}
const MASK u32 = 0xFF00
fn old_area(s Shape) f64 { 1.0 }
fn old_result(s: Shape) f64 { 1.0 }
fn old_type(f: fn(i64) i64) { }
struct Old { a i64, b i64 }

fn main() {
    var x i64 = 5
    let y = 6
    keep :: (it: Item, n: *i64) -> bool { it.hp > 1 }
    K :: 3
    h := (v: i64) -> i64 { v * v }
    k := () -> i64 { 42 }
    w := () { }
    fs := [](i64) -> i64{h}
    vs := vec[(i64) -> ()]()
    c := cast[(i64) -> i64](nil)
    g: (i64) -> i64 = h
    o := fn(v: i64) i64 { v }
    print(x, y)
}
func other() { }
