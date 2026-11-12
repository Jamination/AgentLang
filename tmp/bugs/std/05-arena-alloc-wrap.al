// Arena alloc[T](n) computed n * sizeof[T]() without an overflow check: a.alloc[i64](1 << 61)
// asks for 2^64 bytes = 0, succeeds, and returns a slice of 2^61 elements over no memory; its
// checked indexing then writes anywhere (memory-safety hole). Doc: asking for more than
// `remaining` stops the program with "arena exhausted".
// expected: panic "arena exhausted"   actual (before the fix): prints the length and writes outside
fn main() {
    a := arena_new(64)
    x := a.alloc[i64](1 << 61)
    x[100] = 7
    print("wrote outside the arena", len(x))
}
