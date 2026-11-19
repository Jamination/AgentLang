// The breakout's letters: a TrueType font of the system (std.font), its glyphs rasterised at
// start-up and turned into a signed distance field in the sprite sheet, so the pixel shader of
// render.al draws them sharp at any size, bolder, or as a soft glow. Pure AL.
//
// The font depends on the machine (the first of FONT_PATHS that loads, else the test font of
// std.font), which is why the glyphs are made here and not baked into tiles.png. Nothing of
// the game or of its headless run depends on it.
//
// Sizes are given as before with the bitmap font: `size` view pixels per "font pixel", a
// capital letter is 7 font pixels high, and the distance field reaches FONT_SPREAD font pixels
// to either side of the edge.
use std.font
use "sheet.al"

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/seguisb.ttf",
    "C:/Windows/Fonts/bahnschrift.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
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
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

const GLYPH_EM: f32 = 72.0              // the size of the glyphs in the sheet, pixels per em
const OVERSAMPLE = 4                    // they are rasterised this many times larger
const FIRST_CHAR = 32
const LAST_CHAR = 126

// A glyph in the sheet: its rectangle (the glyph and the reach of the field around it), where
// that rectangle's top left corner is from the pen on the baseline, and the advance; the last
// three in raster pixels.
struct SheetGlyph { tile: Tile, x: f32, y: f32, advance: f32, index: i64 }

struct Letters {
    font: Font
    name: str                    // the file it came from ("" : the test font)
    scale: f32                   // font units to raster pixels
    unit: f32                    // raster pixels per font pixel (a seventh of a capital's height)
    glyphs: [LAST_CHAR - FIRST_CHAR + 1]SheetGlyph
}

// The letters in use (made once by letters_build).
letters: Letters

fn load_font() -> (Font, str) {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return (f, p)
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    (f, "")
}

// The distance of every pixel to the nearest pixel that is `inside` (0 for those), by
// 8-point sequential Euclidean distance transform: each pixel keeps the offset to its nearest
// seed, passed on from its neighbours in two sweeps.
priv fn distances(inside: []bool, w: i64, h: i64) -> []f32 {
    far: f32 = 1.0e5
    off := alloc[vec2](w * h)
    for i in 0..w * h {
        off[i] = if inside[i] { vec2(0.0) } else { vec2(far) }
    }
    fn look(off: []vec2, w: i64, h: i64, x: i64, y: i64, dx: i64, dy: i64) {
        nx := x + dx
        ny := y + dy
        if nx < 0 || ny < 0 || nx >= w || ny >= h {
            return
        }
        c := off[ny * w + nx] + vec2(f32(dx), f32(dy))
        if dot(c, c) < dot(off[y * w + x], off[y * w + x]) {
            off[y * w + x] = c
        }
    }
    for y in 0..h {
        for x in 0..w {
            look(off, w, h, x, y, -1, 0)
            look(off, w, h, x, y, 0, -1)
            look(off, w, h, x, y, -1, -1)
            look(off, w, h, x, y, 1, -1)
        }
        for x in w - 1..=0 by -1 {
            look(off, w, h, x, y, 1, 0)
        }
    }
    for y in h - 1..=0 by -1 {
        for x in w - 1..=0 by -1 {
            look(off, w, h, x, y, 1, 0)
            look(off, w, h, x, y, 0, 1)
            look(off, w, h, x, y, -1, 1)
            look(off, w, h, x, y, 1, 1)
        }
        for x in 0..w {
            look(off, w, h, x, y, -1, 0)
        }
    }
    d := alloc[f32](w * h)
    for i in 0..w * h {
        d[i] = length(off[i])
    }
    d
}

// Rasterises the characters FIRST_CHAR..LAST_CHAR and writes their distance fields into
// `img` (4 channels: white, the field in alpha) in rows from y0 down. Sets `letters`.
fn letters_build(img: *Image, y0: i64) {
    f, name := load_font()
    l := &letters
    l.font = f
    l.name = name
    l.scale = font_scale(f, GLYPH_EM)
    cap := glyph_bitmap(f, glyph_index(f, 'H'), l.scale)
    l.unit = fmax(f32(cap.img.h), 8.0) / 7.0
    pad := i64(ceil(FONT_SPREAD * l.unit)) + 1
    x := 0
    y := y0
    row_h := 0
    m := mark()
    for c in FIRST_CHAR..LAST_CHAR + 1 {
        g := glyph_index(f, c)
        // rasterised OVERSAMPLE times larger, the field computed there and averaged down
        bm := glyph_bitmap(f, g, l.scale * f32(OVERSAMPLE))
        s := OVERSAMPLE
        lx := i64(floor(f32(bm.x) / f32(s))) - pad
        ly := i64(floor(f32(bm.y) / f32(s))) - pad
        w := i64(ceil(f32(bm.x + bm.img.w) / f32(s))) + pad - lx
        h := i64(ceil(f32(bm.y + bm.img.h) / f32(s))) + pad - ly
        if x + w > img.w {
            x = 0
            y += row_h + 1
            row_h = 0
        }
        assert y + h <= img.h, "letters_build: the sheet is too small for the font"
        hw := w * s
        hh := h * s
        inside := alloc[bool](hw * hh)
        outside := alloc[bool](hw * hh)
        for i in 0..hw * hh {
            outside[i] = true
        }
        ox := bm.x - lx * s
        oy := bm.y - ly * s
        for py in 0..bm.img.h {
            for px in 0..bm.img.w {
                if bm.img.pix[py * bm.img.w + px] >= 128 {
                    i := (py + oy) * hw + px + ox
                    inside[i] = true
                    outside[i] = false
                }
            }
        }
        to_in := distances(inside, hw, hh)
        to_out := distances(outside, hw, hh)
        for py in 0..h {
            for px in 0..w {
                sum: f32 = 0.0
                for sy in 0..s {
                    for sx in 0..s {
                        i := (py * s + sy) * hw + px * s + sx
                        sum += if inside[i] { to_out[i] - 0.5 } else { 0.5 - to_in[i] }      // + inside
                    }
                }
                d := sum / f32(s * s) / f32(s)                                              // raster pixels
                a := clamp(0.5 + d / l.unit / (2.0 * FONT_SPREAD), 0.0, 1.0)
                img.set(x + px, y + py, vec4(1.0, 1.0, 1.0, a))
            }
        }
        l.glyphs[c - FIRST_CHAR] = SheetGlyph{Tile{f32(x), f32(y), f32(w), f32(h)}, f32(lx), f32(ly),
            f32(glyph_advance(f, g)) * l.scale, g}
        x += w + 1
        row_h = max(row_h, h)
        release(m)
        m = mark()
    }
    release(m)
}

// The glyph of byte c (outside the font's range: '?').
fn letter(c: u8) -> SheetGlyph {
    k := i64(c)
    if k < FIRST_CHAR || k > LAST_CHAR {
        k = '?'
    }
    letters.glyphs[k - FIRST_CHAR]
}

// The pen's step from character a to b (advance and kerning), in font pixels.
fn letter_step(a: u8, b: u8) -> f32 {
    ga := letter(a)
    k: f32 = 0.0
    if b != 0 {
        k = f32(kerning(letters.font, ga.index, letter(b).index)) * letters.scale
    }
    (ga.advance + k) / letters.unit
}
