// The scenery, painted once at start-up with paint.al: mountain ranges, hills, a forest, clouds
// and the trees, bushes and rocks of the playfield. Everything here is a function of the seed.
use std.image
use std.gfx

// A horizontal strip that tiles: the masks of its materials, uploaded as one coverage texture.
struct Strip { tex: Texture, w: i64, h: i64, mats: []u8 }

fn strip_upload(g: *Gfx, p: *Painter, mats: []u8) -> Strip {
    Strip{tex: g.texture(compile(p, mats), FilterNearest), w: p.w, h: p.h, mats: mats}
}

// ---- mountains

// A range of peaks: a ridged profile (sharp crests) mixed with smooth noise. A pixel is lit as
// the slope of the crest above it, smoothed over a width that grows with the depth below the
// crest: near the top every crag has its own lit and shaded side, further down the faces of
// whole mountains take over, so the boundaries run as ridges diagonally down from the peaks
// and merge. Thin gullies streak the faces, snow caps the peaks above `snow_y` and runs down in
// fingers, and with `trees` > 0 small firs dot the lower slopes.
fn paint_range(p: *Painter, top: f32, range: f32, freq: f32, sharp: f32, snow_y: f32, trees: f32, seed: u32) {
    w := p.w
    fw := f32(w)
    h := alloc[f32](w)
    for x in 0..w {
        ridged := 1.0 - fabs(wnoise(f32(x), fw, freq, seed))
        ridged = ridged * ridged
        smooth := wfbm(f32(x), fw, freq * 2.0, 4, seed + 5) * 0.5 + 0.5
        v := clamp(lerp(smooth, ridged, sharp) + wnoise(f32(x), fw, freq * 6.0, seed + 8) * 0.04, 0.0, 1.0)
        h[x] = top + (1.0 - v) * range
    }
    fn hx(h: []f32, x: i64) -> f32 {
        n := len(h)
        h[((x % n) + n) % n]
    }
    for x in 0..w {
        snow_line := snow_y + wnoise(f32(x), fw, 0.05, seed + 9) * 5.0
        finger := fmax(0.0, wnoise(f32(x), fw, 0.09, seed + 11)) * 16.0
        for y in i64(h[x])..p.h {
            fy := f32(y)
            d := fy - h[x]
            // the slope of the crest averaged over 2r + 1 columns: > 0 where it falls to the right
            r := 1 + i64(d * 0.7)
            slope := (hx(h, x + r) + hx(h, x + r + 1) - hx(h, x - r) - hx(h, x - r - 1)) / f32(2 * r + 1)
            slope += noise2(f32(x) * 0.4, fy * 0.07, seed + 3) * 0.35          // gullies
            nx := clamp(slope * 2.0, -1.0, 1.0)
            ny := -0.55 + smoothstep(0.0, range, d) * 0.45
            m := if fy < snow_line + finger * 0.5 && d < 7.0 + finger + (snow_line - h[x]) * 0.35 { MAT_SNOW } else { MAT_ROCK }
            plot_n(p, x, y, m, vec3(nx, ny, 0.45))
        }
    }
    if trees > 0.0 {
        for x in 0..w by 2 {
            if wfbm(f32(x), fw, 0.03, 3, seed + 21) < 0.15 || hash01(i64(x), seed + 22) > trees {
                continue
            }
            base := h[x] + range * (0.35 + hash01(i64(x), seed + 23) * 0.5)
            if base > f32(p.h) - 2.0 || base < snow_y + 26.0 {
                continue
            }
            th := 4.0 + hash01(i64(x), seed + 24) * 4.0
            tier(p, f32(x), base - th, th * 0.32, th, MAT_LEAF, seed + 25)
        }
    }
}

// ---- hills

