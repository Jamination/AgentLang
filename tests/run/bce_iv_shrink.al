// the Vec gets shorter while the loop runs: the index check must still fail
fn drop_last(v: *Vec[i64]) -> i64 {
    return v.pop()
}

fn main() {
    v := vec[i64]()
    for i in 0..6 {
        v.push(i)
    }
    for i in 0..v.len {
        drop_last(&v)
        print(i, v[i])
    }
    print("not reached")
}
