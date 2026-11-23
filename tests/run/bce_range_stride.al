// a loop unrolled by hand whose bound is past the length: the access of the last group that
// goes past it must fail (its checks are merged into one, so all are on one line)
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn sum4(b: []u8, n: i64) -> i64 {
    s := 0
    i := 0
    while i + 4 <= n {
        s += i64(b[i]) + i64(b[i + 1]) + i64(b[i + 2]) + i64(b[i + 3])
        i += 4
    }
    return s
}

fn main() {
    b := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    print(sum4(b, h(8)), sum4(b, h(10)), sum4(b[2..], h(8)))
    print(sum4(b, h(12)))
    print("not reached")
}
