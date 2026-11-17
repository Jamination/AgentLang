// std.font on a font of the system, if there is one of those listed (else the test is skipped
// with status 77): the printable ASCII characters are mapped, render, measure and wrap.
use std.font

const PATHS = [_]str{
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}

fn main() -> i64 {
    data := ""
    found := false
    for p in PATHS {
        data, found = read_file(p)
        if found { break }
    }
    if !found {
        print("no system TrueType font in the usual places")
        return 77
    }
    f, err := font_parse(data)
    print("parsed:", err == "", "many glyphs:", f.glyphs > 200)
    mapped := true
    rendered := true
    s := font_scale(f, 24.0)
    for c in 33..127 {
        g := glyph_index(f, c)
        if g == 0 { mapped = false }
        b := glyph_bitmap(f, g, s)
        total := 0
        for v in b.img.pix { total += i64(v) }
        // a glyph is about as tall as the font size, its ink well below its box
        if b.img.w < 1 || b.img.h < 1 || b.img.h > 40 || total < 255 || total > b.img.w * b.img.h * 255 {
            rendered = false
        }
        _, ok := glyph_outline(f, g)
        if !ok { rendered = false }
    }
    print("printable ASCII mapped:", mapped, "rendered:", rendered)
    m := font_metrics(f, 24.0)
    print("metrics plausible:", m.ascent > 15.0 && m.ascent < 30.0 && m.descent < 0.0 && m.line_height >= m.ascent - m.descent)
    text := "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs!"
    w := line_width(f, 24.0, text)
    print("width plausible:", w > 24.0 * 20.0 && w < 24.0 * 80.0)
    lines := wrap_text(f, 24.0, text, 300.0)
    fit := true
    for l in lines {
        if line_width(f, 24.0, l) > 300.0 { fit = false }
    }
    print("wrapped:", len(lines) > 2, "fits:", fit, "joined back:", join(lines, " ") == text)
    a, aerr := atlas_build(f, 24.0, char_range(32, 126), 256, 1)
    print("atlas:", aerr == "", a.glyphs.len == 95)
    img := image_new(320, 40, 3)
    draw_text(&img, a, 4.0, 4.0, "Hello, World", vec4(1.0, 1.0, 1.0, 1.0))
    lit := 0
    for v in img.pix { if v > 128 { lit += 1 } }
    print("drawn:", lit > 300)
    0
}
