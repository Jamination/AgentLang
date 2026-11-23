// masked and narrow indices whose range reaches past the array by one: x & 63 into 63
// elements, a u8 into 255, x % 65 into 64: the checks stay and the last one fails
noinline fn h(x: u64) -> u64 {
    return x
}

noinline fn f(x: u64, b: u8) -> i64 {
    a: [63]i64
    t: [255]i64
    c: [64]i64
    a[x & 62] = 1
    t[b & 127] = 2
    return a[x & 63] + t[b] + c[x % 64] + c[(x >> 1) % 65]
}

fn main() {
    print(f(h(62), 254), f(h(5), 0))
    print(f(h(200), 9))
    print(f(h(63), 9))
    print("not reached")
}
