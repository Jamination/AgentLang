// Decodes every PNG fixture listed in tests/std/data/img_png.txt (all colour types, bit depths,
// interlacing, filters, transparency, deflate block kinds) and prints its size and the CRC-32
// of its pixels. The expected output is written by tests/gen/images.py, which computes the
// pixels independently of this decoder.
use std.image

main :: () {
    list, ok := read_file("tests/std/data/img_png.txt")
    assert ok, "fixture list missing"
    for name in lines(list) {
        m := mark()
        img, ok := png_load(concat("tests/std/data/", name))
        if ok {
            print(name, img.w, img.h, img.channels, hex(u64(crc32(img.pix))))
        } else {
            print(name, "failed")
        }
        release(m)
    }
}
