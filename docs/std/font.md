# std.font

`use std.font`. TrueType and OpenType fonts with TrueType outlines: parsing, antialiased glyph
rasterisation at any size, kerning, glyph atlases for a GPU or a software renderer, and text
layout on UTF-8 strings. Everything is written in AL: no FreeType, no libc, so programs using
it stay static executables. Images are `std.image`'s `Image` (which `use std.font` includes).

```
// examples/font_demo.al (shortened)
use std.font

fn main() {
    f, err := font_load("C:/Windows/Fonts/segoeui.ttf")
    if err != "" {
        print(err)
        return
    }
    img := image_new(480, 200, 3)
    lines := wrap_text(f, 22.0, "Fonts for games, in pure AL ...", 450.0)
    draw_text(&img, f, 22.0, 15.0, 10.0, join(lines, "\n"), vec4(1.0, 0.9, 0.6, 1.0))
    a, _ := atlas_build(f, 22.0, char_range(32, 126), 256, 4)    // for a sprite renderer
    draw_text(&img, a, 15.0, 140.0, "From the atlas: Hello, World!", vec4(0.6, 0.9, 1.0, 1.0))
    png_save("tmp/font_demo.png", img)
}
```

**Sizes and coordinates.** A size `px` is the em size in pixels: `font_scale(f, px)` is
`px / units_per_em`, the factor from font units to pixels (a 16 px font has letters a little
under 16 pixels from the top of a capital to the bottom of a descender, depending on the
font). Font units have y up; everything in pixels has y down. Layout places a block of text
with its top left corner at (0, 0): the first baseline is at the font's ascent, the next ones
one line height further down.

## Fonts

```
struct Font {                      // the tables and offsets of a parsed font; read the first six
    data: []u8                     // the file (kept, not copied)
    glyphs: i64                    // number of glyphs
    units_per_em: i64
    ascent: i64                    // font units, above the baseline (hhea)
    descent: i64                   // below it: negative
    line_gap: i64
    ...
}
struct FontMetrics { ascent: f32, descent: f32, line_gap: f32, line_height: f32 }
```

