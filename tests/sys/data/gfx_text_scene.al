// The scenes of the std.gfx_text tests (tests/sys/gfx_text.al: the backend of the target;
// tests/sys/gfx_text_vk.al: Vulkan on Windows). Text drawn by the GPU offscreen is compared,
// pixel by pixel, with the same text drawn into an image by std.font's software draw_text:
// kerning, a wrapped paragraph, alignment, non-ASCII characters, missing glyphs, a scaled
// set_view, and a 4-channel atlas under a linear filter. Written against the API only, so the
// same file checks every backend. Not a test by itself (tests/sys/data is not scanned).
use std.font
use std.gfx_text

const FONT_DATA = embed("../../std/data/font_test.ttf")
const W = 200
const H = 120
const BG: u32 = 0xFF402010
const INK: u32 = 0xFF40E0FF
const PARAGRAPH = "HAVo WoHA AVAW HoH VoW AH oVo WAHAV HoWAVo"

// The largest difference of any channel over all the comparisons, for the report.
worst: i64
// The characters of the fonts: those of the test font, and two it does not have.
fn charset() -> []i64 {
    cs := vec_of(char_range(32, 126))
    cs.extend([]i64{0xA8, 0xAF, 0xC4, 0x1DE, 0x1F600})
    cs.items()
}

// An image of the frame's size filled with the clear colour.
fn background(c: u32) -> Image {
    img := image_new(W, H, 4)
    for i in 0..W * H {
        img.pix[4 * i] = u8(c)
        img.pix[4 * i + 1] = u8(c >> 8)
        img.pix[4 * i + 2] = u8(c >> 16)
        img.pix[4 * i + 3] = 255
    }
    img
}

// The largest difference of a colour channel and the number of pixels more than `tol` off.
fn diff(a: Image, b: Image, tol: i64) -> (i64, i64) {
    most := 0
    off := 0
    for i in 0..W * H {
        bad := false
        for c in 0..4 {
            d := abs(i64(a.pix[4 * i + c]) - i64(b.pix[4 * i + c]))
            most = max(most, d)
            if d > tol { bad = true }
        }
        if bad { off += 1 }
    }
    (most, off)
}

// The number of pixels that differ from the background (the ink of the text).
fn ink(a: Image, c: u32) -> i64 {
    n := 0
    bg := background(c)
    for i in 0..W * H {
        if a.pix[4 * i..4 * i + 3] != bg.pix[4 * i..4 * i + 3] { n += 1 }
    }
    n
}

// Prints `ok` or `WRONG` for a comparison within `tol` per channel; the numbers go to stderr.
fn check(what: str, gpu: Image, want: Image, tol: i64) -> i64 {
    most, off := diff(gpu, want, tol)
    worst = max(worst, most)
    eprint(fmt("  ", what, ": largest difference ", most, ", pixels off by more than ", tol, ": ", off, ", ink ", ink(want, BG)))
    if off == 0 && ink(want, BG) > 0 {
        print("  ok", what)
        return 0
    }
    print("  WRONG", what, "largest difference", most, "pixels off", off)
    1
}

priv fn frame(g: *Gfx, clear: u32) {
    assert g.begin_frame(clear), "begin_frame refused an offscreen frame"
}

priv fn finish(g: *Gfx) -> Image {
    assert g.end_frame() == ""
    g.read_pixels()
}

