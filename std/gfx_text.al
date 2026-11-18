// std.gfx_text: text for std.gfx with the fonts of std.font. A GfxFont is a glyph atlas of one
// font at one pixel size (std.font's atlas_build) uploaded as a coverage texture; draw_text
// lays out UTF-8 text (kerning, '\n', alignment, wrapping into a box) and draws its glyphs
// through the batcher of std.gfx, in the tint's colour. docs/std/gfx.md, "Text".
//
// A separate module so that neither side forces the other on a program: std.gfx does not
// carry the font code into a game without text, std.font does not carry a GPU into a tool
// that only draws into images. It uses only std.gfx_core of std.gfx: the program writes
// `use std.gfx` (or `use std.gfx_vk`) beside `use std.gfx_text`, which picks the backend.
//
// Drawing allocates nothing: it reads the atlas and writes vertices, so it may run every frame
// inside frame_begin() / frame_end(). Making or extending a GfxFont rasterises glyphs and
// allocates (do it at load time, outside the frame's scratch memory).
use std.gfx_core
use std.font

// How the lines of a text are placed against the x of draw_text (its left end, centre or
// right end), and within the width of a box.
enum TextAlign { AlignLeft, AlignCenter, AlignRight }

// A font on the GPU: the glyphs of a set of characters at one pixel size. A value to keep and
// copy (the copies share the atlas and texture). Characters that are not in the atlas are
// drawn as the font's missing glyph (glyph 0, usually a box): gfx_font_add adds characters.
struct GfxFont {
    atlas: Atlas          // the glyphs (std.font): atlas.px is the size they are rasterised at
    tex: Texture          // atlas.img on the GPU (a coverage texture, or RGBA for a 4-channel atlas)
    size: f32             // the em size text is drawn at, in the units of the transform: atlas.px
                          // at first; another size scales the glyphs (filtered, less sharp)
    filter: Filter
    low: []AtlasGlyph     // the glyphs of code points 0..255 (internal: no map lookup for them)
}

// Rasterises the characters `chars` of `f` (char_range(32, 126): printable ASCII) at an em
// size of px pixels into an atlas and uploads it (linear filtering). ("" or what is wrong:
// a bad size, an atlas wider than a texture can be.) Not inside frame_begin() / frame_end():
// the atlas is kept.
fn gfx_font(g: *Gfx, f: Font, px: f32, chars: []i64) -> (GfxFont, str) {
    a, err := atlas_for(f, px, chars)
    if err != "" {
        return (GfxFont{}, err)
    }
    (gfx_font(g, a, FilterLinear), "")
}

// A GfxFont from an atlas made with std.font's atlas_build (1 or 4 channels), uploaded with
// the given filter.
fn gfx_font(g: *Gfx, a: Atlas, filter: Filter) -> GfxFont {
    font := GfxFont{atlas: a, size: a.px, filter: filter}
    font.tex = g.texture(a.img, filter)
    font.low = alloc[AtlasGlyph](256)
    for c in 0..256 {
        font.low[c] = atlas_glyph(a, c)
    }
    font
}

// Adds the characters `chars` to the font: rasterises the atlas again with them and replaces
// the texture (frees the old one: not between begin_frame and end_frame). For text that is
// only known while the game runs (a player's name, a chat line); "" or what is wrong.
fn gfx_font_add(g: *Gfx, font: *GfxFont, chars: []i64) -> str {
    all := vec_of(font.atlas.glyphs.keys())
    n := all.len
    for c in chars {
        if !font.atlas.glyphs.has(c) {
            all.push(c)
        }
    }
    if all.len == n {
        return ""
    }
    a, err := atlas_for(font.atlas.font, font.atlas.px, all.items())
    if err != "" {
        return err
    }
    size := font.size
    g.free_texture(font.tex)
    *font = gfx_font(g, a, font.filter)
    font.size = size
    ""
}

// Releases the font's texture (not between begin_frame and end_frame).
fn gfx_font_free(g: *Gfx, font: GfxFont) {
    g.free_texture(font.tex)
}

// The distance from one baseline to the next at the font's size.
fn line_height(font: GfxFont) -> f32 {
    font.atlas.metrics.line_height * (font.size / font.atlas.px)
}

// ---- measuring -------------------------------------------------------------------------------

// The size of a text drawn by draw_text: its widest line and the number of lines ('\n'
// separates them) times line_height.
fn text_size(font: GfxFont, text: str) -> (f32, f32) {
    text_size(font, text, 0.0)
}

