// fill and copy loops over 256 KiB byte buffers (LLVM turns these into memset / memcpy)
fn fill_bytes(a: []u8, v: u8) {
    for i in 0..len(a) {
        a[i] = v
    }
}

fn copy_bytes(dst: []u8, src: []u8) {
    for i in 0..len(src) {
        dst[i] = src[i]
    }
}

fn main() {
    n := 1 << 18
    mask := n - 1
    a := alloc[u8](n)
    b := alloc[u8](n)
    check: u64 = 0
    for r in 0..40000 {
        fill_bytes(a, u8(r))
        a[(r * 7919) & mask] = 7
        copy_bytes(b, a)
        check = check * 31 + u64(b[(r * 4099) & mask]) + u64(b[(r * 7919) & mask])
    }
    put(check, "\n")
}
