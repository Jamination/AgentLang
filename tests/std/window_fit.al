// std.window: the framebuffer fit + conversion used by `present` (needs no display; the
// same on Linux and Windows).
use std.window

fn px(v: u32) -> str { pad_left(hex(u64(v)), 6, '0') }

fn dump(dst: []u32, w: i64, h: i64) {
    for y in 0..h {
        for x in 0..w {
            put(px(dst[y * w + x]), " ")
        }
        print()
    }
}

fn main() {
    // aspect-preserving fit
    print(fit_rect(640, 480, 320, 240), fit_rect(800, 480, 320, 240), fit_rect(640, 600, 320, 240))
    print(fit_rect(100, 100, 16, 9), fit_rect(1920, 1080, 320, 180), fit_rect(3, 1000, 1000, 1), fit_rect(0, 5, 4, 4), fit_rect(5, 5, 0, 4))

    // 2x2 RGBA image: red, green / blue, white-with-alpha-0
    src := []u8{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 0}
    same := alloc[u32](4)
    blit_fit(same, 2, 2, src, 2, 2, true)
    dump(same, 2, 2)
    blit_fit(same, 2, 2, src, 2, 2, false)
    dump(same, 2, 2)
    // scaled 2x into a wider buffer that held garbage: black bars left and right
    wide := alloc[u32](6 * 4)
    fill(wide, 0xABCDEF)
    blit_fit(wide, 6, 4, src, 2, 2, true)
    dump(wide, 6, 4)
    // taller buffer: bars above and below; downscale 4x1 -> 2 wide
    row := []u8{1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0}
    tall := alloc[u32](2 * 3)
    fill(tall, 0xABCDEF)
    blit_fit(tall, 2, 3, row, 4, 1, true)
    dump(tall, 2, 3)
    // a larger gradient: checksum of the scaled result
    gw := 37
    gh := 23
    grad := alloc[u8](gw * gh * 4)
    for i in 0..gw * gh {
        grad[i * 4] = u8(i)
        grad[i * 4 + 1] = u8(i * 7)
        grad[i * 4 + 2] = u8(i * 13)
        grad[i * 4 + 3] = 255
    }
    big := alloc[u32](211 * 97)
    blit_fit(big, 211, 97, grad, gw, gh, true)
    sum: u64 = 0
    black := 0
    for i, p in big {
        sum = sum * 31 + u64(p) + u64(i)
        if p == 0 {
            black += 1
        }
    }
    print(fit_rect(211, 97, gw, gh), black, sum)
}
