// std.image: encoders (round trips through the decoders), compression, pixel operations
use std.image

fails: i64

ok :: (name: str, c: bool) {
    if !c {
        fails += 1
        print("FAILED:", name)
    }
}

// a picture with smooth and noisy parts, deterministic
picture :: (w: i64, h: i64, channels: i64) -> Image {
    img := image_new(w, h, channels)
    r := rng(99)
    for y in 0..h {
        for x in 0..w {
            for c in 0..channels {
                v := (x * 3 + y * 5 + c * 40) & 255
                if x > w / 2 && y > h / 2 {
                    v = r.range(0, 256)
                }
                img.set(x, y, c, u8(v))
            }
        }
    }
    return img
}

same :: (a: Image, b: Image) -> bool {
    return a.w == b.w && a.h == b.h && a.channels == b.channels && a.pix == b.pix
}

main :: () {
    // PNG round trip for every channel count and awkward sizes
    sizes := [4]i64{1, 7, 64, 131}
    for ch in 1..=4 {
        for sz in sizes {
            img := picture(sz, sz / 2 + 1, ch)
            back, good := png_decode(png_encode(img))
            ok(fmt("png round trip ", ch, " ", sz), good && same(img, back))
        }
    }
    // BMP stores 3 or 4 channels
    for ch in 3..=4 {
        img := picture(37, 21, ch)
        back, good := bmp_decode(bmp_encode(img))
        ok(fmt("bmp round trip ", ch), good && same(img, back))
    }
    grey := picture(9, 5, 1)
    gb, good := bmp_decode(bmp_encode(grey))
    ok("bmp grey becomes rgb", good && gb.channels == 3 && gb.get(3, 2, 0) == grey.get(3, 2, 0) && gb.get(3, 2, 2) == grey.get(3, 2, 0))

    // compression: a smooth gradient shrinks a lot, noise does not explode
    grad := image_new(256, 256, 4)
    for y in 0..256 {
        for x in 0..256 {
            grad.set(x, y, vec4(f32(x) / 255.0, f32(y) / 255.0, 0.5, 1.0))
        }
    }
    enc := png_encode(grad)
    ok("gradient compresses", len(enc) * 20 < len(grad.pix))
    gback, ggood := png_decode(enc)
    ok("gradient round trip", ggood && same(grad, gback))
    noise := alloc[u8](50000)
    r := rng(5)
    for i in 0..len(noise) {
        noise[i] = u8(r.range(0, 256))
    }
    z := zlib_compress(noise)
    back, zgood := zlib_decompress(z)
    ok("zlib noise", zgood && back == noise && len(z) < len(noise) + len(noise) / 100 + 64)
    text := alloc[u8](40000)
    for i in 0..len(text) {
        text[i] = "the quick brown fox "[i % 20]
    }
    zt := zlib_compress(text)
    tback, tgood := zlib_decompress(zt)
    ok("zlib text", tgood && tback == text && len(zt) < 400)
    raw, rgood := inflate(deflate(text[..1000]))
    ok("raw deflate", rgood && raw == text[..1000])
    empty, egood := zlib_decompress(zlib_compress(text[..0]))
    ok("zlib empty", egood && len(empty) == 0)
    ok("checksums", crc32("123456789") == 0xCBF43926 && adler32("Wikipedia") == 0x11E60398 && crc32(crc32("1234"), "56789") == 0xCBF43926 && adler32(adler32("Wiki"), "pedia") == 0x11E60398)

    // files
    dir := "tmp"
    syscall(83, cstr(dir), 0o755)
    p := fmt(dir, "/image_ops_", syscall(39), ".png")
    b := fmt(dir, "/image_ops_", syscall(39), ".bmp")
    pic := picture(40, 30, 4)
    ok("save", png_save(p, pic) && bmp_save(b, pic))
    l1, g1 := image_load(p)
    l2, g2 := image_load(b)
    l3, g3 := png_load(p)
    l4, g4 := bmp_load(b)
    ok("load", g1 && g2 && g3 && g4 && same(l1, pic) && same(l2, pic) && same(l3, pic) && same(l4, pic))
    m1, bad1 := png_load(b)
    m2, bad2 := image_load("tmp/no_such_image.png")
    ok("load failures", !bad1 && !bad2)
    syscall(87, cstr(p))
    syscall(87, cstr(b))

    // pixel access and conversion
    img := image_new(4, 3, 4)
    img.set(1, 2, vec4(1.0, 0.5, 0.0, 1.0))
    ok("get set", img.get(1, 2, 0) == 255 && img.get(1, 2, 1) == 128 && img.get(1, 2, 3) == 255 && approx_eq(img.get(1, 2), vec4(1.0, 0.5019608, 0.0, 1.0)) && img.get(0, 0) == vec4(0.0))
    rgb := convert(img, 3)
    g1c := convert(img, 1)
    ga := convert(img, 2)
    again := convert(rgb, 4)
    ok("convert", rgb.channels == 3 && rgb.get(1, 2, 1) == 128 && len(rgb.pix) == 36 && g1c.channels == 1 && g1c.get(1, 2, 0) == 151 && ga.get(1, 2, 1) == 255 && again.get(1, 2, 3) == 255 && again.get(0, 0, 3) == 255)
    // flip, crop, blit
    pic2 := picture(6, 4, 3)
    fl := crop(pic2, 0, 0, 6, 4)
    fl.flip_y()
    ok("flip_y", fl.get(2, 0, 1) == pic2.get(2, 3, 1) && fl.get(5, 3, 2) == pic2.get(5, 0, 2) && !same(fl, pic2))
    fl.flip_y()
    ok("flip twice", same(fl, pic2))
    cr := crop(pic2, 2, 1, 3, 2)
    ok("crop", cr.w == 3 && cr.h == 2 && cr.get(0, 0, 0) == pic2.get(2, 1, 0) && cr.get(2, 1, 2) == pic2.get(4, 2, 2))
    canvas := image_new(8, 8, 3)
    canvas.blit(cr, 6, 7)
    canvas.blit(cr, -1, -1)
    ok("blit clips", canvas.get(6, 7, 0) == cr.get(0, 0, 0) && canvas.get(7, 7, 1) == cr.get(1, 0, 1) && canvas.get(0, 0, 2) == cr.get(1, 1, 2) && canvas.get(3, 3, 0) == 0)
    // resizing
    chk := image_new(2, 2, 1)
    chk.set(0, 0, 0, 0)
    chk.set(1, 0, 0, 100)
    chk.set(0, 1, 0, 200)
    chk.set(1, 1, 0, 60)
    big := resize_nearest(chk, 4, 4)
    ok("resize_nearest", big.w == 4 && big.get(0, 0, 0) == 0 && big.get(1, 1, 0) == 0 && big.get(2, 0, 0) == 100 && big.get(1, 3, 0) == 200 && big.get(3, 3, 0) == 60)
    ok("resize identity", same(resize_nearest(pic2, 6, 4), pic2) && same(resize_bilinear(pic2, 6, 4), pic2))
    flat := image_new(5, 5, 3)
    fill(flat.pix, 77)
    sm := resize_bilinear(flat, 13, 3)
    allsame := sm.w == 13 && sm.h == 3
    for v in sm.pix {
        allsame = allsame && v == 77
    }
    ok("resize_bilinear flat", allsame)
    bl := resize_bilinear(chk, 1, 1)
    ok("resize_bilinear average", bl.get(0, 0, 0) == 90)
    // mipmaps: box filter
    mip := generate_mipmap(chk)
    ok("mipmap", mip.w == 1 && mip.h == 1 && mip.get(0, 0, 0) == 90)
    chain := mipmap_chain(picture(20, 12, 4))
    ok("mipmap chain", len(chain) == 5 && chain[0].w == 20 && chain[1].w == 10 && chain[1].h == 6 && chain[2].w == 5 && chain[2].h == 3 && chain[3].w == 2 && chain[3].h == 1 && chain[4].w == 1 && chain[4].h == 1)
    // premultiplied alpha
    pm := image_new(1, 2, 4)
    pm.set(0, 0, vec4(1.0, 0.5, 0.25, 0.5))
    pm.set(0, 1, vec4(1.0, 1.0, 1.0, 0.0))
    pm.premultiply_alpha()
    ok("premultiply", pm.get(0, 0, 0) == 128 && pm.get(0, 0, 1) == 64 && pm.get(0, 0, 3) == 128 && pm.get(0, 1, 0) == 0 && pm.get(0, 1, 3) == 0)
    print("image_ops failures:", fails)
}
