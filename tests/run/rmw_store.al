// Read-modify-write stores (x86 isel: `a[i] op= x` as one `op [mem], x` instruction): every
// width and operation, the loaded value also used elsewhere, a store between the load and the
// store, and two updates of what may be the same element.
noinline fn hist8(b: []u8, h: []u8) {
    for x in b {
        h[x & 15] += 3
    }
}

noinline fn hist16(b: []u8, h: []u16, d: u16) {
    for x in b {
        h[x & 15] += d
        h[(x >> 4) & 15] -= 1
    }
}

noinline fn ops32(h: []u32, i: i64, x: u32) {
    h[i] += x
    h[i + 1] -= x
    h[i + 2] &= x
    h[i + 3] |= x
    h[i + 4] ^= x
    h[i + 5] = x - h[i + 5]
}

noinline fn ops64(h: []i64, i: i64, x: i64) -> i64 {
    h[i] += 0x7FFFFFFF
    h[i + 1] -= -5
    h[i + 2] ^= x
    // the loaded value is used again: no fusion
    old := h[i + 3]
    h[i + 3] = old + x
    return old
}

g_slot: i32

noinline fn global_rmw(n: i64) {
    for i in 0..n {
        g_slot += i32(i)
        if g_slot > 1000 {
            g_slot &= 0xFF
        }
    }
}

noinline fn between(h: []i32, o: []i32, i: i64) {
    // a store between the load and the store
    t := h[i]
    o[0] = 7
    h[i] = t + 1
}

noinline fn same_elem(h: []i64, i: i64, j: i64) {
    h[i] += h[j]
    h[j] += h[i]
}

fn main() {
    b := alloc[u8](1000)
    for i in 0..len(b) {
        b[i] = u8(i * 31 + i / 3)
    }
    h8 := alloc[u8](16)
    hist8(b, h8)
    w8 := alloc[u32](16)
    for i in 0..16 {
        w8[i] = u32(h8[i])
    }
    print("hist8", w8[..])
    h16 := alloc[u16](16)
    hist16(b, h16, 7)
    print("hist16", h16[..])
    h32 := alloc[u32](8)
    for i in 0..8 {
        h32[i] = u32(i * 0x01010101 + 0x0F0F)
    }
    ops32(h32, 1, 0xF0F0F0F0)
    print("ops32", h32[..])
    h64 := alloc[i64](8)
    for i in 0..8 {
        h64[i] = i * 1000000007
    }
    print("ops64", ops64(h64, 2, 0x5555), h64[..])
    global_rmw(100)
    print("global", g_slot)
    hi := alloc[i32](4)
    between(hi, hi, 0)
    print("between", hi[..])
    between(hi, hi[1..], 0)
    print("between", hi[..])
    h := alloc[i64](4)
    h[0] = 3
    h[1] = 5
    same_elem(h, 0, 1)
    same_elem(h, 2, 2)
    h[3] = 11
    same_elem(h, 3, 3)
    print("same", h[..])
}
