struct Node { left *Node, right *Node, v i64 }
fn count(t *Node) i64 {
    if t == nil { return 0 }
    1 + count(t.left) + count(t.right)
}
fn sumv(t *Node) i64 {
    if t == nil { return 0 }
    sumv(t.left) + t.v + sumv(t.right)
}
fn fact(n i64) i64 {
    if n <= 1 { return 1 }
    n * fact(n - 1)
}
fn gcd(a i64, b i64) i64 {
    if b == 0 { return a }
    gcd(b, a % b)
}
fn countdown(n i64) {
    if n == 0 { return }
    if n % 10000 == 0 { put(n, " ") }
    countdown(n - 1)
}
fn build(d i64, v i64) *Node {
    if d == 0 { return nil }
    &Node{build(d - 1, v * 2), build(d - 1, v * 2 + 1), v}
}
fn sum_to(n i64) i64 {
    if n == 0 { return 0 }
    n + sum_to(n - 1)
}
fn main() {
    t := build(10, 1)
    print(count(t), sumv(t), fact(20), gcd(1071, 462))
    countdown(30000)
    print()
    print(sum_to(50000))
}
