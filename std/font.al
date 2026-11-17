// std.font: TrueType / OpenType fonts with TrueType outlines, antialiased glyph rasterisation,
// glyph atlases and text layout. Everything is written in AL: no FreeType, no libc.
//
// Every offset and count read from the font is checked: a malformed font makes font_parse
// return an error, or a glyph come out empty, and never reads out of bounds. Units: the font's
// own units (units_per_em to the em) where a function says so, otherwise pixels; a size `px`
// is the em size in pixels (font_scale(f, px) = px / units_per_em). Layout coordinates have
// y growing downwards.
use std.image

// ---------- reading big-endian values, out of range reads give 0 ----------
priv inline fn rd8(d: []u8, i: i64) -> i64 {
    if i < 0 || i >= len(d) {
        return 0
    }
    i64(d[i])
}

priv inline fn rd16(d: []u8, i: i64) -> i64 {
    if i < 0 || i + 2 > len(d) {
        return 0
    }
    i64(d[i]) << 8 | i64(d[i + 1])
}

priv inline fn rds16(d: []u8, i: i64) -> i64 {
    v := rd16(d, i)
    if v >= 0x8000 { v - 0x10000 } else { v }
}

priv inline fn rd32(d: []u8, i: i64) -> i64 {
    if i < 0 || i + 4 > len(d) {
        return 0
    }
    i64(d[i]) << 24 | i64(d[i + 1]) << 16 | i64(d[i + 2]) << 8 | i64(d[i + 3])
}

// d[off..off + n], cut at the end of d; empty if off lies outside d
priv fn sub(d: []u8, off: i64, n: i64) -> []u8 {
    if off < 0 || n <= 0 || off >= len(d) {
        return nil
    }
    d[off..min(len(d), off + n)]
}

priv fn tag_is(d: []u8, i: i64, t: str) -> bool {
    i >= 0 && i + 4 <= len(d) && d[i..i + 4] == t
}

// ---------- the font ----------
// A parsed font. `data` is the whole file (kept, not copied); the slices are its tables.
// The metrics are in font units: ascent above the baseline (positive), descent below it
// (negative), line_gap the extra space between lines.
struct Font {
    data: []u8
    glyphs: i64              // number of glyphs
    units_per_em: i64
    ascent: i64
    descent: i64
    line_gap: i64
    long_loca: bool
    hmetrics: i64            // number of entries with an advance in hmtx
    loca: []u8
    glyf: []u8
    hmtx: []u8
    cmap: []u8               // the chosen subtable
    cmap_format: i64         // 4 or 12
    cmap_symbol: bool        // a Windows symbol font (Wingdings): code points 0..255 are found at U+F000..U+F0FF
    kern: []u8               // the pairs of a format 0 `kern` subtable (6 bytes each)
    gpos: [][][]u8           // per GPOS lookup of the `kern` feature: its pair adjustment subtables
}

// Pixel metrics of a font at an em size: ascent above the baseline (positive), descent below
// it (negative), line_gap, and line_height = ascent - descent + line_gap (baseline to baseline).
struct FontMetrics { ascent: f32, descent: f32, line_gap: f32, line_height: f32 }

// A glyph outline in font units, y up. The points of contour k are x[s..e], y[s..e], on[s..e]
// with s = ends[k - 1] (0 for k = 0), e = ends[k]; `on` tells on-curve points from the control
// points of quadratic curves.
struct Outline { x: Vec[f32], y: Vec[f32], on: Vec[bool], ends: Vec[i64] }

// A rasterised glyph: `img` holds the coverage (one channel, 0..255); (x, y) is where its top
// left corner goes relative to the pen position on the baseline, y down. Empty glyphs (space)
// have a 0 x 0 image.
struct GlyphBitmap { img: Image, x: i64, y: i64 }

priv const MAX_GLYPH_POINTS = 1 << 18    // a composite with more points is rejected
priv const MAX_COMPONENTS = 1 << 14      // components visited while loading one glyph
priv const MAX_DEPTH = 8                 // nesting of composite glyphs
priv const MAX_BITMAP = 1 << 13          // largest glyph bitmap side in pixels

// a table of the font at directory `dir`: (slice, found); found with an empty slice if it lies outside the file
priv fn table(data: []u8, dir: i64, n: i64, t: str) -> ([]u8, bool, bool) {
    for k in 0..n {
        r := dir + 12 + 16 * k
        if tag_is(data, r, t) {
            off := rd32(data, r + 8)
            size := rd32(data, r + 12)
            if off + size > len(data) || off >= len(data) {
                return (nil, true, false)
            }
            return (data[off..off + size], true, true)
        }
    }
    (nil, false, false)
}

// Parses a .ttf / .otf font (with TrueType outlines), or the first font of a .ttc collection.
// Returns "" or what is wrong. The font refers to `data`, which must stay alive.
fn font_parse(data: []u8) -> (Font, str) {
    font_parse(data, 0)
}

