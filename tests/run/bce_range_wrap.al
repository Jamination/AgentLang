// `i + 4 <= n` wraps around for i near the largest i64: the loop runs and its first access is
// out of bounds (and so is every other: one line)
noinline fn h(x: i64) -> i64 {
    return x
}

noinline fn sum4(b: []u8, k: i64) -> i64 {
    s := 0
    n := len(b)
    i := k
    while i + 4 <= n {
        s += i64(b[i]) + i64(b[i + 1]) + i64(b[i + 2]) + i64(b[i + 3])
        i += 4
    }
    return s
}

fn main() {
    b := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9}
    print(sum4(b, h(0)), sum4(b, h(5)), sum4(b, h(6)))
    print(sum4(b, h(0x7FFF_FFFF_FFFF_FFFE)))
    print("not reached")
}
