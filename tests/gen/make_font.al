// Writes the test fonts of tests/std/font_*.al (run from the repository root):
//   build/alc run tests/gen/make_font.al
// tests/std/data/font_test.ttf       cmap formats 4 (3,1) and 12 (3,10), long loca, GPOS kerning
//                                    (a format 1 pair subtable, a format 2 class subtable behind
//                                    an extension lookup)
// tests/std/data/font_test_kern.ttf  cmap format 4 only, short loca, a `kern` table, fewer
//                                    hmtx advances than glyphs
// Both have the same 11 glyphs (units per em 1000, ascender 800, descender -200, line gap 100):
//  0 .notdef   rectangle with a rectangular hole      advance 500
//  1 space     no outline                             250
//  2 A         triangle with a triangular hole        520
//  3 V         polygon, 7 points                      500
//  4 H         polygon, 12 points                     600
//  5 o         quadratic curves: an outer contour of off-curve points only, an inner one of
//              mixed points; 2 bytes of instructions  500
//  6 dieresis  two squares (U+00A8)                   500
//  7 macron    a bar (U+00AF)                         500
//  8 W         composite: V, and V at x 400 scaled (1, 0.5), word arguments    900
//  9 Adieresis composite: A + dieresis at (10, 0), byte arguments (U+00C4)      520
// 10 U+01DE    composite of the composite 9 + macron placed by point matching   520
// U+1F600 maps to glyph 5 in the format 12 subtable only.
// Kerning (both fonts): A V -80, V A -70, W A -70, V Adieresis -70, W Adieresis -70.

priv fn p16(b: *Vec[u8], v: i64) {
    b.push(u8(v >> 8))
    b.push(u8(v))
}

priv fn p32(b: *Vec[u8], v: i64) {
    p16(b, v >> 16)
    p16(b, v)
}

priv fn set16(b: *Vec[u8], at: i64, v: i64) {
    b.buf[at] = u8(v >> 8)
    b.buf[at + 1] = u8(v)
}

priv fn pad4(b: *Vec[u8]) {
    while b.len % 4 != 0 {
        b.push(0)
    }
}

struct Pt { x: i64, y: i64, on: bool }

// a simple glyph from contours of points
priv fn simple(contours: [][]Pt, instructions: i64) -> []u8 {
    b := vec[u8]()
    all := vec[Pt]()
    for c in contours {
        all.extend(c)
    }
    x0 := all[0].x
    y0 := all[0].y
    x1 := x0
    y1 := y0
    for p in all {
        x0 = min(x0, p.x)
        y0 = min(y0, p.y)
        x1 = max(x1, p.x)
        y1 = max(y1, p.y)
    }
    p16(&b, len(contours))
    p16(&b, x0)
    p16(&b, y0)
    p16(&b, x1)
    p16(&b, y1)
    end := -1
    for c in contours {
        end += len(c)
        p16(&b, end)
    }
    p16(&b, instructions)
    for k in 0..instructions {
        b.push(u8(0xB0 + k))
    }
    // flags and coordinates: short vectors where they fit, repeated flags folded
    flags := vec[u8]()
    xs := vec[u8]()
    ys := vec[u8]()
    px := 0
    py := 0
    for p in all {
        fl := if p.on { 1 } else { 0 }
        dx := p.x - px
        dy := p.y - py
        if dx == 0 {
            fl |= 16
        } else if dx > -256 && dx < 256 {
            fl |= 2
            if dx > 0 { fl |= 16 }
            xs.push(u8(abs(dx)))
        } else {
            p16(&xs, dx)
        }
        if dy == 0 {
            fl |= 32
        } else if dy > -256 && dy < 256 {
            fl |= 4
            if dy > 0 { fl |= 32 }
            ys.push(u8(abs(dy)))
        } else {
            p16(&ys, dy)
        }
        flags.push(u8(fl))
        px = p.x
        py = p.y
    }
    i := 0
    while i < flags.len {
        r := 0
        while i + r + 1 < flags.len && flags[i + r + 1] == flags[i] && r < 255 {
            r += 1
        }
        if r >= 1 {
            b.push(flags[i] | 8)
            b.push(u8(r))
        } else {
            b.push(flags[i])
        }
        i += r + 1
    }
    b.extend(xs.items())
    b.extend(ys.items())
    b.items()
}

