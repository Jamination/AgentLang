// v[i] is checked against the length, not the capacity
fn main() {
    v := vec[i64]()
    for i in 0..3 {
        v.push(i)
    }
    print("capacity", len(v.buf), "length", len(v))
    i := 3
    print(v.buf[i])
    print("before")
    v[i] = 1
    print("after")
}
