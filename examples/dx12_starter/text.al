// The starter's text: a TrueType font of the system (a list of common paths, with a
// fallback), its printable ASCII glyphs baked at start-up into art.al's atlas as a
// signed distance field, and kerned layout. A distance field stays sharp at any size: the
// sprite shader of render.al cuts it at the glyph's edge with a one-pixel smooth step wherever
// it lands (mode SDF_TEXT), or turns the distance outside into a soft halo (mode SDF_HALO, the
// neon of titles). Pure AL (std.font, std.image): no GPU here.
//
// The field: each glyph is rasterised at SDF_EM * 2 pixels, an exact Euclidean distance
// transform (Felzenszwalb and Huttenlocher) gives every pixel its distance to the outline, and
// 2 x 2 pixels are averaged into one texel: 0.5 on the outline, 1 at SDF_SPREAD texels inside,
// 0 at SDF_SPREAD outside.
use std.font
use std.image

const SDF_EM = 48                 // texels per em in the atlas
const SDF_SPREAD = 8              // texels of distance the field holds on each side of an edge
const TEXT_W = 1024               // the atlas area the glyphs are packed into
const TEXT_H = 448
const SDF_TEXT: f32 = 1.0         // sprite modes of the shader (0: a plain texture)
const SDF_HALO: f32 = 2.0

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
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

// The first font of FONT_PATHS that loads, else std.font's test font (a few glyphs only).
fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

// Where a character's field is in the atlas, in texels at SDF_EM: its tile, the tile's top
// left corner from the pen on the baseline, and the advance.
struct SdfGlyph { glyph: i64, x: f32, y: f32, w: f32, h: f32, xoff: f32, yoff: f32, advance: f32 }

struct TextFont {
    font: Font
    scale: f32                    // font units to texels
    cap: f32                      // the height of a capital, in ems
    glyphs: [95]SdfGlyph          // characters 32..126
}

// ---- the distance field ----------------------------------------------------------------------

priv const FAR: f32 = 1e20

// The squared distance transform of one row or column: d[q] = min over p of (q - p)^2 + f[p].
priv fn edt_line(f: []f32, d: []f32, v: []i64, z: []f32, n: i64) {
    k := 0
    v[0] = 0
    z[0] = -FAR
    z[1] = FAR
    for q in 1..n {
        fq := f[q] + f32(q * q)
        s := (fq - (f[v[k]] + f32(v[k] * v[k]))) / f32(2 * q - 2 * v[k])
        while s <= z[k] {
            k -= 1
            s = (fq - (f[v[k]] + f32(v[k] * v[k]))) / f32(2 * q - 2 * v[k])
        }
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = FAR
    }
    k = 0
    for q in 0..n {
        while z[k + 1] < f32(q) {
            k += 1
        }
        e := f32(q - v[k])
        d[q] = e * e + f[v[k]]
    }
}

// Squared distances from every pixel to the nearest pixel where `seed` is set (in place).
priv fn edt(grid: []f32, w: i64, h: i64) {
    n := max(w, h)
    f := alloc[f32](n)
    d := alloc[f32](n)
    v := alloc[i64](n)
    z := alloc[f32](n + 1)
    for x in 0..w {
        for y in 0..h { f[y] = grid[y * w + x] }
        edt_line(f, d, v, z, h)
        for y in 0..h { grid[y * w + x] = d[y] }
    }
    for y in 0..h {
        for x in 0..w { f[x] = grid[y * w + x] }
        edt_line(f, d, v, z, w)
        for x in 0..w { grid[y * w + x] = d[x] }
    }
}

// Bakes the fields of characters 32..126 into `img` (premultiplied white, alpha = field) in the
// TEXT_W x TEXT_H area at `at`.
fn bake_text(img: *Image, at: (i64, i64), f: Font) -> TextFont {
    t := TextFont{font: f, scale: font_scale(f, f32(SDF_EM))}
    hi := font_scale(f, f32(SDF_EM * 2))
    pad := SDF_SPREAD * 2
    h_bits := glyph_bitmap(f, glyph_index(f, 'H'), hi)
    t.cap = f32(-h_bits.y) / f32(SDF_EM * 2)
    x := 0
    y := 0
    row := 0
    for c in 32..127 {
        m := mark()
        gi := glyph_index(f, c)
        bits := glyph_bitmap(f, gi, hi)
        // the padded grid, even-sized for the 2 x 2 average
        w := (bits.img.w + 2 * pad + 1) / 2 * 2
        h := (bits.img.h + 2 * pad + 1) / 2 * 2
        outside := alloc[f32](w * h)        // distance to ink
        inside := alloc[f32](w * h)         // distance to no ink
        for p in 0..w * h {
            px := p % w - pad
            py := p / w - pad
            ink := px >= 0 && py >= 0 && px < bits.img.w && py < bits.img.h && bits.img.pix[py * bits.img.w + px] >= 128
            outside[p] = if ink { 0.0 } else { FAR }
            inside[p] = if ink { FAR } else { 0.0 }
        }
        edt(outside, w, h)
        edt(inside, w, h)
        tw := w / 2
        th := h / 2
        if x + tw + 2 > TEXT_W {
            x = 0
            y += row + 2
            row = 0
        }
        assert y + th <= TEXT_H, "text: the glyphs do not fit their atlas area"
        for ty in 0..th {
            for tx in 0..tw {
                sd: f32 = 0.0                   // signed distance in high-resolution pixels, + outside
                for k in 0..4 {
                    p := (ty * 2 + k / 2) * w + tx * 2 + k % 2
                    sd += if outside[p] > 0.0 { sqrt(outside[p]) - 0.5 } else { 0.5 - sqrt(inside[p]) }
                }
                a := saturate(0.5 - sd / 4.0 / 2.0 / f32(2 * SDF_SPREAD))
                q := ((at.1 + y + ty) * img.w + at.0 + x + tx) * 4
                v := u8(i64(a * 255.0 + 0.5))
                img.pix[q] = v
                img.pix[q + 1] = v
                img.pix[q + 2] = v
                img.pix[q + 3] = v
            }
        }
        t.glyphs[c - 32] = SdfGlyph{
            glyph: gi, x: f32(at.0 + x), y: f32(at.1 + y), w: f32(tw), h: f32(th),
            xoff: f32(bits.x - pad) / 2.0, yoff: f32(bits.y - pad) / 2.0, advance: f32(glyph_advance(f, gi)) * t.scale,
        }
        x += tw + 2
        row = max(row, th)
        release(m)
    }
    t
}

// ---- layout ----------------------------------------------------------------------------------

// The glyph of byte c (characters outside 32..126 show as '?').
fn sdf_glyph(t: *TextFont, c: u8) -> *SdfGlyph {
    i := i64(c) - 32
    &t.glyphs[if i >= 0 && i < 95 { i } else { i64('?') - 32 }]
}

// The width of a line of text `size` virtual pixels per em, with kerning.
fn text_w(t: *TextFont, size: f32, text: str) -> f32 {
    k := size / f32(SDF_EM)
    x: f32 = 0.0
    prev := -1
    for c in text {
        g := sdf_glyph(t, c)
        if prev >= 0 {
            x += f32(kerning(t.font, prev, g.glyph)) * t.scale * k
        }
        x += g.advance * k
        prev = g.glyph
    }
    x
}
