deep :: (n: i64) -> i64 {
    if n == 0 {
        return 0
    }
    1 + deep(n - 1) * 2
}
main :: () {
    print(deep(20))
    print(deep(100000000))
}
