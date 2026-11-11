// a user struct named Vec is an ordinary struct: no indexing, slicing or iteration
Vec :: struct { buf: []i64, len: i64 }
main :: () {
    v := Vec{[]i64{1, 2}, 2}
    a := v[0]
    b := v[..1]
    for x in v { }
    c := len(v)
    d := v.buf[0] + v.len
}