// The size of a text wrapped to max_w as draw_text_box wraps it (max_w <= 0: no wrapping).
fn text_size(font: GfxFont, text: str, max_w: f32) -> (f32, f32) {
    f := &font
    k := f.size / f.atlas.px
    w := f32(0.0)
    lines := 0
    start := 0
    loop {
        end := para_end(text, start)
        para := text[start..end]
        at := 0
        loop {
            line_end, next := break_line(f, para, at, max_w / k)
            w = fmax(w, width_of(f, para[at..line_end]) * k)
            lines += 1
            if next >= len(para) {
                break
            }
            at = next
        }
        if end >= len(text) {
            break
        }
        start = end + 1
    }
    (w, f32(lines) * f.atlas.metrics.line_height * k)
}

// ---- drawing ---------------------------------------------------------------------------------

// Draws text (UTF-8, '\n' breaks lines) with the top left corner of its first line at (x, y)
// in the colour `color` (RGBA8, as everywhere in std.gfx): the first baseline is the font's
// ascent below y. The pen position of every glyph is rounded to a whole pixel of the target
// (under a transform that only scales and moves), so the glyphs are drawn texel for pixel.
fn draw_text(g: *Gfx, font: GfxFont, x: f32, y: f32, text: str, color: u32) {
    draw_text(g, font, x, y, text, color, AlignLeft)
}

// The same with every line aligned: x is the left end, the centre or the right end of each.
fn draw_text(g: *Gfx, font: GfxFont, x: f32, y: f32, text: str, color: u32, align: TextAlign) {
    f := &font
    k := f.size / f.atlas.px
    line := 0
    start := 0
    loop {
        end := para_end(text, start)
        s := text[start..end]
        draw_line(g, f, line_x(f, s, x, 0.0, align), y + (f.atlas.metrics.ascent + f32(line) * f.atlas.metrics.line_height) * k, s, color)
        if end >= len(text) {
            break
        }
        start = end + 1
        line += 1
    }
}

// Draws text wrapped into the rectangle r (x, y, w, h): broken at '\n' and at spaces (a word
// wider than r.w between characters), as std.font's wrap_text does; each line aligned within
// r's width, the first one at the top of r. Lines that would reach below r are not drawn (a
// height of 0: no limit). Returns the height of the lines drawn (their number times
// line_height).
fn draw_text_box(g: *Gfx, font: GfxFont, r: vec4, text: str, color: u32, align: TextAlign) -> f32 {
    f := &font
    k := f.size / f.atlas.px
    m := f.atlas.metrics
    line := 0
    start := 0
    loop {
        end := para_end(text, start)
        para := text[start..end]
        at := 0
        loop {
            if r.w > 0.0 && f32(line + 1) * m.line_height * k > r.w + 0.001 {
                return f32(line) * m.line_height * k
            }
            line_end, next := break_line(f, para, at, r.z / k)
            s := para[at..line_end]
            draw_line(g, f, line_x(f, s, r.x, r.z, align), r.y + (m.ascent + f32(line) * m.line_height) * k, s, color)
            line += 1
            if next >= len(para) {
                break
            }
            at = next
        }
        if end >= len(text) {
            break
        }
        start = end + 1
    }
    f32(line) * m.line_height * k
}

// ---- internal --------------------------------------------------------------------------------

// The atlas of a GfxFont: one channel, as wide as needed for a roughly square image.
priv fn atlas_for(f: Font, px: f32, chars: []i64) -> (Atlas, str) {
    if !(px > 0.0) || px > 2048.0 {
        return (Atlas{}, "gfx_font: the size must be above 0 and at most 2048 pixels")
    }
    // characters the font does not have are left to the missing glyph (instead of a copy of it each)
    have := vec[i64]()
    for c in chars {
        if glyph_index(f, c) != 0 {
            have.push(c)
        }
    }
    chars = have.items()
    // a guess from the number of glyphs and their size; wider and again if the image is taller
    // than wide or a glyph does not fit
    cell := i64(px * 1.2) + 2
    width := 64
    while width * width < (len(chars) + 1) * cell * cell && width < 16384 {
        width *= 2
    }
    loop {
        m := mark()
        a, err := atlas_build(f, px, chars, width, 1)
        if err == "" && a.img.h <= width {
            return (a, "")
        }
        if width >= 16384 {
            if err == "" {
                err = "gfx_font: the glyphs do not fit into a 16384 x 16384 texture"
            }
            return (a, err)
        }
        release(m)
        width *= 2
    }
}

