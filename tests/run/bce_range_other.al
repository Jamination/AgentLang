// the loop is bounded by the length of one slice and indexes another, shorter one (the two
// may share memory): the check of the shorter one must still fail
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn copy(a: []i64, b: []i64) -> i64 {
    n := len(a)
    i := 0
    s := 0
    while i < n && a[i] >= 0 {
        s += b[i]
        i += 1
    }
    return s
}

fn main() {
    a := []i64{1, 2, 3, 4, 5}
    print(copy(a[..3], a[1..]), copy(a, a))
    print(copy(a, a[..h(4)]))
    print("not reached")
}
