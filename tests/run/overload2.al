// overload resolution over all arguments, explicit type arguments, generic function values
A[T] :: struct { x: T }
W :: struct { n: i64 }
Rng :: struct { s: u64 }
Dev :: struct { a: i64 }
Fac :: struct { b: i64 }

mk[T] :: (w: *W, n: i64) -> []T { alloc[T](n) }
mk[T] :: (a: *A[i64], n: i64) -> []T { alloc[T](n + 1) }
range :: (r: *Rng, lo: i64, hi: i64) -> i64 { lo + hi }
range :: (r: *Rng, lo: f32, hi: f32) -> f32 { lo * hi }
make[T] :: (self: *Dev, out: *T) -> i64 { 1 }
make[T] :: (self: *Fac, out: *T) -> i64 { 2 }
twice[T] :: (x: T) -> T { x + x }
apply :: (f: (i64) -> i64, x: i64) -> i64 { f(x) }
pick :: (x: i64) -> str { "i64" }
pick :: (x: f64) -> str { "f64" }
pick :: (x: f32) -> str { "f32" }
pick :: (x: str) -> str { "str" }
pick :: (a: i64, b: i64) -> str { "two" }

main :: () {
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
    g: (i64) -> i64 = twice
    print(g(5))
    h: f32 = 1.0
    print(pick(1), pick(1.5), pick(h), pick("s"), pick(1, 2))
}
