// The HUD text of the software starter (game.al): a TrueType font of the system (a list of
// common paths, with a fallback), rasterised by std.font at the sizes it is drawn at, in
// styles prepared once at start-up: every printable ASCII glyph filled with a vertical gradient,
// given a soft dark outline and a drop shadow, and optionally a coloured glow. Drawing is then
// one blit per glyph with kerned, whole-pixel pen positions.
use std.font
use "blit.al"

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/seguisb.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
// std.font's test font: the same everywhere (the headless run draws with it), but its only
// letters are A, V, H, o and W; the others show as its missing glyph, a box.
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

// The first font of FONT_PATHS that loads, else the test font.
fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    test_font()
}

fn test_font() -> Font {
    f, _ := font_parse(TEST_FONT)
    f
}

// One character in a style: its sprite (and glow) with the top left corner at (x, y) from the
// pen on the baseline.
struct StyledGlyph { index: i64, img: Sprite, glow: Sprite, x: i64, y: i64, advance: f32 }

// One look of the font at one size. `cap` is the height of a capital in pixels: text is placed
// by the top of its capitals.
struct TextStyle { font: Font, scale: f32, cap: f32, glyphs: []StyledGlyph, glows: bool }

// A style of `px` pixels per em: the fill goes from `top` at the top of the capitals to `bottom`
// at the baseline; `outline` pixels of dark rim, a shadow `shadow` pixels down and right, and a
// glow of `glow` pixels in `glow_color` (none if 0).
fn text_style(f: Font, px: f32, top: vec3, bottom: vec3, outline: f32, shadow: i64, glow: i64, glow_color: vec3) -> TextStyle {
    st := TextStyle{font: f, scale: font_scale(f, px), glows: glow > 0}
    h := glyph_bitmap(f, glyph_index(f, 'H'), st.scale)
    st.cap = f32(-h.y)
    st.glyphs = alloc[StyledGlyph](95)
    reach := i64(ceil(outline))
    pad := reach + shadow + glow * 2 + 1
    for ch in 32..127 {
        gi := glyph_index(f, ch)
        bm := glyph_bitmap(f, gi, st.scale)
        g := StyledGlyph{index: gi, advance: f32(glyph_advance(f, gi)) * st.scale, x: bm.x - pad, y: bm.y - pad}
        if bm.img.w > 0 {
            w := bm.img.w + 2 * pad
            hh := bm.img.h + 2 * pad
            cover := alloc[f32](w * hh)
            for y in 0..bm.img.h {
                for x in 0..bm.img.w {
                    cover[(y + pad) * w + x + pad] = f32(bm.img.pix[y * bm.img.w + x]) / 255.0
                }
            }
            // the rim: the coverage spread by `outline` pixels, fading over its last pixel
            rim := alloc[f32](w * hh)
            for y in 0..hh {
                for x in 0..w {
                    m := 0.0
                    for j in -reach..=reach {
                        for i in -reach..=reach {
                            xx := x + i
                            yy := y + j
                            if xx >= 0 && yy >= 0 && xx < w && yy < hh {
                                d := sqrt(f32(i * i + j * j))
                                m = fmax(m, cover[yy * w + xx] * saturate(outline + 0.5 - d))
                            }
                        }
                    }
                    rim[y * w + x] = m
                }
            }
            g.img = sprite_new(w, hh)
            for y in 0..hh {
                // the gradient runs down the capitals, measured from the baseline
                t := saturate((f32(y + g.y) + st.cap) / fmax(st.cap, 1.0))
                fill := lerp(top, bottom, t)
                for x in 0..w {
                    px: u32 = 0
                    if shadow > 0 && x >= shadow && y >= shadow {
                        px = premul(vec4(0.0, 0.0, 0.02, rim[(y - shadow) * w + x - shadow] * 0.55))
                    }
                    px = over(px, premul(vec4(0.02, 0.02, 0.07, rim[y * w + x] * 0.9)))
                    px = over(px, premul(vec4(fill, cover[y * w + x])))
                    g.img.px[y * w + x] = px
                }
            }
            if glow > 0 {
                halo := blurred(rim, w, hh, glow)
                g.glow = sprite_new(w, hh)
                for i in 0..w * hh {
                    g.glow.px[i] = color_u32(vec4(glow_color * saturate(halo[i] * 1.6), 1.0))
                }
            }
        }
        st.glyphs[ch - 32] = g
    }
    st
}

// Two passes of a box blur of radius r, horizontally and vertically (a soft, roughly round glow).
fn blurred(src: []f32, w: i64, h: i64, r: i64) -> []f32 {
    a := clone(src)
    b := alloc[f32](w * h)
    n := f32(2 * r + 1)
    for pass in 0..2 {
        for y in 0..h {
            for x in 0..w {
                s := 0.0
                for i in -r..=r {
                    s += a[y * w + clamp(x + i, 0, w - 1)]
                }
                b[y * w + x] = s / n
            }
        }
        for y in 0..h {
            for x in 0..w {
                s := 0.0
                for j in -r..=r {
                    s += b[clamp(y + j, 0, h - 1) * w + x]
                }
                a[y * w + x] = s / n
            }
        }
    }
    a
}

priv fn styled(st: *TextStyle, c: u8) -> *StyledGlyph {
    i := i64(c)
    if i < 32 || i > 126 {
        i = '?'
    }
    &st.glyphs[i - 32]
}

// Width in pixels of s in a style: the advances with kerning.
fn text_width(st: *TextStyle, s: str) -> i64 {
    pen := 0.0
    prev := -1
    for i in 0..s.len {
        g := styled(st, s[i])
        if prev >= 0 {
            pen += f32(kerning(st.font, prev, g.index)) * st.scale
        }
        pen += g.advance
        prev = g.index
    }
    i64(pen + 0.5)
}

// Draws s with its first letter's left edge at x and the top of its capitals at y, faded by
// k / 256: the glows of all letters first, then the letters over them.
fn draw_text(c: *Canvas, st: *TextStyle, x: i64, y: i64, s: str, k: u32) {
    base := y + i64(st.cap + 0.5)
    for pass in 0..2 {
        if pass == 0 && !st.glows {
            continue
        }
        pen := f32(x)
        prev := -1
        for i in 0..s.len {
            g := styled(st, s[i])
            if prev >= 0 {
                pen += f32(kerning(st.font, prev, g.index)) * st.scale
            }
            at := i64(floor(pen + 0.5))
            if pass == 0 {
                blit(c, &g.glow, at + g.x, base + g.y, Add, k)
            } else {
                blit(c, &g.img, at + g.x, base + g.y, Over, k)
            }
            pen += g.advance
            prev = g.index
        }
    }
}
