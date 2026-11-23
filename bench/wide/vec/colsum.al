// column sums of a 512x512 u8 image into u32 accumulators (u8 -> u32 widening, row-wise inner loop)
fn colsum(img: []u8, w: i64, h: i64, acc: []u32) {
    for x in 0..w {
        acc[x] = 0
    }
    for y in 0..h {
        row := img[y * w..(y + 1) * w]
        for x in 0..w {
            acc[x] += u32(row[x])
        }
    }
}

fn main() {
    w := 512
    h := 512
    img := alloc[u8](w * h)
    acc := alloc[u32](w)
    seed: u32 = 555
    for i in 0..w * h {
        seed = seed * 1664525 + 1013904223
        img[i] = u8(seed >> 24)
    }
    check: u64 = 0
    for r in 0..18000 {
        colsum(img, w, h, acc)
        for x in 0..w {
            check = check * 31 + u64(acc[x])
        }
        img[(r * 7919) & (w * h - 1)] += 3
    }
    put(check, "\n")
}
