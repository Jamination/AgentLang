// Decodes every BMP fixture listed in tests/std/data/img_bmp.txt (24/32-bit, bit fields, palettes,
// all header versions, both row orders) and prints its size and the CRC-32 of its pixels. The
// expected output is written by tests/gen/images.py from its own model of the images.
use std.image

fn main() {
    list, ok := read_file("tests/std/data/img_bmp.txt")
    assert ok, "fixture list missing"
    for name in lines(list) {
        m := mark()
        img, ok := image_load(concat("tests/std/data/", name))
        if ok {
            print(name, img.w, img.h, img.channels, hex(u64(crc32(img.pix))))
        } else {
            print(name, "failed")
        }
        release(m)
    }
}
