// Private declarations follow the usual rules inside their file; messages show the written names.
priv fn dup(a: i64) {}
priv fn dup(b: i64) {}
priv g1 := 1
priv g1 := 2
priv struct Pair { a: i64, b: i64 }
priv struct i32 { x: u8 }
priv fn half(x: i64) -> i64 { x / 2 }
priv fn pick[T](a: T, b: T) -> T { a }
priv const K = 1

fn main() {
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