priv fn pts(xy: []i64, on: bool) -> []Pt {
    out := vec[Pt]()
    for k in 0..len(xy) / 2 {
        out.push(Pt{xy[2 * k], xy[2 * k + 1], on})
    }
    out.items()
}

priv fn glyphs() -> [][]u8 {
    gs := vec[[]u8]()
    // 0 .notdef: outer clockwise, hole counter-clockwise
    gs.push(simple([][]Pt{pts([]i64{50, 0, 50, 700, 450, 700, 450, 0}, true),
        pts([]i64{100, 50, 400, 50, 400, 650, 100, 650}, true)}, 0))
    gs.push([]u8{})                                                   // 1 space
    gs.push(simple([][]Pt{pts([]i64{0, 0, 250, 700, 500, 0}, true),
        pts([]i64{150, 100, 350, 100, 250, 380}, true)}, 0))          // 2 A
    gs.push(simple([][]Pt{pts([]i64{0, 700, 100, 700, 250, 150, 400, 700, 500, 700, 300, 0, 200, 0}, true)}, 0)) // 3 V
    gs.push(simple([][]Pt{pts([]i64{0, 0, 0, 700, 100, 700, 100, 400, 400, 400, 400, 700, 500, 700,
        500, 0, 400, 0, 400, 300, 100, 300, 100, 0}, true)}, 0))       // 4 H
    inner := []Pt{Pt{250, 100, true}, Pt{400, 100, false}, Pt{400, 250, true}, Pt{400, 400, false},
        Pt{250, 400, true}, Pt{100, 400, false}, Pt{100, 250, true}, Pt{100, 100, false}}
    gs.push(simple([][]Pt{pts([]i64{0, 0, 0, 500, 500, 500, 500, 0}, false), inner}, 2))   // 5 o
    gs.push(simple([][]Pt{pts([]i64{100, 800, 100, 900, 200, 900, 200, 800}, true),
        pts([]i64{300, 800, 300, 900, 400, 900, 400, 800}, true)}, 0))  // 6 dieresis
    gs.push(simple([][]Pt{pts([]i64{100, 950, 100, 1000, 400, 1000, 400, 950}, true)}, 0)) // 7 macron
    // 8 W: V at (0, 0), then V at (400, 0) scaled x 1, y 0.5; word arguments
    w := vec[u8]()
    p16(&w, -1)
    p16(&w, 0)
    p16(&w, 0)
    p16(&w, 900)
    p16(&w, 700)
    p16(&w, 0x0001 | 0x0002 | 0x0020)
    p16(&w, 3)
    p16(&w, 0)
    p16(&w, 0)
    p16(&w, 0x0001 | 0x0002 | 0x0040)
    p16(&w, 3)
    p16(&w, 400)
    p16(&w, 0)
    p16(&w, 0x4000)
    p16(&w, 0x2000)
    gs.push(w.items())
    // 9 Adieresis: A, then dieresis at (10, 0); byte arguments
    a := vec[u8]()
    p16(&a, -1)
    p16(&a, 0)
    p16(&a, 0)
    p16(&a, 500)
    p16(&a, 900)
    p16(&a, 0x0002 | 0x0020 | 0x0200)
    p16(&a, 2)
    a.push(0)
    a.push(0)
    p16(&a, 0x0002)
    p16(&a, 6)
    a.push(10)
    a.push(0)
    gs.push(a.items())
    // 10 U+01DE: glyph 9, then macron with its point 0 on point 1 of glyph 9 (the apex of A)
    m := vec[u8]()
    p16(&m, -1)
    p16(&m, 0)
    p16(&m, 0)
    p16(&m, 550)
    p16(&m, 900)
    p16(&m, 0x0002 | 0x0020)
    p16(&m, 9)
    m.push(0)
    m.push(0)
    p16(&m, 0)
    p16(&m, 7)
    m.push(1)
    m.push(0)
    gs.push(m.items())
    gs.items()
}

const ADVANCES = [11]i64{500, 250, 520, 500, 600, 500, 500, 500, 900, 520, 520}
const LSBS = [11]i64{50, 0, 0, 0, 0, 0, 100, 100, 0, 0, 0}

// (code point, glyph), sorted
const MAP = [_](i64, i64){(32, 1), (65, 2), (72, 4), (86, 3), (87, 8), (111, 5), (0xA8, 6), (0xAF, 7),
    (0xC4, 9), (0x1DE, 10)}

