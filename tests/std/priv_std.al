// The internal helpers of std/rand.al and std/image.al are `priv`: a program may use their
// names for its own declarations, and the library keeps working.
use std.image

struct Inflate { level: i64 }
struct Png { name: str }
const MAX_DIM = 7
default_rng := 123
crc_tab := [2]i64{5, 6}

fn splitmix(x: i64) -> i64 { x + 1 }
fn fade(t: f32) -> f32 { t * 2.0 }
fn rgba(r: i64, g: i64, b: i64, a: i64) -> i64 { r << 24 | g << 16 | b << 8 | a }
fn luma(img: Image, i: i64) -> i64 { -1 }
fn be32(d: []u8, i: i64) -> i64 { -2 }
fn take_bits(x: i64, n: i64) -> i64 { x & ((1 << n) - 1) }
fn paeth(a: i64, b: i64, c: i64) -> i64 { 0 }

fn main() {
    print(Inflate{3}, Png{"p"}, MAX_DIM, default_rng, crc_tab[1])
    print(splitmix(1), fade(0.25), rgba(1, 2, 3, 4), take_bits(0xFF, 3), paeth(1, 2, 3))

    // the library's own helpers of the same names are untouched
    r := rng(42)
    print(r.next_u64(), rand_u64(), noise2(0.3, 0.7) == noise2(0.3, 0.7, 0), noise2(1.0, 2.0))
    img := image_new(9, 5, 4)
    for y in 0..img.h {
        for x in 0..img.w {
            img.set(x, y, 0, u8(x * 28))
            img.set(x, y, 1, u8(y * 60))
            img.set(x, y, 2, u8(x * y))
            img.set(x, y, 3, 255)
        }
    }
    png := png_encode(img)
    back, ok := png_decode(png)
    print(ok, back.w, back.h, back.channels, back.pix == img.pix, luma(img, 0), be32(png, 0))
    grey := convert(img, 1)
    print(grey.channels, grey.get(8, 4, 0), crc32(img.pix) == crc32(back.pix))
    packed := zlib_compress(img.pix)
    plain, ok2 := zlib_decompress(packed)
    print(ok2, plain == img.pix)
}
