// reading past the length through a pointer to a Vec, inside a loop with a call
fn show(x: i64) {
    print(x)
}

fn dump(v: *Vec[i64], n: i64) {
    for i in 0..n {
        show(v[i])
    }
}

fn main() {
    v := vec[i64]()
    v.push(7)
    v.push(8)
    dump(&v, 3)
}
