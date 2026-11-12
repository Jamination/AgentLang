// std.mem: an Arena allocation whose byte size wraps around (n * sizeof[T]() or the rounding
// to 16) is "arena exhausted", not a slice of 2^61 elements over 0 bytes of the arena
fn main() {
    a := arena_new(64)
    b := a.alloc[u8](64)
    a.reset()
    print(len(b), a.remaining())
    x := a.alloc[i64](1 << 61)
    print("unreachable", len(x))
}