// The atlas glyph of a code point (the missing glyph if the atlas does not have it).
priv fn glyph_of(f: *GfxFont, cp: i64) -> AtlasGlyph {
    if cp >= 0 && cp < len(f.low) {
        return f.low[cp]
    }
    atlas_glyph(f.atlas, cp)
}

// The end of the paragraph that starts at byte `start`: the index of the next '\n' or len(text).
priv fn para_end(text: str, start: i64) -> i64 {
    i := start
    while i < len(text) && text[i] != '\n' {
        i += 1
    }
    i
}

// Where the pen ends after a line, in atlas pixels (kerning included; '\r' skipped).
priv fn width_of(f: *GfxFont, s: str) -> f32 {
    x := f32(0.0)
    prev := -1
    i := 0
    while i < len(s) {
        cp, next := utf8_next(s, i)
        if cp != '\r' {
            ag := glyph_of(f, cp)
            if prev >= 0 {
                x += f32(kerning(f.atlas.font, prev, ag.glyph)) * f.atlas.scale
            }
            x += ag.advance
            prev = ag.glyph
        }
        i = next
    }
    x
}

// The line of a paragraph (no '\n') that starts at byte `start`, wrapped to max_w atlas pixels
// as std.font's wrap_text wraps: (end of the line without the spaces at the break, start of
// the next line; len(para) when this was the last). max_w <= 0: the whole paragraph.
priv fn break_line(f: *GfxFont, para: str, start: i64, max_w: f32) -> (i64, i64) {
    if max_w <= 0.0 {
        return (len(para), len(para))
    }
    x := f32(0.0)
    prev := -1
    space := -1             // the last space after something else on the line
    seen := false           // a character other than a space is on the line
    i := start
    loop {
        if i >= len(para) {
            return (len(para), len(para))
        }
        cp, next := utf8_next(para, i)
        ag := glyph_of(f, cp)
        if prev >= 0 {
            x += f32(kerning(f.atlas.font, prev, ag.glyph)) * f.atlas.scale
        }
        if cp == ' ' {
            if seen && (i == 0 || para[i - 1] != ' ') {
                space = i
            }
        } else {
            if x + ag.advance > max_w && i > start {
                break
            }
            seen = true
        }
        x += ag.advance
        prev = ag.glyph
        i = next
    }
    end := if space > start { space } else { i }
    e := end
    while e > start && para[e - 1] == ' ' {
        e -= 1
    }
    next := end
    while next < len(para) && para[next] == ' ' {
        next += 1
    }
    (e, next)
}

// The x of a line's left end for an alignment within a box of width w at x (w 0: around x).
priv fn line_x(f: *GfxFont, s: str, x: f32, w: f32, align: TextAlign) -> f32 {
    match align {
        AlignLeft => x
        AlignCenter => x + (w - width_of(f, s) * (f.size / f.atlas.px)) * 0.5
        AlignRight => x + w - width_of(f, s) * (f.size / f.atlas.px)
    }
}

// Draws one line (no '\n') with its pen starting at (x, baseline).
priv fn draw_line(g: *Gfx, f: *GfxFont, x: f32, baseline: f32, s: str, color: u32) {
    k := f.size / f.atlas.px
    m := g.xform
    // pen positions on whole target pixels, if the transform keeps the axes
    snap := m.x.y == 0.0 && m.y.x == 0.0 && m.x.x != 0.0 && m.y.y != 0.0
    inv := if snap { inverse(m) } else { m }
    pen := f32(0.0)
    prev := -1
    i := 0
    while i < len(s) {
        cp, next := utf8_next(s, i)
        i = next
        if cp == '\r' {
            continue
        }
        ag := glyph_of(f, cp)
        if prev >= 0 {
            pen += f32(kerning(f.atlas.font, prev, ag.glyph)) * f.atlas.scale
        }
        if ag.w > 0 && ag.h > 0 {
            p := vec2(x + pen * k, baseline)
            if snap {
                t := apply(m, p)
                p = apply(inv, vec2(floor(t.x + 0.5), floor(t.y + 0.5)))
            }
            g.sprite(f.tex, vec4(f32(ag.x), f32(ag.y), f32(ag.w), f32(ag.h)),
                vec4(p.x + f32(ag.xoff) * k, p.y + f32(ag.yoff) * k, f32(ag.w) * k, f32(ag.h) * k), color)
        }
        pen += ag.advance
        prev = ag.glyph
    }
}