// Runs every scene on a new offscreen renderer. (wrong comparisons, "") or (0, why there is
// no device). `save`: a directory to write the GPU frames and the references into ("" not).
fn run_text(desc: GfxDesc, save: str) -> (i64, str) {
    g, err := gfx_offscreen(W, H, desc)
    if err != "" { return (0, err) }
    eprint(concat("device: ", g.device))
    f, ferr := font_parse(FONT_DATA)
    assert ferr == "", ferr
    col := color_vec4(INK)
    f24, e1 := gfx_font(g, f, 24.0, charset())
    f20, e2 := gfx_font(g, f, 20.0, charset())
    f16, e3 := gfx_font(g, f, 16.0, charset())
    assert e1 == "" && e2 == "" && e3 == "", fmt(e1, e2, e3)
    wrong := 0
    shots := vec[(str, Image, Image)]()
    fn keep(shots: *Vec[(str, Image, Image)], name: str, gpu: Image, want: Image) { shots.push((name, gpu, want)) }

    // kerning (A V, V A, W A pairs) at a fractional position: the pen is rounded to whole pixels
    frame(g, BG)
    m0 := mem_used()
    g.draw_text(f24, 3.3, 2.0, "AVAWAV VA", INK)
    g.draw_text(f24, 120.7, 2.4, "WAVA", INK)
    m1 := mem_used()
    gpu := finish(g)
    want := background(BG)
    draw_text(&want, f24.atlas, 3.3, 2.0, "AVAWAV VA", col)
    draw_text(&want, f24.atlas, 120.7, 2.4, "WAVA", col)
    wrong += check("kerning, against std.font's draw_text with the atlas", gpu, want, 2)
    print("  one draw call:", g.stats.draw_calls == 1, "nothing allocated while drawing:", m1 == m0)
    keep(&shots, "kerning", gpu, want)

    // pens on whole pixels: the same as std.font's own rasteriser at its subpixel positions
    frame(g, BG)
    g.draw_text(f20, 4.0, 40.0, "HoW VoH WoH", INK)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f, 20.0, 4.0, 40.0, "HoW VoH WoH", col)
    wrong += check("whole-pixel pens, against std.font's draw_text with the font", gpu, want, 2)
    keep(&shots, "font", gpu, want)

    // a wrapped paragraph, and right / centred lines
    frame(g, BG)
    h := g.draw_text_box(f16, vec4(6.0, 4.0, 110.0, 0.0), PARAGRAPH, INK, AlignLeft)
    g.draw_text(f20, 196.0, 30.0, "HoW\nAVo\nH", INK, AlignRight)
    g.draw_text(f16, 160.0, 100.0, "VoW", INK, AlignCenter)
    gpu = finish(g)
    lines := wrap_text(f, 16.0, PARAGRAPH, 110.0)
    want = background(BG)
    draw_text(&want, f16.atlas, 6.0, 4.0, join(lines, "\n"), col)
    for i, l in []str{"HoW", "AVo", "H"} {
        draw_text(&want, f20.atlas, 196.0 - line_width(f, 20.0, l), 30.0 + f32(i) * f20.atlas.metrics.line_height, l, col)
    }
    draw_text(&want, f16.atlas, 160.0 - line_width(f, 16.0, "VoW") * 0.5, 100.0, "VoW", col)
    wrong += check("wrapped paragraph and aligned lines, against wrap_text and draw_text", gpu, want, 2)
    print("  paragraph:", len(lines), "lines, height", h == f32(len(lines)) * line_height(f16), "size", text_size(f16, PARAGRAPH, 110.0) == text_size(f, 16.0, join(lines, "\n")))
    keep(&shots, "wrapped", gpu, want)

    // non-ASCII: U+00C4 and U+01DE (composite glyphs), U+1F600 (cmap format 12), U+00A8, U+00AF;
    // missing characters (Z, ?, the euro sign, U+FFFD of a broken sequence) as the font's glyph 0
    text := "\xc3\x84\xc7\x9e A\xc3\x84\xf0\x9f\x98\x80 \xc2\xa8\xc2\xaf"
    missing := "AZ?\xe2\x82\xac\xffH"
    frame(g, BG)
    g.draw_text(f24, 4.0, 4.0, text, INK)
    g.draw_text(f24, 4.0, 40.0, missing, INK)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f24.atlas, 4.0, 4.0, text, col)
    draw_text(&want, f24.atlas, 4.0, 40.0, missing, col)
    wrong += check("non-ASCII and missing glyphs", gpu, want, 2)
    keep(&shots, "unicode", gpu, want)

    // a character of the font that is not in the atlas: drawn as glyph 0 with its advance, as a
    // character the font does not have at all
    small, e4 := gfx_font(g, f, 24.0, []i64{'H', 'A', 'V'})
    assert e4 == "", e4
    frame(g, BG)
    g.draw_text(small, 4.0, 4.0, "HoAW", INK)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f24.atlas, 4.0, 4.0, "HZAZ", col)
    wrong += check("characters not in the atlas: the missing glyph", gpu, want, 2)
    keep(&shots, "notinatlas", gpu, want)
    // ... until gfx_font_add puts them in
    assert g.gfx_font_add(&small, []i64{'o', 'W'}) == ""
    frame(g, BG)
    g.draw_text(small, 4.0, 4.0, "HoAW", INK)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f24.atlas, 4.0, 4.0, "HoAW", col)
    wrong += check("gfx_font_add", gpu, want, 2)
    gfx_font_free(g, small)

    // a scaled set_view: 100 x 50 in 200 x 120 is a scale of 2 with bars of 10 pixels above and
    // below. A font rasterised at 24 pixels drawn at size 12 is drawn texel for pixel: the same
    // as std.font drawing the 24-pixel atlas at the doubled position.
    crisp := f24
    crisp.size = 12.0
    frame(g, BG)
    g.set_view(100.0, 50.0)
    g.draw_text(crisp, 5.3, 3.0, "AVAW HoV", INK)
    g.draw_text_box(crisp, vec4(5.0, 18.0, 60.0, 0.0), "HoW AVA WoH", INK, AlignLeft)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f24.atlas, 10.6, 16.0, "AVAW HoV", col)
    draw_text(&want, f24.atlas, 10.0, 46.0, join(wrap_text(f, 24.0, "HoW AVA WoH", 120.0), "\n"), col)
    wrong += check("set_view scale 2, a 24-pixel font at size 12", gpu, want, 2)
    keep(&shots, "view2", gpu, want)

    // a 16-pixel font magnified 1.5 times by set_view and the linear filter: blurrier than the
    // text rasterised at 24 pixels, but in the same place
    frame(g, BG)
    g.set_view(f32(W) / 1.5, f32(H) / 1.5)
    g.draw_text(f16, 4.0, 4.0, "AVAW HoV", INK)
    gpu = finish(g)
    want = background(BG)
    draw_text(&want, f, 24.0, 6.0, 6.0, "AVAW HoV", col)
    most, _ := diff(gpu, want, 255)
    a := ink(gpu, BG)
    b := ink(want, BG)
    eprint(fmt("  set_view scale 1.5, a 16-pixel font magnified: largest difference to the 24-pixel text ", most, ", ink ", a, " and ", b))
    same := same_box(gpu, want, 2)
    print("  set_view scale 1.5: ink in the same place:", same)
    if !same { wrong += 1 }
    keep(&shots, "view15", gpu, want)

    // straight alpha and the linear filter: white text from a 4-channel atlas on white, moved by
    // fractions of a pixel and magnified, stays white (an atlas whose transparent pixels are
    // black between the glyphs gives dark fringes)
    a4, e5 := atlas_build(f, 16.0, charset(), 128, 4)
    assert e5 == "", e5
    white4 := gfx_font(g, a4, FilterLinear)
    white1 := f16
    frame(g, 0xFFFFFFFF)
    g.set_transform(xform_mul(xform_translate(vec2(0.37, 0.61)), xform_scale(vec2(1.37))))
    g.draw_text(white4, 2.0, 2.0, "AVAW HoV\nWoHA", 0xFFFFFFFF)
    g.draw_text(white1, 2.0, 40.0, "AVAW HoV\nWoHA", 0xFFFFFFFF)
    gpu = finish(g)
    wrong += check_white("white on white under a linear filter (1 and 4 channels): no dark fringe", gpu)
    gfx_font_free(g, white4)

    if save != "" {
        for s in shots {
            png_save(fmt(save, "/", s.0, "_gpu.png"), s.1)
            png_save(fmt(save, "/", s.0, "_ref.png"), s.2)
        }
    }
    gfx_font_free(g, f24)
    gfx_font_free(g, f20)
    gfx_font_free(g, f16)
    gfx_close(g)
    (wrong, "")
}

