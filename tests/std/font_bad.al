// std.font on malformed fonts: damaged copies of tests/std/data/font_test*.ttf must be rejected
// by font_parse, or give empty glyphs, and never stop the program (no out-of-bounds index, no
// endless loop). Then every prefix of the files and 10000 randomly damaged copies are parsed and,
// when accepted, used for everything (outlines, bitmaps, kerning, layout, wrapping, an atlas).
use std.font

fn be16(d: []u8, i: i64) -> i64 { i64(d[i]) << 8 | i64(d[i + 1]) }
fn be32(d: []u8, i: i64) -> i64 { be16(d, i) << 16 | be16(d, i + 2) }
fn put16(d: []u8, i: i64, v: i64) {
    d[i] = u8(v >> 8)
    d[i + 1] = u8(v)
}
fn put32(d: []u8, i: i64, v: i64) {
    put16(d, i, v >> 16)
    put16(d, i + 2, v)
}

// offset of the directory record of a table
fn record(d: []u8, tag: str) -> i64 {
    for k in 0..be16(d, 4) {
        r := 12 + 16 * k
        if d[r..r + 4] == tag { return r }
    }
    panic(fmt("no table ", tag))
}

fn table(d: []u8, tag: str) -> i64 { be32(d, record(d, tag) + 8) }

// offset in the file of glyph g (long loca)
fn glyph_at(d: []u8, g: i64) -> i64 { table(d, "glyf") + be32(d, table(d, "loca") + 4 * g) }

// uses everything a font offers; returns a number that depends on all of it
fn exercise(f: Font) -> i64 {
    sum := 0
    s := font_scale(f, 16.0)
    for g in 0..min(f.glyphs, 24) {
        o, ok := glyph_outline(f, g)
        if ok { sum += o.x.len }
        b := glyph_bitmap(f, g, s, 0.25, 0.5)
        sum += b.img.w + b.img.h
        sum += glyph_advance(f, g) + glyph_lsb(f, g)
        for h in 0..min(f.glyphs, 12) {
            sum += kerning(f, g, h)
        }
    }
    text := "AVA W\xC3\x84 \xC7\x9E o H\nVAW \xF0\x9F\x98\x80 Ho"
    sum += len(layout_text(f, 16.0, text)) + len(wrap_text(f, 16.0, text, 40.0))
    sum += i64(line_width(f, 16.0, text))
    a, err := atlas_build(f, 12.0, []i64{'A', 'V', 'W', 'o', 0xC4, 0x1DE}, 64, 1)
    if err == "" {
        img := image_new(40, 20, 3)
        draw_text(&img, a, 1.0, 1.0, "AVo\xC3\x84", vec4(1.0, 1.0, 1.0, 1.0))
        draw_text(&img, f, 12.0, 1.0, 1.0, "W\xC7\x9E", vec4(1.0, 1.0, 1.0, 1.0))
        sum += i64(img.pix[100])
    }
    sum
}

fn check(name: str, d: []u8) {
    f, err := font_parse(d)
    if err != "" {
        print(name, "->", err)
        return
    }
    exercise(f)
    bad := vec[i64]()
    for g in 0..f.glyphs {
        _, ok := glyph_outline(f, g)
        if !ok { bad.push(g) }
    }
    print(name, "-> parsed; glyphs that cannot be read:", bad[..])
}

