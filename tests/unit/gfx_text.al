// std.gfx_text without a GPU: the glyph quads that draw_text gives the batcher, measuring,
// wrapping, alignment, missing glyphs, the size of a font against its raster size, rounding to
// target pixels under a transform, and that drawing allocates nothing. No backend is used:
// `texture` and `free_texture` are the test's own (std.gfx_text calls whatever backend the
// program has), recording into the batcher of std.gfx_core as tests/unit/gfx_batch.al does.
// The pixels themselves are tests/sys/gfx_text.al.
use std.gfx_core
use std.gfx_text

const FONT_DATA = embed("../std/data/font_test.ttf")

fn texture(g: *Gfx, img: Image, f: Filter) -> Texture {
    Texture{g.__gfx_tex_new(img.w, img.h, f, img.channels == 1, false), img.w, img.h}
}

fn free_texture(g: *Gfx, t: Texture) { g.texs[t.id].live = false }

fn test_font() -> Font {
    f, err := font_parse(FONT_DATA)
    assert err == "", err
    f
}

// A 200 x 100 Gfx without a GPU, recording a frame, and a font of the test font at px pixels.
fn recorder(px: f32) -> (*Gfx, GfxFont, Font) {
    g := __gfx_new(200, 100, GfxDesc{max_quads: 256, max_textures: 8})
    f := test_font()
    cs := vec_of(char_range(32, 126))
    cs.extend([]i64{0xC4, 0x1F600})
    font, err := gfx_font(g, f, px, cs.items())
    assert err == "", err
    __gfx_begin(g, alloc[GfxVertex](__gfx_max_vertices(GfxDesc{max_quads: 256})), 0xFF000000)
    (g, font, f)
}

// The top left corner of glyph quad n and its size.
fn quad(g: *Gfx, n: i64) -> vec4 {
    v := g.verts
    vec4(v[6 * n].pos.x, v[6 * n].pos.y, v[6 * n + 5].pos.x - v[6 * n].pos.x, v[6 * n + 5].pos.y - v[6 * n].pos.y)
}

fn near(a: f32, b: f32) -> bool { fabs(a - b) < 1e-3 }

test "a glyph quad per visible character, at the rounded pen position with kerning" {
    g, font, f := recorder(24.0)
    g.draw_text(font, 3.3, 2.0, "AV A", 0xFF00FFFF)
    assert g.nverts == 3 * 6, fmt(g.nverts)              // the space has no quad
    assert g.ncmds == 1 && i64(g.cmds[0].tex) == font.tex.id
    a := atlas_glyph(font.atlas, 'A')
    v := atlas_glyph(font.atlas, 'V')
    s := font_scale(f, 24.0)
    base := floor(2.0 + font_metrics(f, 24.0).ascent + 0.5)
    q := quad(g, 0)
    assert q == vec4(floor(3.3 + 0.5) + f32(a.xoff), base + f32(a.yoff), f32(a.w), f32(a.h)), fmt(q)
    // V after A: the advance of A and the A-V kerning of the font (-80 units)
    assert kerning(f, a.glyph, v.glyph) == -80
    pen := a.advance + f32(-80) * s
    q = quad(g, 1)
    assert q.x == floor(3.3 + pen + 0.5) + f32(v.xoff) && q.y == base + f32(v.yoff), fmt(q, " ", pen)
    // the texture coordinates are the glyph's rectangle in the atlas, the colour the tint
    uv := g.verts[6].uv
    assert near(uv.x, f32(v.x) / f32(font.tex.w)) && near(uv.y, f32(v.y) / f32(font.tex.h)) && g.verts[6].color == 0xFF00FFFF
}

test "measuring agrees with std.font" {
    _, font, f := recorder(20.0)
    for t in []str{"HoW VoH", "AVAWAV", "A\nVVV\n", "", "\xc3\x84A"} {
        assert text_size(font, t) == text_size(f, 20.0, t), t
    }
    para := "HAVo WoHA AVAW HoH VoW AH oVo WAHAV HoWAVo\nAVA  WoW   H"
    for w in []f32{30.0, 61.5, 110.0, 400.0} {
        lines := wrap_text(f, 20.0, para, w)
        assert text_size(font, para, w) == text_size(f, 20.0, join(lines, "\n")), fmt(w)
    }
    w, h := text_size(font, "AV\nH")
    assert h == 2.0 * line_height(font) && w == line_width(f, 20.0, "AV")
}

test "wrapping into a box: lines below the box are not drawn" {
    g, font, f := recorder(16.0)
    para := "HAVo WoHA AVAW HoH VoW AH oVo"
    lines := wrap_text(f, 16.0, para, 50.0)
    assert len(lines) > 3
    lh := line_height(font)
    h := g.draw_text_box(font, vec4(0.0, 0.0, 50.0, 0.0), para, 0xFFFFFFFF, AlignLeft)
    assert h == f32(len(lines)) * lh
    all := g.nverts
    glyphs := 0
    for c in join(lines, "") { if c != ' ' { glyphs += 1 } }
    assert all == glyphs * 6, fmt(all, " ", glyphs)
    h2 := g.draw_text_box(font, vec4(0.0, 0.0, 50.0, 2.5 * lh), para, 0xFFFFFFFF, AlignLeft)
    assert h2 == 2.0 * lh
    two := 0
    for c in concat(lines[0], lines[1]) { if c != ' ' { two += 1 } }
    assert g.nverts - all == two * 6
    // a box too low for one line draws nothing
    assert g.draw_text_box(font, vec4(0.0, 0.0, 50.0, 1.0), para, 0xFFFFFFFF, AlignLeft) == 0.0
}

