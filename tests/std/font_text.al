// std.font: UTF-8 decoding, layout, measuring, line breaking, atlases and drawing into images,
// on tests/std/data/font_test.ttf. At 1000 px the scale is 1: pixels are font units.
use std.font

fn show(ps: []GlyphPos) -> str {
    parts := vec[str]()
    for p in ps {
        parts.push(fmt(p.cp, "@", p.x, ",", p.y, "#", p.byte, "/", p.line))
    }
    join(parts.items(), " ")
}

fn darkness(img: Image) -> i64 {
    total := 0
    for v in img.pix {
        total += 255 - i64(v)
    }
    total
}

fn main() {
    f, err := font_load("tests/std/data/font_test.ttf")
    assert err == "", err
    // UTF-8
    cps := vec[i64]()
    s := "A\xC3\x84\xC7\x9E\xF0\x9F\x98\x80\xFF\xC3\xE0\x80\x80\xED\xA0\x80\xF4\x90\x80\x80Z\xC3"
    i := 0
    while i < len(s) {
        cp, next := utf8_next(s, i)
        cps.push(cp)
        i = next
    }
    print("utf8:", cps[..])
    // layout and measuring (kerning: A V -80, V A -70)
    print("layout:", show(layout_text(f, 1000.0, "AVA\nH\r\nW o")))
    print("line_width AVA:", line_width(f, 1000.0, "AVA"), "AVA at 10 px:", line_width(f, 10.0, "AVA"))
    print("line_width up to the newline:", line_width(f, 1000.0, "AH\nWWWW"), "empty:", line_width(f, 1000.0, ""))
    w, h := text_size(f, 1000.0, "AH\nWWW\n")
    print("text_size:", w, h)
    print("emoji (format 12) and a missing character:", line_width(f, 1000.0, "\xF0\x9F\x98\x80B"))
    // wrapping: "AH AH AH" is 520 + 600 + 250 + 520 + 600 + 250 + 520 + 600
    for mw in []f32{0.0, 5000.0, 3000.0, 2500.0, 2000.0, 1200.0, 1000.0, 500.0} {
        print("wrap", mw, ":", wrap_text(f, 1000.0, "AH AH AH", mw))
    }
    print("wrap long word:", wrap_text(f, 1000.0, "HHHHH AH", 1300.0))
    print("wrap spaces and lines:", wrap_text(f, 1000.0, "  AH   AH  \n\nH", 1500.0))
    // the lines fit
    long := "VA WA HA oo AVAV WWW o H A V W AH AH oH Ho VVVV A"
    fits := true
    for mw in []f32{700.0, 1000.0, 1700.0, 2400.0, 5000.0} {
        for l in wrap_text(f, 1000.0, long, mw) {
            if line_width(f, 1000.0, l) > mw && len(fields(l)) > 1 {
                fits = false
            }
        }
    }
    print("wrapped lines fit:", fits)
    // an atlas, 1 and 4 channels
    chars := vec_of(char_range(32, 126))
    chars.extend([]i64{0xA8, 0xC4, 0x1DE, 0x1F600, 'A'})
    for ch in []i64{1, 4} {
        a, aerr := atlas_build(f, 40.0, chars.items(), 128, ch)
        print("atlas", ch, "channels:", aerr == "", a.img.w, "x", a.img.h, "glyphs", a.glyphs.len, "missing", a.missing.w, a.missing.h)
        // every rectangle inside the image, none overlapping, pixels equal to the glyph's bitmap
        rects := vec[AtlasGlyph]()
        rects.push(a.missing)
        for c in a.glyphs.keys() {
            rects.push(atlas_glyph(a, c))
        }
        ok := true
        for k in 0..rects.len {
            r := rects[k]
            if r.x < 0 || r.y < 0 || r.x + r.w > a.img.w || r.y + r.h > a.img.h {
                ok = false
            }
            for j in 0..k {
                q := rects[j]
                if r.w > 0 && q.w > 0 && r.x < q.x + q.w && q.x < r.x + r.w && r.y < q.y + q.h && q.y < r.y + r.h {
                    ok = false
                }
            }
            b := glyph_bitmap(f, r.glyph, a.scale)
            if b.img.w != r.w || b.img.h != r.h || b.x != r.xoff || b.y != r.yoff {
                ok = false
            }
            for y in 0..r.h {
                for x in 0..r.w {
                    if a.img.pix[((r.y + y) * a.img.w + r.x + x) * ch + ch - 1] != b.img.pix[y * r.w + x] {
                        ok = false
                    }
                }
            }
        }
        print("  rectangles inside, apart, equal to the bitmaps:", ok)
        g := atlas_glyph(a, 'H')
        print("  H:", g.glyph, g.w, g.h, g.xoff, g.yoff, g.advance, "uv", g.u1 - g.u0 == f32(g.w) / f32(a.img.w), "missing:", atlas_glyph(a, 'B').glyph)
    }
    _, e1 := atlas_build(f, 40.0, chars.items(), 20, 1)
    _, e2 := atlas_build(f, 40.0, chars.items(), 128, 3)
    print("atlas errors:", e1, "|", e2)
    // drawing: black text on white, by the font and by an atlas; the darkness is the glyph area
    img := image_new(200, 60, 3)
    fill(img.pix, u8(255))
    draw_text(&img, f, 50.0, 4.0, 2.0, "AHo", vec4(0.0, 0.0, 0.0, 1.0))
    expect: f64 = (147000.0 + 170000.0 + 133333.3) * 0.0025 * 3.0
    d1 := darkness(img)
    print("draw_text darkness close to the area:", fabs(f64(d1) / 255.0 - expect) < expect * 0.01)
    a, _ := atlas_build(f, 50.0, char_range(32, 126), 256, 1)
    img2 := image_new(200, 60, 3)
    fill(img2.pix, u8(255))
    draw_text(&img2, a, 4.0, 2.0, "AHo", vec4(0.0, 0.0, 0.0, 1.0))
    // whole-pixel pen positions here (A at 4, H at 30, o at 60; baseline 42): both ways agree
    print("atlas and font drawing equal:", img.pix == img2.pix)
    // clipping at the edges, a grey and an RGBA image, half transparent colour
    grey := image_new(30, 20, 1)
    draw_text(&grey, f, 40.0, -10.0, -5.0, "WAV\nHHHHHH", vec4(1.0, 1.0, 1.0, 1.0))
    rgba := image_new(30, 20, 4)
    draw_text(&rgba, f, 40.0, 0.0, 0.0, "H", vec4(1.0, 0.0, 0.0, 0.5))
    print("grey max", max_of(grey.pix), "rgba pixel in the stem", rgba.get(1, 15), "outside", rgba.get(8, 15))
}

fn max_of(p: []u8) -> u8 {
    m := u8(0)
    for v in p {
        m = max(m, v)
    }
    m
}
