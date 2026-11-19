// The painter all scenery is made with. Shapes (blobs, pine tiers, trunks, rock faces) are
// painted into a Painter, which remembers per pixel a material and how much that pixel faces a
// key light from the upper left and from the upper right. `compile` turns that into one-channel
// masks, five per material, stacked vertically in one image:
//
//   0 the whole material      drawn in its shadow colour
//   1 mid tone, lit from the left     2 highlight, lit from the left
//   3 mid tone, lit from the right    4 highlight, lit from the right
//
// Uploaded as a coverage texture, each mask is drawn with the colour of the moment as its tint:
// the same pixels are a golden sunrise, a blue noon or a moonlit night, and the lit side follows
// the sun across the sky. Tone boundaries are ordered-dithered (a 4 x 4 Bayer matrix), the way
// a pixel artist blends two colours without adding a third.
use std.image

const MASKS = 5                  // masks per material
const TONE_MID: f32 = 18.0       // a pixel is mid tone above this lighting value, highlight above
const TONE_HI: f32 = 58.0
const TONE_DITHER: f32 = 22.0    // amplitude of the dither across a tone boundary

// Materials. A painter holds any of them; a strip names the ones it compiles.
const MAT_LEAF: u8 = 1
const MAT_TRUNK: u8 = 2
const MAT_AUTUMN: u8 = 3
const MAT_BARK: u8 = 4
const MAT_ROCK: u8 = 5
const MAT_SNOW: u8 = 6
const MAT_GROUND: u8 = 7
const MAT_CLOUD: u8 = 8
const MAT_LINE: u8 = 9           // a dark outline around props

priv const BAYER = [16]f32{0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0}

