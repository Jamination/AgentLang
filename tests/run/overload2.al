// overload resolution over all arguments, explicit type arguments, generic function values
struct A[T] { x: T }
struct W { n: i64 }
struct Rng { s: u64 }
struct Dev { a: i64 }
struct Fac { b: i64 }

fn mk[T](w: *W, n: i64) -> []T { alloc[T](n) }
fn mk[T](a: *A[i64], n: i64) -> []T { alloc[T](n + 1) }
fn range(r: *Rng, lo: i64, hi: i64) -> i64 { lo + hi }
fn range(r: *Rng, lo: f32, hi: f32) -> f32 { lo * hi }
fn make[T](self: *Dev, out: *T) -> i64 { 1 }
fn make[T](self: *Fac, out: *T) -> i64 { 2 }
fn twice[T](x: T) -> T { x + x }
fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }
fn pick(x: i64) -> str { "i64" }
fn pick(x: f64) -> str { "f64" }
fn pick(x: f32) -> str { "f32" }
fn pick(x: str) -> str { "str" }
fn pick(a: i64, b: i64) -> str { "two" }

fn main() {
    a := A[i64]{3}
    w: W
    print(len(mk[u8](&w, 3)), len(mk[u8](&a, 3)), len(w.mk[u8](3)), len(a.mk[i32](5)))
    r: Rng
    f: f32 = 0.5
    print(r.range(3, 4), r.range(f, 3.0), range(&r, 1, 2))
    d := &Dev{1}
    c := &Fac{2}
    x: i64
    print(d.make(&x), c.make(&x), make(d, &x), make(c, &x))
    print(apply(twice[i64], 4))
    g: fn(i64) -> i64 = twice
    print(g(5))
    h: f32 = 1.0
    print(pick(1), pick(1.5), pick(h), pick("s"), pick(1, 2))
}
