// 3x3 box blur of a 1024x1024 u8 image (1 MiB), ping-pong between two buffers
fn blur(src: []u8, dst: []u8, w: i64, h: i64) {
    for y in 1..h - 1 {
        up := src[(y - 1) * w..y * w]
        mid := src[y * w..(y + 1) * w]
        dn := src[(y + 1) * w..(y + 2) * w]
        out := dst[y * w..(y + 1) * w]
        for x in 1..w - 1 {
            s := u32(up[x - 1]) + u32(up[x]) + u32(up[x + 1])
            s += u32(mid[x - 1]) + u32(mid[x]) + u32(mid[x + 1])
            s += u32(dn[x - 1]) + u32(dn[x]) + u32(dn[x + 1])
            out[x] = u8(s / 9)
        }
    }
}

fn main() {
    w := 1024
    h := 1024
    a := alloc[u8](w * h)
    b := alloc[u8](w * h)
    seed: u32 = 4242
    for i in 0..w * h {
        seed = seed * 1664525 + 1013904223
        a[i] = u8(seed >> 24)
        b[i] = a[i]
    }
    check: u64 = 0
    for r in 0..1000 {
        if r & 1 == 0 {
            blur(a, b, w, h)
        } else {
            blur(b, a, w, h)
        }
        // keep the image from going flat
        a[(r * 4099) & (w * h - 1)] = 255
        check = check * 1000003 + u64(a[(r * 7919) & (w * h - 1)])
    }
    for i in 0..w * h {
        check += u64(a[i])
    }
    put(check, "\n")
}