// The ordered-dither threshold of a pixel, in (0, 1).
fn bayer(x: i64, y: i64) -> f32 {
    (BAYER[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0
}

// The two key lights: from the upper left and the upper right, a little towards the viewer.
const LIGHT_L = vec3(-0.55, -0.68, 0.48)
const LIGHT_R = vec3(0.55, -0.68, 0.48)

struct Painter {
    w: i64
    h: i64
    wrap: bool           // x wraps around (a strip that tiles horizontally)
    mat: []u8
    dl: []f32            // lighting from the left, about -100..100
    dr: []f32
}

fn painter(w: i64, h: i64, wrap: bool) -> Painter {
    Painter{w: w, h: h, wrap: wrap, mat: alloc[u8](w * h), dl: alloc[f32](w * h), dr: alloc[f32](w * h)}
}

// The index of pixel (x, y), or -1 outside.
fn at(p: *Painter, x: i64, y: i64) -> i64 {
    if y < 0 || y >= p.h {
        return -1
    }
    if p.wrap {
        x = ((x % p.w) + p.w) % p.w
    } else if x < 0 || x >= p.w {
        return -1
    }
    y * p.w + x
}

fn plot(p: *Painter, x: i64, y: i64, m: u8, dl: f32, dr: f32) {
    i := at(p, x, y)
    if i >= 0 {
        p.mat[i] = m
        p.dl[i] = dl
        p.dr[i] = dr
    }
}

// Plot with the lighting of a surface normal.
fn plot_n(p: *Painter, x: i64, y: i64, m: u8, n: vec3) {
    n = normalize(n)
    plot(p, x, y, m, dot(n, normalize(LIGHT_L)) * 100.0, dot(n, normalize(LIGHT_R)) * 100.0)
}

fn mat_at(p: *Painter, x: i64, y: i64) -> u8 {
    i := at(p, x, y)
    if i < 0 { 0 } else { p.mat[i] }
}

// A rounded lump of leaves (or cloud, or rock): an ellipse with a rough edge, lit as a sphere
// bent towards `bend` (the normal of the whole canopy it is part of: lumps of one tree share
// one light).
fn blob(p: *Painter, c: vec2, r: vec2, m: u8, rough: f32, seed: u32, bend: vec3, flat_bottom: f32) {
    x0 := i64(floor(c.x - r.x - 2.0))
    x1 := i64(ceil(c.x + r.x + 2.0))
    y0 := i64(floor(c.y - r.y - 2.0))
    y1 := i64(ceil(c.y + r.y + 2.0))
    for y in y0..=y1 {
        if f32(y) > flat_bottom {
            break
        }
        for x in x0..=x1 {
            q := (vec2(f32(x) + 0.5, f32(y) + 0.5) - c) / r
            e := dot(q, q)
            edge := 1.0 + rough * noise2(f32(x) * 0.55, f32(y) * 0.55, seed)
            if e > edge {
                continue
            }
            nz := sqrt(fmax(0.0, 1.0 - fmin(e, 1.0)))
            plot_n(p, x, y, m, vec3(q.x, q.y, nz) + bend)
        }
    }
}

// One tier of a fir: a triangle from its tip down to a jagged lower edge.
fn tier(p: *Painter, cx: f32, top: f32, half_w: f32, h: f32, m: u8, seed: u32) {
    y0 := i64(floor(top))
    y1 := i64(ceil(top + h))
    for y in y0..=y1 {
        f := (f32(y) + 0.5 - top) / h                   // 0 at the tip, 1 at the lower edge
        if f < 0.0 {
            continue
        }
        hw := half_w * fmin(f, 1.0) + 0.5
        for x in i64(floor(cx - hw - 1.0))..=i64(ceil(cx + hw + 1.0)) {
            rel := (f32(x) + 0.5 - cx) / fmax(hw, 1.0)
            if fabs(rel) > 1.0 {
                continue
            }
            // the lower edge droops at the sides and is ragged
            jag := f32(noise_hash(x, 0, 0, seed) % 3) - 1.0
            if f32(y) > top + h + rel * rel * 2.0 + jag {
                continue
            }
            plot_n(p, x, y, m, vec3(rel * 1.1, -0.25 + (f - 0.6) * 0.9, 0.55))
        }
    }
}

// A trunk or branch from (x0, y0) to (x1, y1), `w` pixels thick, lit as a cylinder.
fn limb(p: *Painter, a: vec2, b: vec2, w: f32, m: u8) {
    d := b - a
    steps := i64(length(d) * 2.0) + 1
    side := normalize(vec2(-d.y, d.x))
    if side.x > 0.0 {
        side = side * -1.0
    }
    for k in 0..=steps {
        c := a + d * (f32(k) / f32(steps))
        for i in 0..i64(ceil(w)) {
            u := (f32(i) + 0.5) / w * 2.0 - 1.0          // -1 left edge .. 1 right edge
            q := c - side * (u * w * 0.5)
            plot_n(p, i64(floor(q.x)), i64(floor(q.y)), m, vec3(u, -0.15, 0.7))
        }
    }
}

// Marks the empty pixels next to painted ones as outline (props in the playfield).
fn outline(p: *Painter) {
    marks := alloc[bool](p.w * p.h)
    for y in 0..p.h {
        for x in 0..p.w {
            if p.mat[y * p.w + x] != 0 {
                continue
            }
            for d in [_]vec2{vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0)} {
                m := mat_at(p, x + i64(d.x), y + i64(d.y))
                if m != 0 && m != MAT_LINE {
                    marks[y * p.w + x] = true
                }
            }
        }
    }
    for i in 0..p.w * p.h {
        if marks[i] {
            p.mat[i] = MAT_LINE
        }
    }
}

// The masks of the materials `mats`, in that order, stacked: mask j of material k is the
// rows (k * MASKS + j) * h .. + h.
fn compile(p: *Painter, mats: []u8) -> Image {
    img := image_new(p.w, p.h * MASKS * len(mats), 1)
    for y in 0..p.h {
        for x in 0..p.w {
            i := y * p.w + x
            k := index_of(mats, p.mat[i])
            if k < 0 {
                continue
            }
            row := k * MASKS * p.h + y
            b := (bayer(x, y) - 0.5) * TONE_DITHER
            img.pix[row * p.w + x] = 255
            if p.dl[i] + b > TONE_MID {
                img.pix[(row + p.h) * p.w + x] = 255
            }
            if p.dl[i] + b > TONE_HI {
                img.pix[(row + 2 * p.h) * p.w + x] = 255
            }
            if p.dr[i] + b > TONE_MID {
                img.pix[(row + 3 * p.h) * p.w + x] = 255
            }
            if p.dr[i] + b > TONE_HI {
                img.pix[(row + 4 * p.h) * p.w + x] = 255
            }
        }
    }
    img
}

// Noise along a strip `period` pixels long that wraps around seamlessly: 2D noise sampled on a
// circle. `freq` is in bumps per pixel.
fn wnoise(x: f32, period: f32, freq: f32, seed: u32) -> f32 {
    a := x / period * TAU
    r := freq * period / TAU
    noise2(cos(a) * r + 17.0, sin(a) * r - 9.0, seed)
}

// Fractal sum of `octaves` of wnoise, about -1..1.
fn wfbm(x: f32, period: f32, freq: f32, octaves: i64, seed: u32) -> f32 {
    s := 0.0
    amp := 1.0
    norm := 0.0
    for o in 0..octaves {
        s += wnoise(x, period, freq, seed + u32(o) * 31) * amp
        norm += amp
        amp *= 0.5
        freq *= 2.0
    }
    s / norm * 1.4
}

// A deterministic value 0..1 for an integer and a seed.
fn hash01(n: i64, seed: u32) -> f32 {
    f32(noise_hash(n, 7, 3, seed) & 0xFFFFFF) / 16777216.0
}