| Function | |
|----------|---|
| `font_load(path) -> (Font, str)` | read and parse a `.ttf`, `.otf` or the first font of a `.ttc`; `""` or what is wrong |
| `font_parse(data) -> (Font, str)` / `font_parse(data, index)` | the same from memory (`embed("font.ttf")`); `index`: the font of a collection |
| `font_scale(f, px) -> f32` | font units to pixels for an em size of `px` |
| `font_metrics(f, px) -> FontMetrics` | ascent, descent (negative), line gap and `line_height = ascent - descent + line_gap`, in pixels |
| `glyph_index(f, cp) -> i64` | the glyph of a Unicode code point; 0 (the font's "missing" glyph) if it has none |
| `glyph_advance(f, glyph) -> i64` `glyph_lsb(f, glyph) -> i64` | advance width and left side bearing, font units |
| `kerning(f, left, right) -> i64` | added to the advance of `left` before `right`, font units |

**What is read**: the tables `head`, `maxp`, `hhea`, `hmtx`, `loca`, `glyf`, `cmap` (Unicode
subtables of format 4 and 12; format 12 is preferred, it reaches code points above U+FFFF; a
Windows symbol subtable when there is no Unicode one, where the characters 0..255 are the
font's symbols, as in Wingdings),
`kern` (a format 0 subtable) and `GPOS` (the lookups of the `kern` feature: pair adjustment
formats 1 and 2, also behind extension lookups; when the font has them, `kern` is not used).
Composite glyphs are resolved to any depth up to 8, with scales, 2 x 2 transforms and
components placed by offsets or by matching points. Hinting instructions are skipped (glyphs
are rendered unhinted), and so are vertical metrics other than `hhea`, ligatures and other
substitutions (`GSUB`), mark positioning, and variable fonts' variations (the default instance
is drawn).

**CFF outlines** (OpenType fonts whose outlines are PostScript, `OTTO` files with a `CFF ` or
`CFF2` table, most `.otf` files) are not supported: `font_parse` returns `font: CFF (PostScript)
outlines are not supported, only TrueType outlines (glyf)`.

**Malformed fonts** never stop the program: every offset, length and count is checked against
the data. A font whose tables are missing, cut off or inconsistent is rejected with a message
(`font: the 'loca' table lies outside the file`, `font: no Unicode character map (cmap format 4
or 12)`, ...); a damaged glyph (an offset past its table, a contour end out of order, a
composite that contains itself) makes `glyph_outline` return `false` and the glyph draw as
nothing, while the rest of the font works. Kerning data that points outside its table gives 0.

## Glyphs

```
struct Outline { x: Vec[f32], y: Vec[f32], on: Vec[bool], ends: Vec[i64] }
struct GlyphBitmap { img: Image, x: i64, y: i64 }
```

| Function | |
|----------|---|
| `glyph_outline(f, glyph) -> (Outline, bool)` | the points in font units, y up; contour `k` is `ends[k - 1]..ends[k]`; `on` marks on-curve points, the others are quadratic control points |
| `glyph_bitmap(f, glyph, scale) -> GlyphBitmap` | the glyph rasterised: `img` has one channel of coverage (0..255), its top left corner goes at (`x`, `y`) from the pen position on the baseline |
| `glyph_bitmap(f, glyph, scale, shift_x, shift_y)` | the pen moved right / down by a fraction of a pixel first (subpixel positioning) |

The rasteriser accumulates, for every pixel, the exact area the outline covers (the method of
font-rs): curves become straight lines within 0.05 pixels of the curve, the lines' signed areas
are summed per pixel and a running sum gives the coverage. Overlapping contours of the same
direction add up and are clamped to full coverage. A glyph without outline (space) gives a
0 x 0 image; one larger than 8192 pixels on a side gives an empty one.

## Atlas

```
struct AtlasGlyph {
    cp: i64, glyph: i64
    x: i64, y: i64, w: i64, h: i64     // rectangle in the atlas image
    xoff: i64, yoff: i64               // its top left corner from the pen position on the baseline (y down)
    advance: f32                       // pixels
    u0: f32, v0: f32, u1: f32, v1: f32 // the rectangle in texture coordinates
}
struct Atlas { font: Font, px: f32, scale: f32, metrics: FontMetrics, img: Image, glyphs: Map[i64, AtlasGlyph], missing: AtlasGlyph }
```

| Function | |
|----------|---|
| `atlas_build(f, px, chars: []i64, width, channels) -> (Atlas, str)` | rasterises the code points `chars` (repeats ignored) and glyph 0 at size `px`, packed in rows (tallest first, 1 pixel apart) into an image `width` pixels wide and as high as needed; `channels` 1: coverage, 4: the coverage as alpha (straight alpha) and white RGB in every pixel, also the empty ones, so that a GPU's linear filter mixes no black into the glyphs' edges. `""` or what is wrong (a glyph wider than the image, another channel count) |
| `char_range(first, last) -> []i64` | the code points `first..=last`: `char_range(32, 126)` is printable ASCII |
| `atlas_glyph(a, cp) -> AtlasGlyph` | the glyph of a code point, or `a.missing` |

A GPU renderer draws exactly what `draw_text(&img, atlas, ...)` below draws into an image: it
uploads `a.img.pix`, then for each `GlyphPos` of `layout_text(a.font, a.px, text)` draws the
quad of `atlas_glyph(a, p.cp)` at `(x + p.x + g.xoff, y + p.y + g.yoff)`, `g.w` x `g.h`
pixels, with texture coordinates `(g.u0, g.v0)`-`(g.u1, g.v1)`, the pen position rounded to
whole pixels (`floor(v + 0.5)`) for crisp text: glyphs are rasterised at a pen position on a
whole pixel, and the 1-pixel gap between them keeps a linear filter from mixing in a
neighbour.

## Text

UTF-8 throughout (a malformed sequence is U+FFFD); `'\n'` breaks lines, `'\r'` is ignored.

```
struct GlyphPos { cp: i64, glyph: i64, x: f32, y: f32, byte: i64, line: i64 }
```

| Function | |
|----------|---|
| `layout_text(f, px, text) -> []GlyphPos` | every character (spaces too, not `'\n'`) with its pen position on the baseline, kerning applied, the byte index in `text` and its line |
| `line_width(f, px, text) -> f32` | where the pen ends after one line (up to the first `'\n'`): the advance width with kerning |
| `text_size(f, px, text) -> (f32, f32)` | the widest line and `lines * line_height` |
| `wrap_text(f, px, text, max_w) -> []str` | lines no wider than `max_w`: broken at `'\n'` and at spaces (dropped there), a word too long for a line between characters; views of `text`. `max_w <= 0`: only at `'\n'` |
| `draw_text(&img, f, px, x, y, text, col: vec4)` | draws text with its top left corner at (x, y), every glyph rasterised at its exact subpixel position, colour `col` (alpha blends; on 2- and 4-channel images the alpha of the image grows) |
| `draw_text(&img, atlas, x, y, text, col)` | the same with an atlas's glyphs, at whole-pixel positions: much faster for text drawn every frame |
| `utf8_next(s, i) -> (i64, i64)` | the code point at byte `i` and the index after it |

`draw_text` with a font allocates while it runs and gives the memory back before it returns
(`mark` / `release`); everything else that returns slices or images allocates from the arena.
For wrapped text: `draw_text(&img, f, px, x, y, join(wrap_text(f, px, text, w), "\n"), col)`.

## Tests

`tests/gen/make_font.al` writes the two test fonts in `tests/std/data/`: 11 glyphs with holes,
quadratic curves (one contour of off-curve points only), hinting instructions, composites
(scaled, nested, placed by point matching), kerning pairs; one with cmap formats 4 and 12,
long `loca` and GPOS kerning (a format 1 and a class-based format 2 subtable behind an
extension), the other with format 4 only, short `loca`, a `kern` table and fewer advances than
glyphs. `font_basic.al` checks indices, advances, kerning, outlines, bitmap placement and the
covered area of every glyph against what Windows' DirectWrite reports for the same files.
`font_text.al` covers UTF-8, layout, wrapping, atlases and drawing; `font_bad.al` feeds 35
damaged fonts, every prefix of both files and 10,000 randomly damaged copies, using everything
on those that parse. `font_system.al` renders a system font (Arial, Segoe UI, DejaVu Sans,
Liberation Sans or Noto Sans where installed; skipped otherwise). Every font in
`C:\Windows\Fonts` of a Windows 11 machine was parsed and all its glyphs rendered without a
failure while the module was written.
