// slices of a Vec end at its length; the check also works through a pointer and in a loop
fn tail(v: *Vec[i64], from: i64) -> []i64 {
    return v[from..]
}

fn main() {
    v := vec[i64]()
    for i in 0..5 {
        v.push(i * 10)
    }
    n := len(v)
    print(v[1..3], v[..0], v[n..], tail(&v, 4))
    s := 0
    for i in 0..n {
        s += v[i]
    }
    print(s)
    k := n + 1
    print(v[2..k])
}