priv fn cmap(with12: bool) -> []u8 {
    // format 4: one segment per character, U+00C4 through glyphIdArray, then 0xFFFF
    segs := len(MAP) + 1
    f4 := vec[u8]()
    p16(&f4, 4)
    p16(&f4, 0)        // length, set below
    p16(&f4, 0)
    p16(&f4, segs * 2)
    sr := 2
    es := 0
    while sr * 2 <= segs * 2 {
        sr *= 2
        es += 1
    }
    p16(&f4, sr)
    p16(&f4, es - 1)
    p16(&f4, segs * 2 - sr)
    for e in MAP { p16(&f4, e.0) }
    p16(&f4, 0xFFFF)
    p16(&f4, 0)
    for e in MAP { p16(&f4, e.0) }
    p16(&f4, 0xFFFF)
    for e in MAP {
        p16(&f4, if e.0 == 0xC4 { 0 } else { (e.1 - e.0) & 0xFFFF })
    }
    p16(&f4, 1)
    for k, e in MAP {
        // idRangeOffset: from this entry to glyphIdArray[0]
        p16(&f4, if e.0 == 0xC4 { 2 * (segs - k) } else { 0 })
    }
    p16(&f4, 0)
    p16(&f4, 9)        // glyphIdArray[0]: glyph of U+00C4
    set16(&f4, 2, f4.len)
    f12 := vec[u8]()
    if with12 {
        p16(&f12, 12)
        p16(&f12, 0)
        p32(&f12, 16 + 12 * (len(MAP) + 1))
        p32(&f12, 0)
        p32(&f12, len(MAP) + 1)
        for e in MAP {
            p32(&f12, e.0)
            p32(&f12, e.0)
            p32(&f12, e.1)
        }
        p32(&f12, 0x1F600)
        p32(&f12, 0x1F600)
        p32(&f12, 5)
    }
    c := vec[u8]()
    n := if with12 { 2 } else { 1 }
    p16(&c, 0)
    p16(&c, n)
    p16(&c, 3)
    p16(&c, 1)
    p32(&c, 4 + 8 * n)
    if with12 {
        p16(&c, 3)
        p16(&c, 10)
        p32(&c, 4 + 8 * n + f4.len)
    }
    c.extend(f4.items())
    c.extend(f12.items())
    c.items()
}

priv fn kern_table() -> []u8 {
    pairs := [_](i64, i64, i64){(2, 3, -80), (3, 2, -70), (3, 9, -70), (8, 2, -70), (8, 9, -70)}
    k := vec[u8]()
    p16(&k, 0)
    p16(&k, 1)
    p16(&k, 0)
    p16(&k, 14 + 6 * len(pairs))
    p16(&k, 1)
    p16(&k, len(pairs))
    p16(&k, 4)
    p16(&k, 2)
    p16(&k, 24 - 24)
    for p in pairs {
        p16(&k, p.0)
        p16(&k, p.1)
        p16(&k, p.2)
    }
    k.items()
}

