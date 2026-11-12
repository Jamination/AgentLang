// `clone` of a pointer would be a copy of the pointer: an alias that looks like a copy.
struct S { v: Vec[i64], next: *S }
fn dup[T](x: T) -> T { clone(x) }
fn main() {
    v := vec[i64]()
    s := S{v: v, next: nil}
    p := &s
    a := clone(&v)
    b := clone(p)
    c := p.clone()
    d := clone(*p)              // fine: a copy of the value; d.next is still shared
    e := clone(s)
    f := dup(p)                 // fine: in a generic function a pointer is copied as it is
    g: i64 = d
}
