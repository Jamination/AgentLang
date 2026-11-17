// std.font on the fonts of tests/gen/make_font.al: character maps (formats 4 and 12), metrics,
// kerning (GPOS and kern), outlines (simple, composite, nested, point matching) and the
// rasteriser. The glyph areas are those Windows' DirectWrite reports for the same files
// (System.Windows.Media.GlyphTypeface.GetGlyphOutline(...).GetArea(), at 1000 units), except
// for glyph 10, which DirectWrite leaves empty (it draws no composite of a composite); its
// area is that of glyph 9 plus the macron (15000), which it does not overlap.
use std.font

const AREAS = [_](i64, f64){(0, 100000.0), (2, 147000.0), (3, 127500.0), (4, 170000.0), (5, 133369.1),
    (6, 20000.0), (7, 15000.0), (8, 191250.0), (9, 167000.0), (10, 182000.0)}

fn load(name: str) -> Font {
    f, err := font_load(concat("tests/std/data/", name))
    assert err == "", err
    f
}

fn coverage_area(b: GlyphBitmap, scale: f32) -> f64 {
    total := 0
    for v in b.img.pix {
        total += i64(v)
    }
    f64(total) / 255.0 / f64(scale) / f64(scale)
}

fn main() {
    for name in []str{"font_test.ttf", "font_test_kern.ttf"} {
        f := load(name)
        print(name, "glyphs", f.glyphs, "em", f.units_per_em, "ascent", f.ascent, "descent", f.descent,
            "gap", f.line_gap, "cmap", f.cmap_format, "loca long", f.long_loca, "hmetrics", f.hmetrics)
        m := font_metrics(f, 50.0)
        print("  metrics at 50 px:", m.ascent, m.descent, m.line_gap, m.line_height)
        cps := []i64{' ', 'A', 'V', 'H', 'o', 'W', 0xA8, 0xAF, 0xC4, 0x1DE, 0x1F600, 'B', 0xFFFF, -1, 0x110000}
        idx := vec[i64]()
        for c in cps {
            idx.push(glyph_index(f, c))
        }
        print("  glyph indices:", idx[..])
        adv := vec[i64]()
        lsb := vec[i64]()
        for g in 0..f.glyphs + 1 {
            adv.push(glyph_advance(f, g))
            lsb.push(glyph_lsb(f, g))
        }
        print("  advances:", adv[..])
        print("  lsb:", lsb[..])
        A := 2
        V := 3
        H := 4
        W := 8
        AD := 9
        print("  kerning AV VA WA VAD WAD AA HV VH AW:", kerning(f, A, V), kerning(f, V, A), kerning(f, W, A),
            kerning(f, V, AD), kerning(f, W, AD), kerning(f, A, A), kerning(f, H, V), kerning(f, V, H), kerning(f, A, W))
        for g in 0..f.glyphs {
            o, ok := glyph_outline(f, g)
            print("  glyph", g, "outline", ok, "points", o.x.len, "contours", o.ends[..])
        }
        // the macron of glyph 10 is placed by point matching: its point 0 on the apex of A
        o10, _ := glyph_outline(f, 10)
        print("  glyph 10 macron at", o10.x[14], o10.y[14], o10.x[16], o10.y[16])
        o8, _ := glyph_outline(f, 8)
        print("  glyph 8 second V (scaled 1, 0.5):", o8.x[7], o8.y[7], o8.x[10], o8.y[10])
        // areas against DirectWrite, at 100 px (scale 0.1) and 37 px
        for px in []f32{100.0, 37.0} {
            s := font_scale(f, px)
            bad := 0
            for e in AREAS {
                a := coverage_area(glyph_bitmap(f, e.0, s), s)
                if fabs(a - e.1) > e.1 * 0.005 {
                    print("  area of glyph", e.0, "at", px, "px:", a, "expected", e.1)
                    bad += 1
                }
            }
            print("  areas at", px, "px within 0.5%:", bad == 0)
        }
        s := font_scale(f, 100.0)
        for g in 0..f.glyphs {
            b := glyph_bitmap(f, g, s)
            print("  bitmap", g, b.img.w, "x", b.img.h, "at", b.x, b.y)
        }
        // H at 100 px lies on pixel edges: stems and bar full, the notches empty, nothing between
        h := glyph_bitmap(f, H, s)
        p := h.img.pix
        between := 0
        for v in p {
            if v != 0 && v != 255 { between += 1 }
        }
        print("  H pixels: stem", p[5 * 50 + 5], "notch", p[10 * 50 + 20], "bar", p[35 * 50 + 20], "other values", between)
        // shifted by half a pixel the stem edges are half covered
        h2 := glyph_bitmap(f, H, s, 0.5, 0.0)
        print("  H shifted 0.5:", h2.img.w, h2.x, h2.img.pix[5 * 51], h2.img.pix[5 * 51 + 5], h2.img.pix[5 * 51 + 10])
    }
}