// Parses font number `index` of a .ttc collection (index 0 for a single font file).
fn font_parse(data: []u8, index: i64) -> (Font, str) {
    f := Font{data: data}
    if len(data) < 12 {
        return (f, "font: file too short")
    }
    dir := 0
    if tag_is(data, 0, "ttcf") {
        count := rd32(data, 8)
        if index < 0 || index >= count || 12 + 4 * index + 4 > len(data) {
            return (f, fmt("font: the collection has no font ", index))
        }
        dir = rd32(data, 12 + 4 * index)
        if dir + 12 > len(data) {
            return (f, "font: collection entry outside the file")
        }
    } else if index != 0 {
        return (f, fmt("font: not a collection, no font ", index))
    }
    version := rd32(data, dir)
    if tag_is(data, dir, "OTTO") {
        return (f, "font: CFF (PostScript) outlines are not supported, only TrueType outlines (glyf)")
    }
    if version != 0x00010000 && !tag_is(data, dir, "true") {
        return (f, "font: not a TrueType or OpenType font")
    }
    n := rd16(data, dir + 4)
    if dir + 12 + 16 * n > len(data) {
        return (f, "font: table directory cut off")
    }
    head, has_head, head_ok := table(data, dir, n, "head")
    maxp, has_maxp, maxp_ok := table(data, dir, n, "maxp")
    hhea, has_hhea, hhea_ok := table(data, dir, n, "hhea")
    hmtx, has_hmtx, hmtx_ok := table(data, dir, n, "hmtx")
    loca, has_loca, loca_ok := table(data, dir, n, "loca")
    glyf, has_glyf, glyf_ok := table(data, dir, n, "glyf")
    cmap, has_cmap, cmap_ok := table(data, dir, n, "cmap")
    kern, _, kern_ok := table(data, dir, n, "kern")
    gpos, _, gpos_ok := table(data, dir, n, "GPOS")
    if !has_glyf {
        _, cff, _ := table(data, dir, n, "CFF ")
        _, cff2, _ := table(data, dir, n, "CFF2")
        if cff || cff2 {
            return (f, "font: CFF (PostScript) outlines are not supported, only TrueType outlines (glyf)")
        }
    }
    names := []str{"head", "maxp", "hhea", "hmtx", "loca", "glyf", "cmap"}
    has := []bool{has_head, has_maxp, has_hhea, has_hmtx, has_loca, has_glyf, has_cmap}
    ok := []bool{head_ok, maxp_ok, hhea_ok, hmtx_ok, loca_ok, glyf_ok, cmap_ok}
    for k in 0..len(names) {
        if !has[k] {
            return (f, fmt("font: no '", names[k], "' table"))
        }
        if !ok[k] {
            return (f, fmt("font: the '", names[k], "' table lies outside the file"))
        }
    }
    if len(head) < 54 || rd32(head, 12) != 0x5F0F3CF5 {
        return (f, "font: bad 'head' table")
    }
    f.units_per_em = rd16(head, 18)
    if f.units_per_em < 16 || f.units_per_em > 16384 {
        return (f, "font: bad units per em")
    }
    loc_format := rds16(head, 50)
    if loc_format != 0 && loc_format != 1 {
        return (f, "font: bad 'loca' format")
    }
    f.long_loca = loc_format == 1
    if len(maxp) < 6 {
        return (f, "font: bad 'maxp' table")
    }
    f.glyphs = rd16(maxp, 4)
    if f.glyphs < 1 {
        return (f, "font: no glyphs")
    }
    if len(hhea) < 36 {
        return (f, "font: bad 'hhea' table")
    }
    f.ascent = rds16(hhea, 4)
    f.descent = rds16(hhea, 6)
    f.line_gap = rds16(hhea, 8)
    f.hmetrics = min(rd16(hhea, 34), f.glyphs)
    if f.hmetrics < 1 || len(hmtx) < 4 * f.hmetrics {
        return (f, "font: bad 'hmtx' table")
    }
    f.hmtx = hmtx
    entry := if f.long_loca { 4 } else { 2 }
    if len(loca) < (f.glyphs + 1) * entry {
        return (f, "font: 'loca' table too short")
    }
    f.loca = loca
    f.glyf = glyf
    sub_cmap, format, symbol := choose_cmap(cmap)
    if format == 0 {
        return (f, "font: no Unicode character map (cmap format 4 or 12)")
    }
    f.cmap = sub_cmap
    f.cmap_format = format
    f.cmap_symbol = symbol
    if kern_ok {
        f.kern = kern_pairs(kern)
    }
    if gpos_ok {
        f.gpos = gpos_kern_lookups(gpos)
    }
    (f, "")
}

// Reads and parses a font file (see font_parse).
fn font_load(path: str) -> (Font, str) {
    data, ok := read_file(path)
    if !ok {
        f: Font
        return (f, fmt("font: cannot read ", path, ": ", error_text(io_error())))
    }
    font_parse(data)
}

// the best Unicode subtable of a cmap table, else a Windows symbol one: (subtable, format,
// symbol), format 0 if none
priv fn choose_cmap(cmap: []u8) -> ([]u8, i64, bool) {
    n := rd16(cmap, 2)
    best: []u8
    best_format := 0
    best_score := 0
    best_symbol := false
    for k in 0..n {
        r := 4 + 8 * k
        if r + 8 > len(cmap) {
            break
        }
        platform := rd16(cmap, r)
        encoding := rd16(cmap, r + 2)
        off := rd32(cmap, r + 4)
        unicode := platform == 0 || platform == 3 && (encoding == 1 || encoding == 10)
        symbol := platform == 3 && encoding == 0
        if !unicode && !symbol || off + 8 > len(cmap) {
            continue
        }
        format := rd16(cmap, off)
        score := 0
        st: []u8
        if format == 4 {
            st = sub(cmap, off, rd16(cmap, off + 2))
            seg2 := rd16(st, 6)
            if seg2 >= 2 && seg2 % 2 == 0 && 16 + 4 * seg2 <= len(st) {
                score = if symbol { 1 } else { 2 }
            }
        } else if format == 12 && !symbol {
            st = sub(cmap, off, rd32(cmap, off + 4))
            groups := rd32(st, 12)
            if len(st) >= 16 && 16 + 12 * groups <= len(st) {
                score = 3
            }
        }
        if score > best_score {
            best = st
            best_format = format
            best_score = score
            best_symbol = symbol
        }
    }
    (best, best_format, best_symbol)
}

// Glyph index of a Unicode code point; 0 (the "missing" glyph) if the font has none. In a
// Windows symbol font (Wingdings, Webdings) the characters 0..255 are those of the font's
// own encoding.
fn glyph_index(f: Font, cp: i64) -> i64 {
    if f.cmap_symbol && cp >= 0 && cp < 0x100 {
        g := lookup(f, 0xF000 + cp)
        if g != 0 {
            return g
        }
    }
    lookup(f, cp)
}

