// Private declarations follow the usual rules inside their file; messages show the written names.
priv dup :: (a: i64) {}
priv dup :: (b: i64) {}
priv g1 := 1
priv g1 := 2
priv Pair :: struct { a: i64, b: i64 }
priv i32 :: struct { x: u8 }
priv half :: (x: i64) -> i64 { x / 2 }
priv pick[T] :: (a: T, b: T) -> T { a }
priv K :: 1

main :: () {
    p := Pair{c: 1}
    p.zap
    K = 2
    q: Pair = 5
    half(1, 2)
    half("s")
    pick[Pair](p)
    p.nothing()
    r := pick
    K.half(1)
}
