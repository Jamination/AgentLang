// Draws a picture, saves it as PNG and BMP, loads it back and makes a thumbnail.
use std.image

main :: () {
    img := image_new(256, 128, 4)
    for y in 0..img.h {
        for x in 0..img.w {
            u := f32(x) / f32(img.w - 1)
            v := f32(y) / f32(img.h - 1)
            rgb := hsv_to_rgb(vec3(u, 1.0 - v * 0.5, 1.0))
            img.set(x, y, vec4(rgb, 1.0))
        }
    }
    if !png_save("tmp/rainbow.png", img) || !bmp_save("tmp/rainbow.bmp", img) {
        print("cannot write to tmp/")
        return
    }
    back, ok := image_load("tmp/rainbow.png")
    print("loaded:", ok, back.w, back.h, back.channels, "identical:", ok && back.pix == img.pix)
    size, _ := read_file("tmp/rainbow.png")
    print("png is smaller than the raw pixels:", len(size) < len(img.pix))
    thumb := resize_bilinear(back, 64, 32)
    grey := convert(thumb, 1)
    print("thumbnail:", thumb.w, thumb.h, "grey channels:", grey.channels)
    print("crc32 of the pixels:", hex(u64(crc32(img.pix))))
}