test "alignment: lines end at x, or are centred on it, or in the box" {
    g, font, _ := recorder(20.0)
    h := atlas_glyph(font.atlas, 'H')
    g.draw_text(font, 100.0, 0.0, "H\nHH", 0xFFFFFFFF, AlignRight)
    // the pen ends at x: the last H starts one advance before it
    assert quad(g, 0).x == floor(100.0 - h.advance + 0.5) + f32(h.xoff)
    assert quad(g, 2).x == floor(100.0 - h.advance + 0.5) + f32(h.xoff)
    assert quad(g, 1).x == floor(100.0 - 2.0 * h.advance + 0.5) + f32(h.xoff)
    g.draw_text(font, 100.0, 0.0, "HH", 0xFFFFFFFF, AlignCenter)
    assert quad(g, 3).x == floor(100.0 - h.advance + 0.5) + f32(h.xoff)
    g.draw_text_box(font, vec4(10.0, 0.0, 80.0, 0.0), "HH", 0xFFFFFFFF, AlignCenter)
    assert quad(g, 5).x == floor(50.0 - h.advance + 0.5) + f32(h.xoff)
    g.draw_text_box(font, vec4(10.0, 0.0, 80.0, 0.0), "HH", 0xFFFFFFFF, AlignRight)
    assert quad(g, 7).x == floor(90.0 - 2.0 * h.advance + 0.5) + f32(h.xoff)
}

test "characters not in the atlas draw the missing glyph with its advance" {
    g, font, _ := recorder(24.0)
    m := font.atlas.missing
    assert m.glyph == 0 && m.w > 0
    g.draw_text(font, 0.0, 0.0, "Z\xe2\x82\xacH", 0xFFFFFFFF)      // Z: not in the font; the euro sign: not in the atlas
    assert g.nverts == 18
    v := g.verts
    assert near(v[0].uv.x, f32(m.x) / f32(font.tex.w)) && near(v[6].uv.x, f32(m.x) / f32(font.tex.w))
    h := atlas_glyph(font.atlas, 'H')
    assert quad(g, 2).x == floor(2.0 * m.advance + 0.5) + f32(h.xoff)
}

test "a font drawn at another size than its raster size" {
    g, font, _ := recorder(24.0)
    w, h := text_size(font, "AVH\nW")
    half := font
    half.size = 12.0
    w2, h2 := text_size(half, "AVH\nW")
    assert near(w2, w * 0.5) && near(h2, h * 0.5) && near(line_height(half), line_height(font) * 0.5)
    g.draw_text(half, 0.0, 0.0, "H", 0xFFFFFFFF)
    hg := atlas_glyph(font.atlas, 'H')
    q := quad(g, 0)
    assert near(q.z, f32(hg.w) * 0.5) && near(q.w, f32(hg.h) * 0.5)
}

test "pens are rounded to whole pixels of the target" {
    g, font, _ := recorder(24.0)
    half := font
    half.size = 12.0
    // a view scaled by 2 with an offset: the corners of the 24-pixel glyphs drawn at size 12
    // land on whole target pixels, wherever the text is
    g.set_transform(xform_mul(xform_translate(vec2(7.0, 3.0)), xform_scale(vec2(2.0))))
    g.draw_text(half, 1.37, 2.71, "AVAW HoV", 0xFFFFFFFF)
    for i in 0..g.nverts {
        p := g.verts[i].pos
        assert p.x == floor(p.x) && p.y == floor(p.y), fmt(i, " ", p)
    }
    // a turned transform is not rounded: the text turns smoothly
    g.set_transform(xform_rotate(0.3))
    n := g.nverts
    g.draw_text(font, 1.37, 2.71, "H", 0xFFFFFFFF)
    assert g.nverts == n + 6
}

test "drawing allocates nothing" {
    g, font, _ := recorder(16.0)
    before := mem_used()
    for i in 0..20 {
        g.draw_text(font, 1.0, 2.0, "AVAW\nHoV \xc3\x84\xf0\x9f\x98\x80", 0xFFFFFFFF, AlignCenter)
        g.draw_text_box(font, vec4(0.0, 0.0, 40.0, 60.0), "HAVo WoHA AVAW HoH", 0xFFFFFFFF, AlignRight)
        _, _ = text_size(font, "HAVo WoHA AVAW HoH", 40.0)
    }
    assert mem_used() == before, fmt(mem_used() - before)
}

test "adding characters, freeing, errors" {
    g := __gfx_new(200, 100, GfxDesc{max_textures: 8})
    f := test_font()
    font, err := gfx_font(g, f, 16.0, []i64{'A'})
    assert err == "" && font.atlas.glyphs.len == 1
    old := font.tex
    font.size = 8.0
    assert g.gfx_font_add(&font, []i64{'A', 'V', 'W'}) == ""
    assert font.atlas.glyphs.len == 3 && atlas_glyph(font.atlas, 'W').glyph == 8 && font.size == 8.0
    live := 0
    for t in g.texs { if t.live { live += 1 } }
    assert live == 2 && g.texs[font.tex.id].live && font.tex.w * font.tex.h >= old.w * old.h      // the white pixel and the new atlas
    assert g.gfx_font_add(&font, []i64{'V'}) == ""              // nothing new: nothing done
    gfx_font_free(g, font)
    assert !g.texs[font.tex.id].live
    _, e1 := gfx_font(g, f, 0.0, []i64{'A'})
    assert e1 != ""
    // many characters: the atlas grows wider and stays about square
    big, e2 := gfx_font(g, f, 40.0, char_range(32, 1000))
    assert e2 == "" && big.atlas.img.h <= big.atlas.img.w && big.atlas.img.channels == 1, fmt(e2, big.atlas.img.w, "x", big.atlas.img.h)
}
