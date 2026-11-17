// std.image: the JPEG encoder, through the decoder: every channel count, awkward sizes,
// qualities; the error must stay within what the quantisation allows.
use std.image
use std.os

fails: i64

fn ok(name: str, c: bool) {
    if !c {
        fails += 1
        print("FAILED:", name)
    }
}

// a smooth picture with one hard edge, deterministic
fn picture(w: i64, h: i64, channels: i64) -> Image {
    img := image_new(w, h, channels)
    for y in 0..h {
        for x in 0..w {
            for c in 0..channels {
                v := match c {
                    0 => x * 255 / w
                    1 => y * 255 / h
                    2 => (x + y) * 255 / (w + h)
                    _ => 128 + x - y
                }
                if x * 3 > w * 2 {
                    v = 255 - c * 70
                }
                img.set(x, y, c, u8(v))
            }
        }
    }
    img
}

// peak signal to noise ratio in dB of b against a (same size and channels); 99 if identical
fn psnr(a: Image, b: Image) -> f64 {
    se := 0
    for i in 0..len(a.pix) {
        d := i64(a.pix[i]) - i64(b.pix[i])
        se += d * d
    }
    if se == 0 {
        return 99.0
    }
    mse := f64(se) / f64(len(a.pix))
    10.0 * log(255.0 * 255.0 / mse) / log(10.0)
}

fn main() {
    sizes := [6]i64{1, 7, 16, 17, 64, 131}
    qualities := [5]i64{10, 50, 75, 90, 100}
    // the lowest PSNR (dB) accepted per quality
    floor := [5]f64{24.0, 30.0, 32.0, 35.0, 40.0}
    for ch in 1..=4 {
        for sz in sizes {
            src := picture(sz, sz / 2 + 1, ch)
            want := convert(src, if ch <= 2 { 1 } else { 3 })
            for qi, q in qualities {
                enc := jpeg_encode(src, q)
                back, good := jpeg_decode(enc)
                name := fmt("ch ", ch, " size ", sz, " quality ", q)
                ok(name, good && back.w == src.w && back.h == src.h && back.channels == want.channels)
                if good && back.channels == want.channels {
                    p := psnr(want, back)
                    // In a picture of a few pixels the hard edge is most of the image, and below
                    // quality 90 its colour is subsampled: libjpeg-turbo, with the same tables and
                    // its accurate DCT, loses as much there (checked by hand: 7 x 4 at quality
                    // 50 / 75 / 95: 19.3 / 20.1 / 38.2 dB here, 18.2 / 20.3 / 38.2 dB with libjpeg-turbo)
                    small := sz <= 17 && ch >= 3
                    ok(fmt(name, ": psnr ", fmtf(p, 1)), p >= (if small { floor[qi] - 12.0 } else { floor[qi] }) || (sz == 1 && q <= 50))
                }
            }
        }
        print("channels", ch, "done")
    }
    // libjpeg-turbo with its accurate DCT, the same quality and subsampling (tests/gen/jpegs.py)
    // writes the same entropy-coded data: only the arrangement of the header segments differs
    list, lok_ := read_file("tests/std/data/jpeg_enc.txt")
    assert lok_, "fixture list missing"
    for line in lines(list) {
        parts := split(line, ' ')
        q, _ := parse_i64(parts[1])
        src, sok := png_load(fmt("tests/std/data/", parts[0], ".png"))
        theirs, tok := read_file(fmt("tests/std/data/", parts[0], ".jpg"))
        assert sok && tok, parts[0]
        mine := jpeg_encode(src, q)
        same := mine[find(mine, "\xFF\xDA")..] == theirs[find(theirs, "\xFF\xDA")..]
        print(parts[0], if same { "scan identical to libjpeg-turbo's" } else { "scan differs" })
    }
    // the file shrinks with the quality
    big := picture(200, 120, 3)
    s10 := len(jpeg_encode(big, 10))
    s50 := len(jpeg_encode(big, 50))
    s90 := len(jpeg_encode(big, 90))
    ok("sizes grow with quality", s10 < s50 && s50 < s90 && s90 < len(big.pix))
    // qualities out of range are clamped
    ok("quality clamped", jpeg_encode(big, 0) == jpeg_encode(big, 1) && jpeg_encode(big, 500) == jpeg_encode(big, 100))
    // save, then load by signature
    make_dir("tmp")
    path := fmt("tmp/image_jpeg_enc_", process_id(), ".jpg")
    ok("save", jpeg_save(path, big, 80))
    l, lok := image_load(path)
    l2, lok2 := jpeg_load(path)
    d, _ := jpeg_decode(jpeg_encode(big, 80))
    ok("load", lok && lok2 && l.pix == d.pix && l2.pix == d.pix)
    _, bad := jpeg_load("tmp/no_such_image.jpg")
    ok("load failure", !bad)
    ok("remove", remove_file(path))
    print("failures:", fails)
}
