// declarations that are written wrongly
fn f1(x: i64) -> () { }
fn f2(x i64) -> i64 { x }
fn f6(a) { }
fn f7(x: i64) -> i64
fn f8(cb: fn(i64) -> ()) { }
fn (x: i64) { }
fn 5() { }
const K: i64
const = 5
struct S1 { a i64 }
struct { a: i64 }
enum { A }
inline struct S3 { a: i64 }
noinline enum E1 { A, B }
inline type R1 = i64
noinline const C1 = 5
inline v1: i64
noinline v2 := 1
extern "libc.so.6" v3: i64
extern "libc.so.6" struct S4 { a: i64 }
extern "libc.so.6" fn c_gen[T](x: T) -> T
extern "libc.so.6" fn c_body() -> i32 { 1 }
extern fn getpid() -> i32
inline priv fn late() { }
type A1[T] = T
const C3[T] = 5
g1[T]: i64
g2 = 5
g3 i64
stray()

fn main() {
    const L1 = 5
    struct L3 { a: i64 }
    enum L4 { A }
    type L5 = i64
    fn n1(x: i64) -> () { }
    fn n2(x i64) { }
    a1 := fn(x: i64) -> () { }
    a4 := fn(i64, i64) -> bool { true }
    a5 := fn[T](x: T) -> T { x }
    t3: fn(i64) -> () = nil
    print(1)
}
