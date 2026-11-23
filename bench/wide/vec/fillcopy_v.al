// fillcopy.al with the library's fill / copy instead of hand-written loops
fn main() {
    n := 1 << 18
    mask := n - 1
    a := alloc[u8](n)
    b := alloc[u8](n)
    check: u64 = 0
    for r in 0..40000 {
        fill(a, u8(r))
        a[(r * 7919) & mask] = 7
        copy(b, a)
        check = check * 31 + u64(b[(r * 4099) & mask]) + u64(b[(r * 7919) & mask])
    }
    put(check, "\n")
}
