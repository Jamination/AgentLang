// Decodes every JPEG fixture listed in tests/std/data/jpeg.txt (baseline, extended, progressive,
// greyscale, 4:4:4 / 4:2:2 / 4:2:0 / 4:4:0 / 4:1:1, restart intervals, optimised tables,
// YCCK, a file from Windows' encoder) and compares the pixels with libjpeg-turbo's decode of the
// same file (jpeg_*.png, written by tests/gen/jpegs.py). Both use the accurate integer IDCT and
// the same upsampling and colour conversion, so the samples may differ by rounding only.
use std.image

fn main() {
    list, ok := read_file("tests/std/data/jpeg.txt")
    assert ok, "fixture list missing"
    total := 0
    for name in lines(list) {
        m := mark()
        img, good := jpeg_load(concat("tests/std/data/", name))
        ref, rok := png_load(concat("tests/std/data/", replace(name, ".jpg", ".png")))
        assert rok, name
        // image_load picks the decoder by the signature
        any, aok := image_load(concat("tests/std/data/", name))
        if !good || !aok || any.pix != img.pix {
            print(name, "failed")
            release(m)
            continue
        }
        worst := 0
        off := 0
        if img.w == ref.w && img.h == ref.h && img.channels == ref.channels {
            for i in 0..len(img.pix) {
                d := abs(i64(img.pix[i]) - i64(ref.pix[i]))
                worst = max(worst, d)
                if d != 0 {
                    off += 1
                }
            }
        } else {
            worst = 256
        }
        total += len(img.pix)
        print(name, img.w, img.h, img.channels, if worst <= 2 { "ok" } else { fmt("max difference ", worst) }, "samples off:", off)
        release(m)
    }
}