priv fn gpos_table() -> []u8 {
    // subtable 1: PairPos format 1, coverage [A], pair set {V: -80}, value format 1 = XAdvance
    s1 := vec[u8]()
    p16(&s1, 1)
    p16(&s1, 12)       // coverage
    p16(&s1, 4)
    p16(&s1, 0)
    p16(&s1, 1)
    p16(&s1, 18)       // pair set
    p16(&s1, 1)        // coverage format 1, 1 glyph: A
    p16(&s1, 1)
    p16(&s1, 2)
    p16(&s1, 1)        // pair set: 1 record
    p16(&s1, 3)
    p16(&s1, -80)
    // subtable 2: PairPos format 2, coverage format 2 [V], [W]; class 1 = {V, W}, class 2: {A, Adieresis} = 1
    s2 := vec[u8]()
    p16(&s2, 2)
    p16(&s2, 0)        // coverage, set below
    p16(&s2, 4)
    p16(&s2, 0)
    p16(&s2, 0)        // class def 1
    p16(&s2, 0)        // class def 2
    p16(&s2, 2)
    p16(&s2, 2)
    for v in []i64{0, 0, 0, -70} { p16(&s2, v) }
    set16(&s2, 2, s2.len)
    p16(&s2, 2)        // coverage format 2: ranges [3..3] index 0, [8..8] index 1
    p16(&s2, 2)
    for v in []i64{3, 3, 0, 8, 8, 1} { p16(&s2, v) }
    set16(&s2, 8, s2.len)
    p16(&s2, 1)        // class def format 1: glyphs 3..8
    p16(&s2, 3)
    p16(&s2, 6)
    for v in []i64{1, 0, 0, 0, 0, 1} { p16(&s2, v) }
    set16(&s2, 10, s2.len)
    p16(&s2, 2)        // class def format 2: [2..2] 1, [9..9] 1
    p16(&s2, 2)
    for v in []i64{2, 2, 1, 9, 9, 1} { p16(&s2, v) }
    g := vec[u8]()
    p32(&g, 0x00010000)
    p16(&g, 10)        // script list
    p16(&g, 30)        // feature list
    p16(&g, 46)        // lookup list
    // script list at 10: 1 script DFLT -> script at +8 -> default lang sys at +4
    p16(&g, 1)
    g.extend("DFLT")
    p16(&g, 8)
    p16(&g, 4)
    p16(&g, 0)
    p16(&g, 0)         // lang sys: lookup order
    p16(&g, 0xFFFF)
    p16(&g, 1)
    p16(&g, 0)
    // feature list at 30: 1 feature 'kern' -> feature at +8: lookups 0 and 1
    assert g.len == 30
    p16(&g, 1)
    g.extend("kern")
    p16(&g, 8)
    p16(&g, 0)
    p16(&g, 2)
    p16(&g, 0)
    p16(&g, 1)
    // lookup list at 46: 2 lookups
    assert g.len == 46
    p16(&g, 2)
    p16(&g, 6)
    p16(&g, 6 + 8 + len(s1))
    // lookup 0 (type 2, one subtable s1)
    p16(&g, 2)
    p16(&g, 0)
    p16(&g, 1)
    p16(&g, 8)
    g.extend(s1.items())
    // lookup 1 (type 9, one extension subtable -> s2)
    p16(&g, 9)
    p16(&g, 0)
    p16(&g, 1)
    p16(&g, 8)
    p16(&g, 1)
    p16(&g, 2)
    p32(&g, 8)
    g.extend(s2.items())
    g.items()
}

// OS/2 version 4, name and post version 3: not read by std.font, but other font software
// (Windows, to compare with) wants them
priv fn os2_table() -> []u8 {
    o := vec[u8]()
    p16(&o, 4)
    p16(&o, 500)
    p16(&o, 400)
    p16(&o, 5)
    p16(&o, 0)
    for v in []i64{650, 600, 0, 75, 650, 600, 0, 350, 50, 250} { p16(&o, v) }
    p16(&o, 0)
    for _ in 0..10 { o.push(0) }
    p32(&o, 15)                // Basic Latin, Latin-1 Supplement, Latin Extended-A and B
    p32(&o, 0)
    p32(&o, 0)
    p32(&o, 0)
    o.extend("NONE")
    p16(&o, 0x40)
    p16(&o, 32)
    p16(&o, 0xFFFF)
    p16(&o, 800)
    p16(&o, -200)
    p16(&o, 100)
    p16(&o, 1000)
    p16(&o, 200)
    p32(&o, 1)
    p32(&o, 0)
    p16(&o, 500)
    p16(&o, 700)
    p16(&o, 0)
    p16(&o, 32)
    p16(&o, 2)
    o.items()
}

priv fn name_table(family: str) -> []u8 {
    names := [_](i64, str){(1, family), (2, "Regular"), (4, family), (6, replace(family, " ", ""))}
    n := vec[u8]()
    p16(&n, 0)
    p16(&n, len(names))
    p16(&n, 6 + 12 * len(names))
    strings := vec[u8]()
    for e in names {
        p16(&n, 3)
        p16(&n, 1)
        p16(&n, 0x409)
        p16(&n, e.0)
        p16(&n, 2 * len(e.1))
        p16(&n, strings.len)
        for c in e.1 {
            strings.push(0)
            strings.push(c)
        }
    }
    n.extend(strings.items())
    n.items()
}

priv fn post_table() -> []u8 {
    p := vec[u8]()
    p32(&p, 0x00030000)
    p32(&p, 0)
    p16(&p, -100)
    p16(&p, 50)
    for _ in 0..5 { p32(&p, 0) }
    p.items()
}

