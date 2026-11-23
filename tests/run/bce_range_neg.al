// a scanner that starts below 0: the first check must fail (i < len(s) holds, i >= 0 does not)
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn scan(s: []u8, k: i64) -> i64 {
    n := len(s)
    i := k
    while i < n && s[i] != 0 {
        i += 1
    }
    return i
}

fn main() {
    s := []u8{1, 2, 0}
    print(scan(s, h(0)), scan(s, h(1)))
    print(scan(s, h(-1)))
    print("not reached")
}
