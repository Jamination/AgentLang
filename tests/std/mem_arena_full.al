// std.mem: running out of arena space is a panic (also in --unchecked builds)
main :: () {
    a := arena_new(64)
    x := a.alloc[u64](8)
    print(len(x), a.remaining())
    a.alloc[u8](1)
    print("unreachable")
}