priv fn checksum(t: []u8) -> i64 {
    s := 0
    for k in 0..(len(t) + 3) / 4 {
        w := 0
        for j in 0..4 {
            i := 4 * k + j
            w = w << 8 | (if i < len(t) { i64(t[i]) } else { 0 })
        }
        s = (s + w) & 0xFFFF_FFFF
    }
    s
}

priv fn font(main: bool) -> []u8 {
    gs := glyphs()
    long := main
    glyf := vec[u8]()
    loca := vec[u8]()
    for g in gs {
        if long { p32(&loca, glyf.len) } else { p16(&loca, glyf.len / 2) }
        glyf.extend(g)
        while glyf.len % 2 != 0 { glyf.push(0) }
    }
    if long { p32(&loca, glyf.len) } else { p16(&loca, glyf.len / 2) }
    nhm := if main { 11 } else { 10 }
    hmtx := vec[u8]()
    for k in 0..11 {
        if k < nhm { p16(&hmtx, ADVANCES[k]) }
        p16(&hmtx, LSBS[k])
    }
    head := vec[u8]()
    p32(&head, 0x00010000)
    p32(&head, 0x00010000)
    p32(&head, 0)              // checkSumAdjustment, set below
    p32(&head, 0x5F0F3CF5)
    p16(&head, 0x000B)
    p16(&head, 1000)
    for _ in 0..4 { p32(&head, 0) }
    p16(&head, 0)
    p16(&head, 0)
    p16(&head, 900)
    p16(&head, 1000)
    p16(&head, 0)
    p16(&head, 8)
    p16(&head, 2)
    p16(&head, if long { 1 } else { 0 })
    p16(&head, 0)
    hhea := vec[u8]()
    p32(&hhea, 0x00010000)
    p16(&hhea, 800)
    p16(&hhea, -200)
    p16(&hhea, 100)
    p16(&hhea, 900)
    p16(&hhea, 0)
    p16(&hhea, 0)
    p16(&hhea, 900)
    p16(&hhea, 1)
    for _ in 0..6 { p16(&hhea, 0) }
    p16(&hhea, 0)
    p16(&hhea, nhm)
    maxp := vec[u8]()
    p32(&maxp, 0x00010000)
    p16(&maxp, 11)
    for v in []i64{12, 2, 15, 5, 2, 0, 0, 0, 0, 2, 2, 2, 3} { p16(&maxp, v) }
    tables := vec[(str, []u8)]()
    if main {
        tables.push(("GPOS", gpos_table()))
    }
    tables.push(("OS/2", os2_table()))
    tables.push(("cmap", cmap(main)))
    tables.push(("glyf", glyf.items()))
    tables.push(("head", head.items()))
    tables.push(("hhea", hhea.items()))
    tables.push(("hmtx", hmtx.items()))
    if !main {
        tables.push(("kern", kern_table()))
    }
    tables.push(("loca", loca.items()))
    tables.push(("maxp", maxp.items()))
    tables.push(("name", name_table(if main { "AL Test" } else { "AL Test Kern" })))
    tables.push(("post", post_table()))
    n := tables.len
    out := vec[u8]()
    p32(&out, 0x00010000)
    p16(&out, n)
    sr := 1
    es := 0
    while sr * 2 <= n {
        sr *= 2
        es += 1
    }
    p16(&out, sr * 16)
    p16(&out, es)
    p16(&out, n * 16 - sr * 16)
    off := 12 + 16 * n
    head_at := 0
    for t in tables {
        out.extend(t.0)
        p32(&out, checksum(t.1))
        p32(&out, off)
        p32(&out, len(t.1))
        if t.0 == "head" { head_at = off }
        off += (len(t.1) + 3) / 4 * 4
    }
    for t in tables {
        out.extend(t.1)
        pad4(&out)
    }
    adj := (0xB1B0AFBA - checksum(out.items())) & 0xFFFF_FFFF
    set16(&out, head_at + 8, adj >> 16)
    set16(&out, head_at + 10, adj)
    out.items()
}

fn main() {
    assert write_file("tests/std/data/font_test.ttf", font(true)), "cannot write font_test.ttf"
    assert write_file("tests/std/data/font_test_kern.ttf", font(false)), "cannot write font_test_kern.ttf"
    print("wrote tests/std/data/font_test.ttf and font_test_kern.ttf")
}