// Rolling hills, lit along their crests, with copses and lone trees on top.
fn paint_hills(p: *Painter, top: f32, range: f32, freq: f32, seed: u32) {
    w := p.w
    fw := f32(w)
    h := alloc[f32](w)
    for x in 0..w {
        h[x] = top + (0.5 - wfbm(f32(x), fw, freq, 3, seed) * 0.5) * range
    }
    for x in 0..w {
        for y in i64(h[x])..p.h {
            dy := f32(y) - h[x]
            // lit as the crest's slope smoothed with depth, as the mountains are
            r := 2 + i64(dy * 1.5)
            slope := (h[((x + r) % w + w) % w] - h[((x - r) % w + w) % w]) / f32(2 * r)
            n := lerp(vec3(slope * 6.0, -1.0, 0.45), vec3(slope * 4.0, -0.25, 0.8), smoothstep(2.0, 16.0, dy))
            // fields: faint bands of a different tone further down
            band := wnoise(f32(x) + f32(y) * 2.0, fw, 0.02, seed + 4)
            if dy > 18.0 && band > 0.35 {
                n = vec3(slope, -0.6, 0.6)
            }
            plot_n(p, x, y, MAT_GROUND, n)
        }
    }
    x := 0
    while x < w {
        density := wfbm(f32(x), fw, 0.012, 2, seed + 7)
        x += if density > 0.1 { 3 + i64(hash01(i64(x), seed + 8) * 4.0) } else { 9 + i64(hash01(i64(x), seed + 8) * 30.0) }
        if x >= w {
            break
        }
        base := h[x] + 2.0
        r := hash01(i64(x), seed + 9)
        th := 8.0 + hash01(i64(x), seed + 10) * 9.0
        if r < 0.45 {
            pine(p, f32(x), base, th * 1.3, th * 0.55, MAT_LEAF, MAT_TRUNK, seed + u32(x))
        } else {
            mat := if r > 0.9 { MAT_AUTUMN } else { MAT_LEAF }
            broadleaf(p, f32(x), base, th, th * 0.9, mat, MAT_TRUNK, seed + u32(x))
        }
    }
}

// ---- trees

fn pine(p: *Painter, x: f32, base: f32, h: f32, w: f32, leaf: u8, trunk: u8, seed: u32) {
    limb(p, vec2(x, base), vec2(x, base - h * 0.3), fmax(1.0, w * 0.14), trunk)
    nt := clamp(i64(h / 8.0), 3, 7)
    for t in 0..nt {
        ft := f32(t) / f32(nt - 1)
        top := base - h + ft * h * 0.58
        tier(p, x, top, w * 0.5 * (0.32 + 0.68 * ft), h * (0.3 - ft * 0.05), leaf, seed + u32(t) * 13)
    }
}

fn broadleaf(p: *Painter, x: f32, base: f32, h: f32, w: f32, leaf: u8, trunk: u8, seed: u32) {
    lean := (hash01(1, seed) - 0.5) * w * 0.2
    c := vec2(x + lean, base - h * 0.6)
    tw := fmax(1.0, w * 0.13)
    limb(p, vec2(x, base), c + vec2(0.0, h * 0.1), tw, trunk)
    if h > 18.0 {
        limb(p, vec2(x + lean * 0.5, base - h * 0.3), c + vec2(-w * 0.25, -h * 0.05), fmax(1.0, tw * 0.6), trunk)
        limb(p, vec2(x + lean * 0.5, base - h * 0.35), c + vec2(w * 0.28, -h * 0.1), fmax(1.0, tw * 0.6), trunk)
    }
    rad := vec2(w * 0.5, h * 0.38)
    n := 5 + i64(h / 6.0)
    for k in 0..n {
        a := hash01(i64(k), seed + 1) * TAU
        d := sqrt(hash01(i64(k), seed + 2)) * 0.55
        off := vec2(cos(a), sin(a) * 0.8) * d
        if k == n - 1 {
            off = vec2(-0.15, -0.35)              // a crown lump on top, drawn last
        }
        pos := c + off * rad
        r := rad * (0.42 + hash01(i64(k), seed + 3) * 0.2)
        blob(p, pos, r, leaf, 0.3, seed + u32(k), vec3(off.x, off.y, 0.0) * 0.9, 1e9)
    }
}

