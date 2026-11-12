// zext(narrow index) that wraps around inside a long enough sequence: every access is in
// bounds, so no panic (bce's first/last/order checks used to reject the wrap)
noinline fn h(x: i64) -> i64 { return x }
fn main() {
    a := vec_fill(h(256), 1)
    s := 0
    for i in i8(h(-5))..i8(h(5)) {
        s += a[u8(i)]
    }
    print(s)
    b: [256]i64
    for i in u8(h(240))..u8(h(255)) {
        s += b[i + u8(10)] + 1
    }
    print(s)
    c: [200]i64
    for i in u8(h(100))..u8(h(150)) {
        s += c[i + u8(10)] + 1
    }
    print(s)
}
