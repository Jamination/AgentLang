// core alloc[T](n) does not check n * sizeof[T]() for overflow: prints 2305843009213693952 (a slice of 2^61 i64 over no memory)
fn main() {
    x := alloc[i64](1 << 61)
    print(len(x))
}
