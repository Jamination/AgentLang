// failures inside library functions: the library's own frames before the program's are left
// out (the trace starts at the call, the line the message names); between frames of the
// program they are shown (sort_by calling the comparison)
fn take(v: *Vec[i64]) -> i64 {
    return v.pop()
}

fn by_size(a: i64, b: i64) -> bool {
    assert a != b, "equal elements"
    return a < b
}

fn main() {
    o: Opt[i64] = Some(3)
    v := vec_of([]i64{1})
    print(o.unwrap(), take(&v))
    xs := []i64{3, 1, 2}
    sort_by(xs, by_size)
    print(xs)
    ys := []i64{3, 1, 3}
    if len(args()) == 3 {
        sort_by(ys, by_size)
    }
    print(take(&v))
}
