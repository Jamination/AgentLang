fn main() {
    a := []i64{1, 2, 3, 4}
    n := len(a)
    print(a[1..3], a[..0], a[n..])
    k := n + 1
    print(a[2..k])
}
