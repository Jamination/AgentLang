// a user struct named Vec is an ordinary struct: no indexing, slicing or iteration
struct Vec { buf []i64, len i64 }
fn main() {
    v := Vec{[]i64{1, 2}, 2}
    a := v[0]
    b := v[..1]
    for x in v { }
    c := len(v)
    d := v.buf[0] + v.len
}
