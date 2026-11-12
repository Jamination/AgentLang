use std.image
fn main() {
    a := args()
    for i in 1..len(a) {
        put(a[i], " ")
        flush()
        data, ok0 := read_file(a[i])
        img, ok := image_decode(data)
        if ok {
            assert len(img.pix) == img.w * img.h * img.channels, "pix len"
            print("ok", img.w, img.h, img.channels, hex(u64(crc32(img.pix))))
        } else {
            print("bad")
        }
    }
}
