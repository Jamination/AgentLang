// the bound is taken once and the Vec gets shorter in the loop: the check must still fail
noinline fn drop_last(v: *Vec[i64]) {
    v.pop()
}

fn main() {
    v := vec[i64]()
    for i in 0..6 {
        v.push(i * 10)
    }
    n := v.len
    i := 0
    while i < n && v[i] >= 0 {
        print(i, v[i])
        drop_last(&v)
        i += 1
    }
    print("not reached")
}