fn birch(p: *Painter, x: f32, base: f32, h: f32, w: f32, leaf: u8, seed: u32) {
    limb(p, vec2(x, base), vec2(x + 1.0, base - h * 0.75), 3.0, MAT_BARK)
    // the dark marks of birch bark
    for y in i64(base - h * 0.75)..i64(base) {
        if noise_hash(y, 0, 0, seed) % 4 == 0 {
            plot(p, i64(x) + i64(noise_hash(y, 1, 0, seed) % 2), y, MAT_LINE, -100.0, -100.0)
        }
    }
    c := vec2(x + 1.0, base - h * 0.68)
    rad := vec2(w * 0.5, h * 0.33)
    for k in 0..6 {
        off := vec2((hash01(i64(k), seed + 1) - 0.5) * 1.1, (f32(k) / 5.0 - 0.6) * 1.1)
        r := rad * (0.38 + hash01(i64(k), seed + 3) * 0.18)
        blob(p, c + off * rad, r, leaf, 0.35, seed + u32(k), vec3(off.x, off.y, 0.0) * 0.8, 1e9)
    }
}

// ---- the forest: the nearest strip behind the playfield

fn paint_forest(p: *Painter, floor_y: f32, seed: u32) {
    w := p.w
    fw := f32(w)
    for y in i64(floor_y)..p.h {
        for x in 0..w {
            plot_n(p, x, y, MAT_GROUND, vec3(0.0, -0.3, 1.0))
        }
    }
    for row in 0..2 {
        x := i64(hash01(i64(row), seed) * 10.0)
        while x < w {
            r := hash01(i64(x), seed + 1 + u32(row))
            tall := 0.55 + 0.45 * (wfbm(f32(x), fw, 0.01, 2, seed + 2) * 0.5 + 0.5)
            th := (34.0 + hash01(i64(x), seed + 3) * 34.0) * tall * (if row == 0 { 1.15 } else { 0.9 })
            base := floor_y + f32(row) * 5.0 + hash01(i64(x), seed + 4) * 3.0
            s := seed + u32(x) * 7 + u32(row) * 1000
            if r < 0.55 {
                pine(p, f32(x), base, th, th * 0.42, MAT_LEAF, MAT_TRUNK, s)
                x += 7 + i64(hash01(i64(x), seed + 5) * 9.0)
            } else if r < 0.88 {
                broadleaf(p, f32(x), base, th * 0.8, th * 0.6, MAT_LEAF, MAT_TRUNK, s)
                x += 12 + i64(hash01(i64(x), seed + 5) * 10.0)
            } else {
                broadleaf(p, f32(x), base, th * 0.7, th * 0.55, MAT_AUTUMN, MAT_TRUNK, s)
                x += 11 + i64(hash01(i64(x), seed + 5) * 8.0)
            }
        }
    }
}

// ---- clouds: a sheet of cumulus, each with a flat base

const CLOUD_COUNT = 8
const CLOUD_CELL_W = 112
const CLOUD_CELL_H = 46           // tall enough that no cloud reaches into the cell above

fn paint_clouds(p: *Painter, seed: u32) {
    for k in 0..CLOUD_COUNT {
        s := seed + u32(k) * 101
        x0 := f32((k % 2) * CLOUD_CELL_W)
        y0 := f32((k / 2) * CLOUD_CELL_H)
        cw := 50.0 + hash01(i64(k), s) * 56.0
        ch := 13.0 + hash01(i64(k), s + 1) * 10.0
        base := y0 + f32(CLOUD_CELL_H) - 3.0
        cx := x0 + f32(CLOUD_CELL_W) * 0.5
        n := 4 + i64(cw / 14.0)
        for i in 0..n {
            rel := (f32(i) + 0.5) / f32(n) * 2.0 - 1.0            // -1 .. 1 along the cloud
            hump := 1.0 - rel * rel * 0.75
            r := vec2(ch * 0.55 * hump * (0.8 + hash01(i64(i), s + 2) * 0.45))
            r.x *= 1.25
            c := vec2(cx + rel * cw * 0.42, base - r.y * (0.55 + hash01(i64(i), s + 3) * 0.3))
            blob(p, c, r, MAT_CLOUD, 0.12, s + u32(i), vec3(rel * 0.4, 0.15, 0.0), base)
        }
        // the underside is in its own shadow
        for y in i64(base) - 3..=i64(base) {
            for x in i64(x0)..i64(x0) + CLOUD_CELL_W {
                i := at(p, x, y)
                if i >= 0 && p.mat[i] == MAT_CLOUD {
                    p.dl[i] = fmin(p.dl[i], -30.0)
                    p.dr[i] = fmin(p.dr[i], -30.0)
                }
            }
        }
    }
}

