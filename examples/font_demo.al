// Loads a TrueType font, wraps a paragraph, draws it into an image, bakes a glyph atlas and
// saves both as PNG files in tmp/.
//   alc run examples/font_demo.al                       a system font, or the test font
//   alc run examples/font_demo.al -- path/to/font.ttf
use std.font

const FONTS = [_]str{
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "tests/std/data/font_test.ttf",
}

fn main() -> i64 {
    paths := if len(args()) > 1 { args()[1..] } else { FONTS[..] }
    f: Font
    err := "no font found"
    for p in paths {
        f, err = font_load(p)
        if err == "" {
            print("font:", p, "glyphs:", f.glyphs)
            break
        }
    }
    if err != "" {
        print(err)
        return 1
    }
    text := concat("Fonts for games, in pure AL: TrueType outlines, kerning (AV, To, Wa), ",
        "antialiased glyphs at any size, atlases for the GPU, and text drawn into images.")
    img := image_new(480, 200, 3)
    fill(img.pix, u8(24))
    lines := wrap_text(f, 22.0, text, 450.0)
    draw_text(&img, f, 22.0, 15.0, 10.0, join(lines, "\n"), vec4(1.0, 0.9, 0.6, 1.0))
    w, h := text_size(f, 22.0, join(lines, "\n"))
    print("lines:", len(lines), "size:", fmtf(w, 1), "x", fmtf(h, 1))
    // the same text from an atlas (the way a sprite renderer would draw it)
    a, aerr := atlas_build(f, 22.0, char_range(32, 126), 256, 4)
    if aerr != "" {
        print(aerr)
        return 1
    }
    draw_text(&img, a, 15.0, 140.0, "From the atlas: Hello, World!", vec4(0.6, 0.9, 1.0, 1.0))
    if !png_save("tmp/font_demo.png", img) || !png_save("tmp/font_atlas.png", a.img) {
        print("cannot write to tmp/")
        return 1
    }
    print("wrote tmp/font_demo.png and tmp/font_atlas.png (atlas", a.img.w, "x", a.img.h, ")")
    0
}
