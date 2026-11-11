fn check(x: i64) -> i64 {
    if x > 2 {
        panic("too big")
    }
    x
}
fn main() -> i64 {
    print(check(1))
    print(check(3))
    return 0
}