fn main() {
    good, ok := read_file("tests/std/data/font_test.ttf")
    assert ok, "font_test.ttf missing"
    kern, ok2 := read_file("tests/std/data/font_test_kern.ttf")
    assert ok2, "font_test_kern.ttf missing"
    fn copy_of(d: []u8) -> []u8 { clone(d) }

    check("empty", "")
    check("short", good[..11])
    check("text", "hello, world! this is not a font")
    d := copy_of(good)
    d[0..4].copy("OTTO")
    check("OpenType with CFF outlines", d)
    d = copy_of(good)
    d[record(d, "glyf")..record(d, "glyf") + 4].copy("CFF ")
    check("CFF table, no glyf", d)
    d = copy_of(good)
    d[record(d, "glyf")..record(d, "glyf") + 4].copy("xxxx")
    check("no glyf", d)
    d = copy_of(good)
    put32(d, record(d, "head") + 8, len(d) - 10)
    check("head beyond the end", d)
    d = copy_of(good)
    put32(d, record(d, "loca") + 12, 0x7FFF_FFFF)
    check("loca length huge", d)
    d = copy_of(good)
    put16(d, 4, 2000)
    check("2000 tables", d)
    d = copy_of(good)
    put32(d, table(d, "head") + 12, 0x12345678)
    check("bad head magic", d)
    d = copy_of(good)
    put16(d, table(d, "head") + 18, 0)
    check("units per em 0", d)
    d = copy_of(good)
    put16(d, table(d, "head") + 50, 7)
    check("loca format 7", d)
    d = copy_of(good)
    put16(d, table(d, "maxp") + 4, 0)
    check("no glyphs", d)
    d = copy_of(good)
    put16(d, table(d, "maxp") + 4, 1000)
    check("1000 glyphs, loca for 11", d)
    d = copy_of(good)
    put16(d, table(d, "hhea") + 34, 0)
    check("no hmtx advances", d)
    d = copy_of(good)
    put16(d, table(d, "hhea") + 34, 60000)
    check("more hmtx advances than glyphs", d)
    d = copy_of(good)
    c := table(d, "cmap")
    put16(d, c + 4, 1)
    put16(d, c + 12, 1)
    check("only Macintosh character maps", d)
    d = copy_of(kern)
    c = table(d, "cmap")
    put16(d, c + 6, 0)
    fs, es := font_parse(d)
    print("Windows symbol encoding:", es == "", fs.cmap_symbol, glyph_index(fs, 'A'), glyph_index(fs, 0x1DE))
    d = copy_of(kern)
    c = table(d, "cmap")
    put16(d, c + be32(d, c + 8) + 6, 0xFFFE)
    check("format 4 with 32767 segments", d)
    d = copy_of(kern)
    c = table(d, "cmap")
    put32(d, c + 8, 0x7FFF_0000)
    check("cmap subtable beyond the end", d)
    d = copy_of(good)
    c = table(d, "cmap")
    put32(d, c + be32(d, c + 16) + 12, 0x0FFF_FFFF)
    check("format 12 with too many groups (format 4 used)", d)
    d = copy_of(good)
    put32(d, table(d, "loca") + 4 * 3, be32(d, table(d, "loca") + 4 * 4) + 2)
    check("loca decreasing at glyph 3", d)
    d = copy_of(good)
    put32(d, table(d, "loca") + 4 * 11, 0x10000)
    check("last loca beyond glyf", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 9) + 12, 9)
    check("composite 9 contains itself", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 10) + 12, 10)
    put16(d, glyph_at(d, 9) + 12, 10)
    check("composites 9 and 10 contain each other", d)
    d = copy_of(good)
    d[glyph_at(d, 10) + 20] = 200
    check("point matching with a point that does not exist", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 10) + 12, 999)
    check("component glyph 999", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 2) + 10, 5)
    check("contour ends decreasing (glyph 2)", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 4) + 10, 60000)
    check("60001 points in a 12-point glyph (4)", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 5) + 14, 60000)
    check("60000 bytes of instructions (glyph 5)", d)
    d = copy_of(good)
    put16(d, glyph_at(d, 8) + 10, 0x0001 | 0x0002 | 0x0020 | 0x0080)
    check("composite transform cut off (glyph 8)", d)
    d = copy_of(good)
    g := table(d, "GPOS")
    put16(d, g + 8, 0xFFF0)
    put16(d, g + 6, 0xFFF0)
    check("GPOS lists beyond the end", d)
    d = copy_of(good)
    put16(d, g + be16(d, g + 8) + 2, 0xFFFF)
    check("GPOS lookup offset beyond the end", d)
    d = copy_of(kern)
    put16(d, table(d, "kern") + 10, 0xFFFF)
    check("kern with 65535 pairs", d)
    // a collection holding the font: the table offsets move by the header
    ttc := vec[u8]()
    ttc.extend("ttcf")
    for v in []u8{0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16} { ttc.push(v) }
    ttc.extend(good)
    t := ttc.items()
    for k in 0..be16(t, 16 + 4) {
        r := 16 + 12 + 16 * k + 8
        put32(t, r, be32(t, r) + 16)
    }
    f0, e0 := font_parse(t, 0)
    _, e1 := font_parse(t, 1)
    _, e2 := font_parse(good, 1)
    print("collection: font 0", e0 == "", f0.glyphs, glyph_index(f0, 'A'), "|", e1, "|", e2)
    put32(t, 12, len(t) - 4)
    check("collection entry beyond the end", t)

    // every prefix of both files
    for d0 in [][]u8{good, kern} {
        parsed := 0
        rejected := 0
        for n in 0..len(d0) {
            f, err := font_parse(d0[..n])
            if err == "" {
                exercise(f)
                parsed += 1
            } else {
                rejected += 1
            }
        }
        print("prefixes of", len(d0), "bytes: parsed", parsed, "rejected", rejected)
    }

    // random damage: 1 to 8 bytes set to random values, 0, 0xFF or 0x80
    seed := u64(0x9E3779B97F4A7C15)
    fn next(seed: *u64) -> i64 {
        *seed = *seed * 6364136223846793005 + 1442695040888963407
        i64(*seed >> 33)
    }
    parsed := 0
    rejected := 0
    for it in 0..10000 {
        d = copy_of(if it % 2 == 0 { good } else { kern })
        for _ in 0..1 + next(&seed) % 8 {
            i := next(&seed) % len(d)
            d[i] = match next(&seed) % 4 {
                0 => u8(0)
                1 => u8(0xFF)
                2 => u8(0x80)
                _ => u8(next(&seed))
            }
        }
        m := mark()
        f, err := font_parse(d)
        if err == "" {
            exercise(f)
            parsed += 1
        } else {
            rejected += 1
        }
        release(m)
    }
    print("damaged copies: parsed", parsed, "rejected", rejected)
}
