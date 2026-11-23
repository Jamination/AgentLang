// a scanner whose bound is one past the length: the check of s[n - 1 + 1] must still fail
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn scan(s: []u8, n: i64) -> i64 {
    i := 0
    while i < n && s[i] != 0 {
        i += 1
    }
    return i
}

fn main() {
    s := []u8{1, 2, 3}
    print(scan(s, h(3)), scan(s[..2], h(2)))
    print(scan(s, h(4)))
    print("not reached")
}