// Whether the ink of both images (pixels that differ from the background) has the same
// bounding box within `tol` pixels.
fn same_box(a: Image, b: Image, tol: i64) -> bool {
    fn bbox(img: Image) -> [4]i64 {
        r := [4]i64{W, H, -1, -1}
        bg := background(BG)
        for y in 0..H {
            for x in 0..W {
                i := 4 * (y * W + x)
                if img.pix[i..i + 3] != bg.pix[i..i + 3] {
                    r[0] = min(r[0], x)
                    r[1] = min(r[1], y)
                    r[2] = max(r[2], x)
                    r[3] = max(r[3], y)
                }
            }
        }
        r
    }
    p := bbox(a)
    q := bbox(b)
    eprint(fmt("  ink boxes ", p, " and ", q))
    for k in 0..4 {
        if abs(p[k] - q[k]) > tol { return false }
    }
    true
}

// Prints `ok` if every pixel is white (within 1), else `WRONG` and the darkest.
fn check_white(what: str, img: Image) -> i64 {
    darkest := 255
    for i in 0..W * H {
        for c in 0..3 {
            darkest = min(darkest, i64(img.pix[4 * i + c]))
        }
    }
    eprint(fmt("  ", what, ": darkest channel ", darkest))
    worst = max(worst, 255 - darkest)
    if darkest >= 254 {
        print("  ok", what)
        return 0
    }
    print("  WRONG", what, "darkest", darkest)
    1
}