// ---- props of the playfield: trees, bushes, rocks, each in a cell of one sheet

enum PropKind { PropTree, PropBush, PropRock }
struct Prop { src: vec4, kind: PropKind, mats: u32 }   // mats: bit k set if material k of PROP_MATS is in it

const PROP_MATS = [_]u8{MAT_LINE, MAT_TRUNK, MAT_BARK, MAT_ROCK, MAT_LEAF, MAT_AUTUMN}
const PROP_SHEET_W = 512
const PROP_SHEET_H = 96

struct Props { tex: Texture, list: Vec[Prop], h: i64 }

fn paint_props(g: *Gfx, seed: u32) -> Props {
    p := painter(PROP_SHEET_W, PROP_SHEET_H, false)
    cells := vec[(vec4, PropKind)]()
    x := 1.0
    // trees: 52 x 94 cells
    for k in 0..8 {
        s := seed + u32(k) * 977
        cx := x + 26.0
        base := f32(PROP_SHEET_H) - 2.0
        match k % 4 {
            0 => pine(&p, cx, base, 70.0 + hash01(i64(k), s) * 20.0, 30.0, MAT_LEAF, MAT_TRUNK, s)
            1 => broadleaf(&p, cx, base, 58.0 + hash01(i64(k), s) * 16.0, 44.0, MAT_LEAF, MAT_TRUNK, s)
            2 => birch(&p, cx, base, 66.0, 24.0, if k == 2 { MAT_AUTUMN } else { MAT_LEAF }, s)
            _ => broadleaf(&p, cx, base, 54.0, 42.0, MAT_AUTUMN, MAT_TRUNK, s)
        }
        cells.push((vec4(x, 0.0, 52.0, f32(PROP_SHEET_H)), PropTree))
        x += 53.0
    }
    // bushes: 22 x 14
    for k in 0..3 {
        s := seed + 5000 + u32(k) * 31
        base := f32(PROP_SHEET_H) - 2.0
        for i in 0..4 {
            off := f32(i) * 4.0 - 6.0
            blob(&p, vec2(x + 11.0 + off, base - 5.0 - hash01(i64(i), s) * 3.0), vec2(5.5, 4.5), if k == 2 { MAT_AUTUMN } else { MAT_LEAF },
                0.3, s + u32(i), vec3(off * 0.08, 0.0, 0.0), base)
        }
        cells.push((vec4(x, f32(PROP_SHEET_H) - 16.0, 22.0, 16.0), PropBush))
        x += 23.0
    }
    // rocks: 16 x 12
    for k in 0..3 {
        s := seed + 6000 + u32(k) * 17
        base := f32(PROP_SHEET_H) - 2.0
        blob(&p, vec2(x + 8.0, base - 3.0), vec2(6.0 + f32(k), 5.0 + f32(k % 2)), MAT_ROCK, 0.15, s, vec3(0.0), base)
        cells.push((vec4(x, f32(PROP_SHEET_H) - 13.0, 17.0, 13.0), PropRock))
        x += 18.0
    }
    outline(&p)
    props := Props{h: PROP_SHEET_H}
    for c in cells {
        mats: u32 = 0
        for y in i64(c.0.y)..i64(c.0.y + c.0.w) {
            for xx in i64(c.0.x)..i64(c.0.x + c.0.z) {
                k := index_of(PROP_MATS[..], mat_at(&p, xx, y))
                if k >= 0 {
                    mats |= u32(1) << u32(k)
                }
            }
        }
        props.list.push(Prop{src: c.0, kind: c.1, mats: mats})
    }
    props.tex = g.texture(compile(&p, PROP_MATS[..]), FilterNearest)
    props
}