priv fn lookup(f: Font, cp: i64) -> i64 {
    g := 0
    c := f.cmap
    if f.cmap_format == 4 {
        if cp < 0 || cp > 0xFFFF {
            return 0
        }
        seg2 := rd16(c, 6)
        // the first segment whose end code is >= cp
        lo := 0
        hi := seg2 / 2
        while lo < hi {
            mid := (lo + hi) / 2
            if rd16(c, 14 + 2 * mid) < cp { lo = mid + 1 } else { hi = mid }
        }
        if lo >= seg2 / 2 {
            return 0
        }
        start := rd16(c, 16 + seg2 + 2 * lo)
        if cp < start {
            return 0
        }
        delta := rd16(c, 16 + 2 * seg2 + 2 * lo)
        ro_at := 16 + 3 * seg2 + 2 * lo
        ro := rd16(c, ro_at)
        if ro == 0 {
            g = (cp + delta) & 0xFFFF
        } else {
            g = rd16(c, ro_at + ro + 2 * (cp - start))
            if g != 0 {
                g = (g + delta) & 0xFFFF
            }
        }
    } else if f.cmap_format == 12 {
        lo := 0
        hi := rd32(c, 12)
        while lo < hi {
            mid := (lo + hi) / 2
            r := 16 + 12 * mid
            if rd32(c, r + 4) < cp {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        r := 16 + 12 * lo
        if lo >= rd32(c, 12) || cp < rd32(c, r) {
            return 0
        }
        g = rd32(c, r + 8) + cp - rd32(c, r)
    }
    if g < 0 || g >= f.glyphs { 0 } else { g }
}

// Advance width of a glyph in font units.
fn glyph_advance(f: Font, glyph: i64) -> i64 {
    if glyph < 0 || glyph >= f.glyphs {
        return 0
    }
    k := min(glyph, f.hmetrics - 1)
    rd16(f.hmtx, 4 * k)
}

// Left side bearing of a glyph in font units.
fn glyph_lsb(f: Font, glyph: i64) -> i64 {
    if glyph < 0 || glyph >= f.glyphs {
        return 0
    }
    if glyph < f.hmetrics {
        return rds16(f.hmtx, 4 * glyph + 2)
    }
    rds16(f.hmtx, 4 * f.hmetrics + 2 * (glyph - f.hmetrics))
}

// The scale from font units to pixels for an em size of px pixels.
fn font_scale(f: Font, px: f32) -> f32 {
    px / f32(f.units_per_em)
}

// Vertical metrics in pixels for an em size of px pixels.
fn font_metrics(f: Font, px: f32) -> FontMetrics {
    s := font_scale(f, px)
    a := f32(f.ascent) * s
    d := f32(f.descent) * s
    g := f32(f.line_gap) * s
    FontMetrics{a, d, g, a - d + g}
}

// ---------- kerning ----------
priv fn kern_pairs(kern: []u8) -> []u8 {
    if rd16(kern, 0) != 0 || rd16(kern, 2) < 1 {
        return nil
    }
    // the first subtable: version, length, coverage (format in the high byte, bit 0 horizontal)
    coverage := rd16(kern, 8)
    if coverage >> 8 != 0 || coverage & 1 == 0 || coverage & 4 != 0 {
        return nil
    }
    pairs := rd16(kern, 10)
    sub(kern, 18, 6 * pairs)
}

// the subtables of the GPOS lookups that the `kern` feature uses (pair adjustment, also behind extensions)
priv fn gpos_kern_lookups(gpos: []u8) -> [][][]u8 {
    if rd16(gpos, 0) != 1 {
        return nil
    }
    features := sub(gpos, rd16(gpos, 6), len(gpos))
    lookups := sub(gpos, rd16(gpos, 8), len(gpos))
    nlookups := rd16(lookups, 0)
    used := alloc[bool](nlookups)
    for k in 0..rd16(features, 0) {
        r := 2 + 6 * k
        if r + 6 > len(features) {
            break
        }
        if !tag_is(features, r, "kern") {
            continue
        }
        feat := sub(features, rd16(features, r + 4), len(features))
        for j in 0..rd16(feat, 2) {
            if 4 + 2 * j + 2 > len(feat) {
                break
            }
            li := rd16(feat, 4 + 2 * j)
            if li < nlookups {
                used[li] = true
            }
        }
    }
    out := vec[[][]u8]()
    for li in 0..nlookups {
        if !used[li] {
            continue
        }
        lk := sub(lookups, rd16(lookups, 2 + 2 * li), len(lookups))
        kind := rd16(lk, 0)
        subs := vec[[]u8]()
        for k in 0..rd16(lk, 4) {
            if 6 + 2 * k + 2 > len(lk) {
                break
            }
            st := sub(lk, rd16(lk, 6 + 2 * k), len(lk))
            if kind == 9 {
                if rd16(st, 0) != 1 || rd16(st, 2) != 2 {
                    continue
                }
                st = sub(st, rd32(st, 4), len(st))
            } else if kind != 2 {
                continue
            }
            format := rd16(st, 0)
            if format == 1 || format == 2 {
                subs.push(st)
            }
        }
        if subs.len > 0 {
            out.push(subs.items())
        }
    }
    out.items()
}

// coverage index of a glyph in a coverage table, or -1
priv fn coverage(c: []u8, g: i64) -> i64 {
    format := rd16(c, 0)
    n := rd16(c, 2)
    lo := 0
    hi := n
    if format == 1 {
        while lo < hi {
            mid := (lo + hi) / 2
            v := rd16(c, 4 + 2 * mid)
            if v == g {
                return mid
            }
            if v < g { lo = mid + 1 } else { hi = mid }
        }
    } else if format == 2 {
        while lo < hi {
            mid := (lo + hi) / 2
            r := 4 + 6 * mid
            if g < rd16(c, r) {
                hi = mid
            } else if g > rd16(c, r + 2) {
                lo = mid + 1
            } else {
                return rd16(c, r + 4) + g - rd16(c, r)
            }
        }
    }
    -1
}

// class of a glyph in a class definition table (0 if it is not listed)
priv fn class_of(c: []u8, g: i64) -> i64 {
    format := rd16(c, 0)
    if format == 1 {
        start := rd16(c, 2)
        if g >= start && g - start < rd16(c, 4) {
            return rd16(c, 6 + 2 * (g - start))
        }
    } else if format == 2 {
        lo := 0
        hi := rd16(c, 2)
        while lo < hi {
            mid := (lo + hi) / 2
            r := 4 + 6 * mid
            if g < rd16(c, r) {
                hi = mid
            } else if g > rd16(c, r + 2) {
                lo = mid + 1
            } else {
                return rd16(c, r + 4)
            }
        }
    }
    0
}

// size of a GPOS value record in bytes, and the offset of its x advance (-1: none)
priv fn value_layout(format: i64) -> (i64, i64) {
    size := popcnt(format & 0xFF) * 2
    if format & 4 == 0 {
        return (size, -1)
    }
    (size, popcnt(format & 3) * 2)
}

// the x advance adjustment of a pair adjustment subtable for (a, b), and whether it applies
priv fn pair_adjust(st: []u8, a: i64, b: i64) -> (i64, bool) {
    ci := coverage(sub(st, rd16(st, 2), len(st)), a)
    if ci < 0 {
        return (0, false)
    }
    size1, xadv := value_layout(rd16(st, 4))
    size2, _ := value_layout(rd16(st, 6))
    if rd16(st, 0) == 1 {
        if ci >= rd16(st, 8) {
            return (0, false)
        }
        set := sub(st, rd16(st, 10 + 2 * ci), len(st))
        rec := 2 + size1 + size2
        lo := 0
        hi := rd16(set, 0)
        while lo < hi {
            mid := (lo + hi) / 2
            r := 2 + rec * mid
            v := rd16(set, r)
            if v == b {
                if xadv < 0 {
                    return (0, true)
                }
                return (rds16(set, r + 2 + xadv), true)
            }
            if v < b { lo = mid + 1 } else { hi = mid }
        }
        return (0, false)
    }
    c1 := class_of(sub(st, rd16(st, 8), len(st)), a)
    c2 := class_of(sub(st, rd16(st, 10), len(st)), b)
    n1 := rd16(st, 12)
    n2 := rd16(st, 14)
    if c1 >= n1 || c2 >= n2 {
        return (0, false)
    }
    if xadv < 0 {
        return (0, true)
    }
    (rds16(st, 16 + (c1 * n2 + c2) * (size1 + size2) + xadv), true)
}

// Kerning between two glyphs in font units (added to the advance of `left`): from the GPOS
// `kern` feature (pair adjustment, formats 1 and 2) if the font has one, else from a format 0
// `kern` table.
fn kerning(f: Font, left: i64, right: i64) -> i64 {
    if len(f.gpos) > 0 {
        total := 0
        for subs in f.gpos {
            for st in subs {
                v, applies := pair_adjust(st, left, right)
                if applies {
                    total += v
                    break
                }
            }
        }
        return total
    }
    key := left << 16 | right
    lo := 0
    hi := len(f.kern) / 6
    while lo < hi {
        mid := (lo + hi) / 2
        k := rd32(f.kern, 6 * mid)
        if k == key {
            return rds16(f.kern, 6 * mid + 4)
        }
        if k < key { lo = mid + 1 } else { hi = mid }
    }
    0
}

// ---------- outlines ----------
// the bytes of a glyph in glyf: (data, ok); empty for a glyph without outline
priv fn glyph_data(f: Font, g: i64) -> ([]u8, bool) {
    if g < 0 || g >= f.glyphs {
        return (nil, false)
    }
    a := 0
    b := 0
    if f.long_loca {
        a = rd32(f.loca, 4 * g)
        b = rd32(f.loca, 4 * g + 4)
    } else {
        a = rd16(f.loca, 2 * g) * 2
        b = rd16(f.loca, 2 * g + 2) * 2
    }
    if b == a {
        return (nil, true)
    }
    if b < a || b > len(f.glyf) {
        return (nil, false)
    }
    (f.glyf[a..b], true)
}

priv inline fn f2dot14(d: []u8, i: i64) -> f32 {
    f32(rds16(d, i)) / 16384.0
}

priv fn load(f: Font, g: i64, depth: i64, budget: *i64) -> (Outline, bool) {
    out: Outline
    d, ok := glyph_data(f, g)
    if !ok {
        return (out, false)
    }
    if len(d) == 0 {
        return (out, true)
    }
    if len(d) < 10 {
        return (out, false)
    }
    nc := rds16(d, 0)
    if nc >= 0 {
        return simple(d, nc)
    }
    if depth >= MAX_DEPTH {
        return (out, false)
    }
    p := 10
    loop {
        *budget -= 1
        if *budget < 0 || p + 4 > len(d) {
            return (out, false)
        }
        flags := rd16(d, p)
        child := rd16(d, p + 2)
        p += 4
        a1 := 0
        a2 := 0
        xy := flags & 2 != 0
        if flags & 1 != 0 {
            if p + 4 > len(d) {
                return (out, false)
            }
            a1 = if xy { rds16(d, p) } else { rd16(d, p) }
            a2 = if xy { rds16(d, p + 2) } else { rd16(d, p + 2) }
            p += 4
        } else {
            if p + 2 > len(d) {
                return (out, false)
            }
            a1 = rd8(d, p)
            a2 = rd8(d, p + 1)
            if xy {
                a1 = i64(i8(a1))
                a2 = i64(i8(a2))
            }
            p += 2
        }
        ta := f32(1.0)
        tb := f32(0.0)
        tc := f32(0.0)
        td := f32(1.0)
        if flags & 8 != 0 {
            if p + 2 > len(d) {
                return (out, false)
            }
            ta = f2dot14(d, p)
            td = ta
            p += 2
        } else if flags & 0x40 != 0 {
            if p + 4 > len(d) {
                return (out, false)
            }
            ta = f2dot14(d, p)
            td = f2dot14(d, p + 2)
            p += 4
        } else if flags & 0x80 != 0 {
            if p + 8 > len(d) {
                return (out, false)
            }
            ta = f2dot14(d, p)
            tb = f2dot14(d, p + 2)
            tc = f2dot14(d, p + 4)
            td = f2dot14(d, p + 6)
            p += 8
        }
        part, good := load(f, child, depth + 1, budget)
        if !good {
            return (out, false)
        }
        for i in 0..part.x.len {
            x := part.x[i]
            y := part.y[i]
            part.x[i] = ta * x + tc * y
            part.y[i] = tb * x + td * y
        }
        dx := f32(0.0)
        dy := f32(0.0)
        if xy {
            dx = f32(a1)
            dy = f32(a2)
            if flags & 0x800 != 0 && flags & 0x1000 == 0 {
                dx = ta * f32(a1) + tc * f32(a2)
                dy = tb * f32(a1) + td * f32(a2)
            }
        } else {
            // point matching: point a1 of the glyph so far meets point a2 of the component
            if a1 >= out.x.len || a2 >= part.x.len {
                return (out, false)
            }
            dx = out.x[a1] - part.x[a2]
            dy = out.y[a1] - part.y[a2]
        }
        base := out.x.len
        if base + part.x.len > MAX_GLYPH_POINTS {
            return (out, false)
        }
        for i in 0..part.x.len {
            out.x.push(part.x[i] + dx)
            out.y.push(part.y[i] + dy)
            out.on.push(part.on[i])
        }
        for e in part.ends {
            out.ends.push(base + e)
        }
        if flags & 0x20 == 0 {
            break
        }
    }
    (out, true)
}

// a simple glyph with nc contours
priv fn simple(d: []u8, nc: i64) -> (Outline, bool) {
    out: Outline
    p := 10 + 2 * nc
    if p + 2 > len(d) {
        return (out, false)
    }
    prev := -1
    for k in 0..nc {
        e := rd16(d, 10 + 2 * k)
        if e <= prev {
            return (out, false)
        }
        prev = e
        out.ends.push(e + 1)
    }
    npts := prev + 1
    p += 2 + rd16(d, p)
    flags := alloc[u8](npts)
    i := 0
    while i < npts {
        if p >= len(d) {
            return (out, false)
        }
        fl := d[p]
        p += 1
        flags[i] = fl
        i += 1
        if fl & 8 != 0 {
            if p >= len(d) {
                return (out, false)
            }
            r := i64(d[p])
            p += 1
            if i + r > npts {
                return (out, false)
            }
            for _ in 0..r {
                flags[i] = fl
                i += 1
            }
        }
    }
    out.x.reserve(npts)
    out.y.reserve(npts)
    out.on.reserve(npts)
    v := 0
    for k in 0..npts {
        fl := flags[k]
        if fl & 2 != 0 {
            if p >= len(d) {
                return (out, false)
            }
            dv := i64(d[p])
            p += 1
            v += if fl & 16 != 0 { dv } else { -dv }
        } else if fl & 16 == 0 {
            if p + 2 > len(d) {
                return (out, false)
            }
            v += rds16(d, p)
            p += 2
        }
        out.x.push(f32(v))
        out.on.push(fl & 1 != 0)
    }
    v = 0
    for k in 0..npts {
        fl := flags[k]
        if fl & 4 != 0 {
            if p >= len(d) {
                return (out, false)
            }
            dv := i64(d[p])
            p += 1
            v += if fl & 32 != 0 { dv } else { -dv }
        } else if fl & 32 == 0 {
            if p + 2 > len(d) {
                return (out, false)
            }
            v += rds16(d, p)
            p += 2
        }
        out.y.push(f32(v))
    }
    (out, true)
}

// The outline of a glyph (composite glyphs resolved), and whether it could be read; a glyph
// without outline (a space) gives an empty one and true.
fn glyph_outline(f: Font, glyph: i64) -> (Outline, bool) {
    budget := MAX_COMPONENTS
    o, ok := load(f, glyph, 0, &budget)
    if !ok {
        empty: Outline
        return (empty, false)
    }
    (o, true)
}

// ---------- rasteriser ----------
// Line segments in pixel coordinates, 4 floats each (x0, y0, x1, y1).
priv struct Path { seg: Vec[f32] }

priv fn line(p: *Path, x0: f32, y0: f32, x1: f32, y1: f32) {
    p.seg.push(x0)
    p.seg.push(y0)
    p.seg.push(x1)
    p.seg.push(y1)
}

// a quadratic curve as straight lines, the fewer the flatter it is
priv fn quad(p: *Path, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32) {
    dx := x0 - 2.0 * x1 + x2
    dy := y0 - 2.0 * y1 + y2
    dd := dx * dx + dy * dy
    if dd < 0.333 {
        line(p, x0, y0, x2, y2)
        return
    }
    // n lines stay within |d| / (4 n^2) pixels of the curve: here within 0.05
    n := min(i64(ceil(sqrt(5.0 * sqrt(dd)))), 256)
    px := x0
    py := y0
    for i in 1..=n {
        t := f32(i) / f32(n)
        u := 1.0 - t
        qx := u * u * x0 + 2.0 * u * t * x1 + t * t * x2
        qy := u * u * y0 + 2.0 * u * t * y1 + t * t * y2
        line(p, px, py, qx, qy)
        px = qx
        py = qy
    }
}

// point k (modulo n) of the contour starting at s, in pixels
priv fn at(o: Outline, s: i64, n: i64, k: i64, scale: f32, sx: f32, sy: f32) -> (f32, f32, bool) {
    i := s + k % n
    (o.x[i] * scale + sx, -o.y[i] * scale + sy, o.on[i])
}

// the outline as line segments in pixels: x * scale + sx, -y * scale + sy
priv fn flatten(o: Outline, scale: f32, sx: f32, sy: f32) -> Path {
    p: Path
    s := 0
    for e in o.ends {
        n := e - s
        if n >= 2 {
            first := -1
            for k in 0..n {
                if o.on[s + k] {
                    first = k
                    break
                }
            }
            x0 := f32(0.0)
            y0 := f32(0.0)
            begin := 0
            if first >= 0 {
                x0, y0, _ = at(o, s, n, first, scale, sx, sy)
                begin = first + 1
            } else {
                ax, ay, _ := at(o, s, n, 0, scale, sx, sy)
                qbx, qby, _ := at(o, s, n, 1, scale, sx, sy)
                x0 = (ax + qbx) * 0.5
                y0 = (ay + qby) * 0.5
                begin = 1
            }
            cx := x0
            cy := y0
            has := false
            qx := f32(0.0)
            qy := f32(0.0)
            for k in begin..begin + n {
                // the point after the last is the start again (for first < 0: point 0, a control point)
                if first >= 0 && k == begin + n - 1 {
                    break
                }
                px, py, on := at(o, s, n, k, scale, sx, sy)
                if on {
                    if has { quad(&p, cx, cy, qx, qy, px, py) } else { line(&p, cx, cy, px, py) }
                    cx = px
                    cy = py
                    has = false
                } else {
                    if has {
                        mx := (qx + px) * 0.5
                        my := (qy + py) * 0.5
                        quad(&p, cx, cy, qx, qy, mx, my)
                        cx = mx
                        cy = my
                    }
                    qx = px
                    qy = py
                    has = true
                }
            }
            if has { quad(&p, cx, cy, qx, qy, x0, y0) } else { line(&p, cx, cy, x0, y0) }
        }
        s = e
    }
    p
}

// Accumulates the signed area each line covers in every pixel; a running sum then gives the
// coverage (the method of font-rs). a has w * h + 2 cells; coordinates lie in [0, w] x [0, h].
priv fn draw_line(a: []f32, w: i64, h: i64, x0: f32, y0: f32, x1: f32, y1: f32) {
    if y0 == y1 {
        return
    }
    dir := f32(1.0)
    if y0 > y1 {
        dir = -1.0
        swap(&x0, &x1)
        swap(&y0, &y1)
    }
    dxdy := (x1 - x0) / (y1 - y0)
    if !(fabs(dxdy) < 1.0e20) {
        return              // nearly horizontal (or not a number): covers no area
    }
    fw := f32(w)
    x := x0
    ytop := i64(y0)
    yend := min(h, i64(ceil(y1)))
    for y in ytop..yend {
        row := y * w
        dy := fmin(f32(y + 1), y1) - fmax(f32(y), y0)
        // (rounding may carry x a little past the ends of the line: keep it in the bitmap)
        xnext := fmin(fmax(x + dxdy * dy, 0.0), fw)
        d := dy * dir
        xa := fmin(x, xnext)
        xb := fmax(x, xnext)
        xaf := floor(xa)
        xai := i64(xaf)
        xbc := ceil(xb)
        xbi := i64(xbc)
        if xbi <= xai + 1 {
            xm := 0.5 * (x + xnext) - xaf
            a[row + xai] += d - d * xm
            a[row + xai + 1] += d * xm
        } else {
            s := 1.0 / (xb - xa)
            xf := xa - xaf
            a0 := 0.5 * s * (1.0 - xf) * (1.0 - xf)
            xbf := xb - xbc + 1.0
            am := 0.5 * s * xbf * xbf
            a[row + xai] += d * a0
            if xbi == xai + 2 {
                a[row + xai + 1] += d * (1.0 - a0 - am)
            } else {
                a1 := s * (1.5 - xf)
                a[row + xai + 1] += d * (a1 - a0)
                for xi in xai + 2..xbi - 1 {
                    a[row + xi] += d * s
                }
                a2 := a1 + f32(xbi - xai - 3) * s
                a[row + xbi - 1] += d * (1.0 - a2 - am)
            }
            a[row + xbi] += d * am
        }
        x = xnext
    }
}

// Rasterises a glyph at `scale` (font_scale), its pen position moved right by shift_x and down
// by shift_y pixels (0..1, for subpixel placement). Antialiased: each pixel holds the part of
// its area the glyph covers. A glyph that cannot be read, or larger than 8192 pixels on a
// side, comes out empty.
fn glyph_bitmap(f: Font, glyph: i64, scale: f32, shift_x: f32, shift_y: f32) -> GlyphBitmap {
    empty := GlyphBitmap{img: Image{0, 0, 1, nil}}
    if !(scale > 0.0) || !(scale < 1.0e6) {
        return empty
    }
    o, ok := glyph_outline(f, glyph)
    if !ok || o.x.len == 0 {
        return empty
    }
    p := flatten(o, scale, shift_x, shift_y)
    n := p.seg.len / 4
    if n == 0 {
        return empty
    }
    minx := p.seg[0]
    maxx := minx
    miny := p.seg[1]
    maxy := miny
    for i in 0..p.seg.len / 2 {
        x := p.seg[2 * i]
        y := p.seg[2 * i + 1]
        minx = fmin(minx, x)
        maxx = fmax(maxx, x)
        miny = fmin(miny, y)
        maxy = fmax(maxy, y)
    }
    if !(maxx - minx < f32(MAX_BITMAP)) || !(maxy - miny < f32(MAX_BITMAP)) {
        return empty
    }
    ix := i64(floor(minx))
    iy := i64(floor(miny))
    w := i64(ceil(maxx)) - ix
    h := i64(ceil(maxy)) - iy
    if w <= 0 || h <= 0 {
        return empty
    }
    a := alloc[f32](w * h + 2)
    fw := f32(w)
    fh := f32(h)
    ox := f32(ix)
    oy := f32(iy)
    for k in 0..n {
        x0 := fmin(fmax(p.seg[4 * k] - ox, 0.0), fw)
        y0 := fmin(fmax(p.seg[4 * k + 1] - oy, 0.0), fh)
        x1 := fmin(fmax(p.seg[4 * k + 2] - ox, 0.0), fw)
        y1 := fmin(fmax(p.seg[4 * k + 3] - oy, 0.0), fh)
        draw_line(a, w, h, x0, y0, x1, y1)
    }
    img := image_new(w, h, 1)
    acc := f32(0.0)
    for i in 0..w * h {
        acc += a[i]
        v := fmin(fabs(acc), 1.0)
        img.pix[i] = u8(i64(v * 255.0 + 0.5))
    }
    GlyphBitmap{img, ix, iy}
}

// The same without a shift.
fn glyph_bitmap(f: Font, glyph: i64, scale: f32) -> GlyphBitmap {
    glyph_bitmap(f, glyph, scale, 0.0, 0.0)
}

// ---------- UTF-8 ----------
// The code point starting at byte i of s and the index after it; a malformed sequence gives
// U+FFFD and advances one byte.
fn utf8_next(s: str, i: i64) -> (i64, i64) {
    c := i64(s[i])
    if c < 0x80 {
        return (c, i + 1)
    }
    n := 0
    cp := 0
    lo := 0
    if c >= 0xC2 && c <= 0xDF {
        n = 1
        cp = c & 0x1F
        lo = 0x80
    } else if c >= 0xE0 && c <= 0xEF {
        n = 2
        cp = c & 0x0F
        lo = 0x800
    } else if c >= 0xF0 && c <= 0xF4 {
        n = 3
        cp = c & 0x07
        lo = 0x10000
    } else {
        return (0xFFFD, i + 1)
    }
    if i + n >= len(s) {
        return (0xFFFD, i + 1)
    }
    for k in 1..=n {
        b := i64(s[i + k])
        if b & 0xC0 != 0x80 {
            return (0xFFFD, i + 1)
        }
        cp = cp << 6 | b & 0x3F
    }
    if cp < lo || cp > 0x10FFFF || cp >= 0xD800 && cp <= 0xDFFF {
        return (0xFFFD, i + 1)
    }
    (cp, i + n + 1)
}

// ---------- layout ----------
// A glyph placed by layout_text: the code point, its glyph, the pen position (x, y) on the
// baseline in pixels (y down; the first baseline is at the ascent), the byte index of the
// character in the text and its line number.
struct GlyphPos { cp: i64, glyph: i64, x: f32, y: f32, byte: i64, line: i64 }

// Positions of the characters of a UTF-8 text at an em size of px pixels, with kerning. '\n'
// starts a new line ('\r' is skipped); neither gets a position.
fn layout_text(f: Font, px: f32, text: str) -> []GlyphPos {
    s := font_scale(f, px)
    m := font_metrics(f, px)
    out := vec[GlyphPos]()
    x := f32(0.0)
    line := 0
    prev := -1
    i := 0
    while i < len(text) {
        cp, next := utf8_next(text, i)
        if cp == '\n' {
            line += 1
            x = 0.0
            prev = -1
        } else if cp != '\r' {
            g := glyph_index(f, cp)
            if prev >= 0 {
                x += f32(kerning(f, prev, g)) * s
            }
            out.push(GlyphPos{cp, g, x, m.ascent + f32(line) * m.line_height, i, line})
            x += f32(glyph_advance(f, g)) * s
            prev = g
        }
        i = next
    }
    out.items()
}

// Width in pixels of one line of text (up to the first '\n'): where the pen ends, with kerning.
fn line_width(f: Font, px: f32, text: str) -> f32 {
    s := font_scale(f, px)
    x := f32(0.0)
    prev := -1
    i := 0
    while i < len(text) {
        cp, next := utf8_next(text, i)
        if cp == '\n' {
            break
        }
        if cp != '\r' {
            g := glyph_index(f, cp)
            if prev >= 0 {
                x += f32(kerning(f, prev, g)) * s
            }
            x += f32(glyph_advance(f, g)) * s
            prev = g
        }
        i = next
    }
    x
}

// Size in pixels of a text with '\n' line breaks: the widest line, and the number of lines
// times the line height.
fn text_size(f: Font, px: f32, text: str) -> (f32, f32) {
    w := f32(0.0)
    parts := split(text, '\n')
    for part in parts {
        w = fmax(w, line_width(f, px, part))
    }
    (w, f32(len(parts)) * font_metrics(f, px).line_height)
}

// Breaks a text into lines no wider than max_w pixels: at '\n', and at spaces (the spaces at
// a break are dropped); a word wider than max_w is broken between characters. The lines are
// views of text. max_w <= 0: only the '\n' breaks.
fn wrap_text(f: Font, px: f32, text: str, max_w: f32) -> []str {
    out := vec[str]()
    s := font_scale(f, px)
    for para in split(text, '\n') {
        if max_w <= 0.0 {
            out.push(para)
            continue
        }
        start := 0
        loop {
            // the longest piece from start that fits
            x := f32(0.0)
            prev := -1
            space := -1             // the last space after something else on the line
            seen := false           // a character other than a space is on the line
            i := start
            over := false
            while i < len(para) {
                cp, next := utf8_next(para, i)
                g := glyph_index(f, cp)
                if prev >= 0 {
                    x += f32(kerning(f, prev, g)) * s
                }
                adv := f32(glyph_advance(f, g)) * s
                if cp == ' ' {
                    if seen && (i == 0 || para[i - 1] != ' ') {
                        space = i
                    }
                } else {
                    if x + adv > max_w && i > start {
                        over = true
                        break
                    }
                    seen = true
                }
                x += adv
                prev = g
                i = next
            }
            if !over {
                out.push(para[start..])
                break
            }
            end := i
            if space > start {
                end = space
            }
            out.push(trim_right(para[start..end], " "))
            start = end
            while start < len(para) && para[start] == ' ' {
                start += 1
            }
            if start >= len(para) {
                break
            }
        }
    }
    out.items()
}

// ---------- drawing into an image ----------
// blends a coverage value (0..255) of colour col into the pixel (x, y), if it is inside
priv fn blend(img: *Image, x: i64, y: i64, cov: u8, col: vec4) {
    if cov == 0 || x < 0 || y < 0 || x >= img.w || y >= img.h {
        return
    }
    a := f32(cov) / 255.0 * col.w
    i := (y * img.w + x) * img.channels
    p := img.pix
    fn mix(d: u8, c: f32, a: f32) -> u8 {
        v := f32(d) * (1.0 - a) + c * 255.0 * a + 0.5
        u8(i64(fmin(fmax(v, 0.0), 255.0)))
    }
    // with alpha in the image: the colour goes over it (straight alpha), its alpha grows
    ca := a
    if img.channels == 2 || img.channels == 4 {
        k := i + img.channels - 1
        da := f32(p[k]) / 255.0
        oa := a + da * (1.0 - a)
        ca = if oa > 0.0 { a / oa } else { 1.0 }
        p[k] = u8(i64(fmin(oa * 255.0 + 0.5, 255.0)))
    }
    if img.channels >= 3 {
        p[i] = mix(p[i], col.x, ca)
        p[i + 1] = mix(p[i + 1], col.y, ca)
        p[i + 2] = mix(p[i + 2], col.z, ca)
    } else {
        p[i] = mix(p[i], (col.x * 77.0 + col.y * 150.0 + col.z * 29.0) / 256.0, ca)
    }
}

// Draws text (UTF-8, '\n' breaks lines) into an image with its top left corner at (x, y), at an
// em size of px pixels, in colour col (components 0..1, alpha blends). Every glyph is
// rasterised at its subpixel position; for text drawn often, bake an Atlas.
fn draw_text(img: *Image, f: Font, px: f32, x: f32, y: f32, text: str, col: vec4) {
    m := mark()
    defer { release(m) }
    s := font_scale(f, px)
    for gp in layout_text(f, px, text) {
        gx := x + gp.x
        gy := y + gp.y
        ix := floor(gx)
        iy := floor(gy)
        b := glyph_bitmap(f, gp.glyph, s, gx - ix, gy - iy)
        ox := i64(ix) + b.x
        oy := i64(iy) + b.y
        for yy in 0..b.img.h {
            for xx in 0..b.img.w {
                blend(img, ox + xx, oy + yy, b.img.pix[yy * b.img.w + xx], col)
            }
        }
    }
}

// ---------- atlas ----------
// A glyph in an atlas: its rectangle (x, y, w, h) in the atlas image and in texture
// coordinates (u0, v0)-(u1, v1); where the rectangle's top left corner goes relative to the
// pen position on the baseline (xoff, yoff, y down); the pen advance in pixels.
struct AtlasGlyph {
    cp: i64
    glyph: i64
    x: i64
    y: i64
    w: i64
    h: i64
    xoff: i64
    yoff: i64
    advance: f32
    u0: f32
    v0: f32
    u1: f32
    v1: f32
}

// Glyphs of a font at one size, packed into one image: coverage in a 1-channel image, or
// white with the coverage as alpha in a 4-channel one.
struct Atlas {
    font: Font
    px: f32
    scale: f32
    metrics: FontMetrics
    img: Image
    glyphs: Map[i64, AtlasGlyph]   // by code point
    missing: AtlasGlyph            // glyph 0, for code points that are not in the atlas
}

// The code points first..last (inclusive), for atlas_build.
fn char_range(first: i64, last: i64) -> []i64 {
    out := vec[i64]()
    for c in first..=last {
        out.push(c)
    }
    out.items()
}

// Rasterises the glyphs of the code points `chars` (and glyph 0) at an em size of px pixels and
// packs them into an image `width` pixels wide and as high as needed, with 1 pixel between
// glyphs; channels 1 (coverage) or 4 (white RGB, coverage as alpha). Returns "" or what is wrong.
fn atlas_build(f: Font, px: f32, chars: []i64, width: i64, channels: i64) -> (Atlas, str) {
    a := Atlas{font: f, px: px, scale: font_scale(f, px), metrics: font_metrics(f, px)}
    if channels != 1 && channels != 4 {
        return (a, "atlas: channels must be 1 or 4")
    }
    if !(px > 0.0) || width < 1 || width > MAX_BITMAP * 4 {
        return (a, "atlas: bad size")
    }
    // the code points, without repeats; -1 stands for glyph 0
    cps := vec[i64]()
    cps.push(-1)
    seen := map[i64, bool]()
    for c in chars {
        if !seen.has(c) && c >= 0 {
            seen.set(c, true)
            cps.push(c)
        }
    }
    bms := vec[GlyphBitmap]()
    for c in cps {
        g := if c < 0 { 0 } else { glyph_index(f, c) }
        bms.push(glyph_bitmap(f, g, a.scale))
    }
    // shelves, tallest glyphs first
    order := vec[i64]()
    for k in 0..cps.len {
        order.push(k)
    }
    sort_by(order.items(), bms.items(), fn(b: []GlyphBitmap, i: i64, j: i64) -> bool {
        b[i].img.h > b[j].img.h || b[i].img.h == b[j].img.h && i < j
    })
    pos := alloc[(i64, i64)](cps.len)
    x := 1
    y := 1
    shelf := 0
    for k in order {
        b := bms[k]
        if b.img.w + 2 > width {
            return (a, fmt("atlas: a glyph is ", b.img.w, " pixels wide, wider than the atlas"))
        }
        if x + b.img.w + 1 > width {
            y += shelf + 1
            x = 1
            shelf = 0
        }
        pos[k] = (x, y)
        x += b.img.w + 1
        shelf = max(shelf, b.img.h)
    }
    height := y + shelf + 1
    a.img = image_new(width, height, channels)
    for k in 0..cps.len {
        b := bms[k]
        px0, py0 := pos[k]
        for yy in 0..b.img.h {
            for xx in 0..b.img.w {
                v := b.img.pix[yy * b.img.w + xx]
                i := ((py0 + yy) * width + px0 + xx) * channels
                if channels == 1 {
                    a.img.pix[i] = v
                } else {
                    a.img.pix[i] = 255
                    a.img.pix[i + 1] = 255
                    a.img.pix[i + 2] = 255
                    a.img.pix[i + 3] = v
                }
            }
        }
        c := cps[k]
        g := if c < 0 { 0 } else { glyph_index(f, c) }
        fw := f32(width)
        fh := f32(height)
        ag := AtlasGlyph{
            cp: c, glyph: g, x: px0, y: py0, w: b.img.w, h: b.img.h, xoff: b.x, yoff: b.y,
            advance: f32(glyph_advance(f, g)) * a.scale,
            u0: f32(px0) / fw, v0: f32(py0) / fh,
            u1: f32(px0 + b.img.w) / fw, v1: f32(py0 + b.img.h) / fh,
        }
        if c < 0 {
            a.missing = ag
        } else {
            a.glyphs.set(c, ag)
        }
    }
    (a, "")
}

// The atlas glyph of a code point (the missing glyph if the atlas does not have it).
fn atlas_glyph(a: Atlas, cp: i64) -> AtlasGlyph {
    ag, ok := a.glyphs.get(cp)
    if ok { ag } else { a.missing }
}

// Draws text with the glyphs of an atlas (pen positions rounded to whole pixels), as
// draw_text with a font does.
fn draw_text(img: *Image, a: Atlas, x: f32, y: f32, text: str, col: vec4) {
    for gp in layout_text(a.font, a.px, text) {
        ag := atlas_glyph(a, gp.cp)
        ox := i64(floor(x + gp.x + 0.5)) + ag.xoff
        oy := i64(floor(y + gp.y + 0.5)) + ag.yoff
        ch := a.img.channels
        for yy in 0..ag.h {
            for xx in 0..ag.w {
                v := a.img.pix[((ag.y + yy) * a.img.w + ag.x + xx) * ch + ch - 1]
                blend(img, ox + xx, oy + yy, v, col)
            }
        }
    }
}
