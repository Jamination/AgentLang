// Software blitting for the starter's front end (game.al). A sprite is a block of premultiplied
// RGBA pixels held as u32 (0xAABBGGRR: red in the lowest byte, the layout of std.image and of
// the framebuffer that std.window presents); every helper draws one into a Canvas, clipped at
// its edges, and allocates nothing.
//   - blit: a sprite at a whole-pixel position, "over" (alpha) or added (light)
//   - blit_xf: scaled, stretched and rotated, filtered bilinearly
//   - mask_xf: a grey sprite (a glow, a ring, a puff of smoke) that gets its colour when drawn
// The byte arithmetic works on the four channels of a pixel at once, two of them per 32-bit
// multiply ("SIMD within a register"): about a third of a nanosecond per pixel.
use std.image

struct Sprite { w: i64, h: i64, px: []u32 }
struct Canvas { w: i64, h: i64, px: []u32 }
enum Blend { Over, Add }

// A set of halvings of one sprite, so that it can be drawn small without flicker.
struct Mips { levels: []Sprite }

fn sprite_new(w: i64, h: i64) -> Sprite { Sprite{w, h, alloc[u32](w * h)} }
fn sprite_of(img: Image) -> Sprite { Sprite{img.w, img.h, from_bytes[u32](img.pix)} }
fn image_of(s: Sprite) -> Image { Image{w: s.w, h: s.h, channels: 4, pix: as_bytes(s.px)} }

fn mips_of(s: Sprite) -> Mips {
    imgs := mipmap_chain(image_of(s))         // box filter: right for premultiplied pixels
    levels := alloc[Sprite](imgs.len)
    for i, img in imgs {
        levels[i] = sprite_of(img)
    }
    Mips{levels}
}

// The level to draw `size` pixels wide: the smallest that is at least that wide.
fn level(m: *Mips, size: f32) -> Sprite {
    i := 0
    while i + 1 < m.levels.len && f32(m.levels[i + 1].w) >= size {
        i += 1
    }
    m.levels[i]
}

// A colour with straight alpha (components 0..1) as a premultiplied pixel.
fn premul(c: vec4) -> u32 { color_u32(vec4(c.xyz * c.w, c.w)) }

// A light of colour `rgb` (may exceed 1 for bright light) and strength `k` as an additive pixel.
fn light(rgb: vec3, k: f32) -> u32 { color_u32(vec4(rgb * k, 1.0)) }

// Each byte of c times k / 256 (k in 0..=256).
inline fn scale4(c: u32, k: u32) -> u32 {
    rb := ((c & 0x00FF00FF) * k >> 8) & 0x00FF00FF
    ga := ((c >> 8) & 0x00FF00FF) * k & 0xFF00FF00
    rb | ga
}

// Bytewise a + b, each byte clamped at 255.
inline fn add4(a: u32, b: u32) -> u32 {
    s := (a & 0x7F7F7F7F) + (b & 0x7F7F7F7F)  // the low seven bits, carrying into bit 7
    s = s ^ ((a ^ b) & 0x80808080)            // bit 7 of the sum
    carry := ((a & b) | ((a | b) & ~s)) & 0x80808080
    c := carry >> 7                           // 1 in each byte that overflowed ...
    s | ((c << 8) - c)                        // ... becomes 255
}

// The weight 0..=256 of what lies under a pixel of alpha a.
inline fn behind(a: u32) -> u32 {
    k := 255 - a
    k + (k >> 7)
}

// The premultiplied pixel s over d.
inline fn over(d: u32, s: u32) -> u32 { add4(s, scale4(d, behind(s >> 24))) }

inline fn lerp4(a: u32, b: u32, t: u32) -> u32 { scale4(a, 256 - t) + scale4(b, t) }

inline fn texel(s: *Sprite, x: i64, y: i64) -> u32 {
    if x < 0 || y < 0 || x >= s.w || y >= s.h {
        return 0
    }
    s.px[y * s.w + x]
}

inline fn put(c: *Canvas, i: i64, v: u32, blend: Blend) {
    c.px[i] = match blend {
        Over => over(c.px[i], v)
        Add => add4(c.px[i], v)
    }
}

// Draws s with its top left corner at (x, y), its pixels scaled by k / 256 (256: as they are).
fn blit(c: *Canvas, s: *Sprite, x: i64, y: i64, blend: Blend, k: u32) {
    x0 := max(x, 0)
    y0 := max(y, 0)
    x1 := min(x + s.w, c.w)
    y1 := min(y + s.h, c.h)
    for py in y0..y1 {
        src := (py - y) * s.w - x
        dst := py * c.w
        for px in x0..x1 {
            v := s.px[src + px]
            if v != 0 {
                put(c, dst + px, if k < 256 { scale4(v, k) } else { v }, blend)
            }
        }
    }
}

// The sprite centred on (cx, cy), drawn sx times as wide and sy times as high, turned by
// `angle` radians (clockwise: y points down). Pixels are scaled by k / 256.
fn blit_xf(c: *Canvas, s: *Sprite, cx: f32, cy: f32, angle: f32, sx: f32, sy: f32, blend: Blend, k: u32) {
    transformed(c, s, cx, cy, angle, sx, sy, blend, false, k)
}

// A grey mask (its red channel) drawn like blit_xf in the premultiplied colour `color`.
fn mask_xf(c: *Canvas, m: *Sprite, cx: f32, cy: f32, angle: f32, sx: f32, sy: f32, blend: Blend, color: u32) {
    transformed(c, m, cx, cy, angle, sx, sy, blend, true, color)
}

// A round mask from a mip chain, `size` pixels across, centred on (cx, cy).
fn mask_at(c: *Canvas, m: *Mips, cx: f32, cy: f32, size: f32, blend: Blend, color: u32) {
    if size < 0.5 {
        return
    }
    s := m.level(size)
    k := size / f32(s.w)
    transformed(c, &s, cx, cy, 0.0, k, k, blend, true, color)
}

// The texture coordinates walk across a row in 16.16 fixed point; the four texels around the
// sample are read directly when they lie inside the sprite (texel() checks the border).
priv fn transformed(c: *Canvas, s: *Sprite, cx: f32, cy: f32, angle: f32, sx: f32, sy: f32, blend: Blend, mask: bool, k: u32) {
    if sx <= 0.0 || sy <= 0.0 {
        return
    }
    sn, cs := sin_cos(angle)
    // the box around the turned rectangle bounds the rows and columns to visit
    hw := f32(s.w) * 0.5 * sx + 1.0
    hh := f32(s.h) * 0.5 * sy + 1.0
    ex := fabs(cs) * hw + fabs(sn) * hh
    ey := fabs(sn) * hw + fabs(cs) * hh
    x0 := max(i64(floor(cx - ex)), 0)
    x1 := min(i64(ceil(cx + ex)), c.w)
    y0 := max(i64(floor(cy - ey)), 0)
    y1 := min(i64(ceil(cy + ey)), c.h)
    if x0 >= x1 {
        return
    }
    // screen offset from the centre -> sprite pixels: turn back by -angle, then unscale. Half a
    // texel is taken off, so that the integer part is the texel up and left of the sample.
    ux := cs / sx
    uy := sn / sx
    vx := -sn / sy
    vy := cs / sy
    mx := f32(s.w) * 0.5 - 0.5
    my := f32(s.h) * 0.5 - 0.5
    du := i64(ux * 65536.0)
    dv := i64(vx * 65536.0)
    w := s.w
    for py in y0..y1 {
        dy := f32(py) + 0.5 - cy
        dx := f32(x0) + 0.5 - cx
        u := ux * dx + uy * dy + mx
        v := vx * dx + vy * dy + my
        // only the run of the row whose samples fall on the sprite
        lo, hi := span(u, ux, f32(w), 0, x1 - x0)
        lo, hi = span(v, vx, f32(s.h), lo, hi)
        iu := i64((u + ux * f32(lo)) * 65536.0)
        iv := i64((v + vx * f32(lo)) * 65536.0)
        out := py * c.w + x0
        for i in lo..hi {
            x := iu >> 16
            y := iv >> 16
            a: u32 = 0
            b: u32 = 0
            d: u32 = 0
            e: u32 = 0
            if x >= 0 && y >= 0 && x < w - 1 && y < s.h - 1 {
                o := y * w + x
                a = s.px[o]
                b = s.px[o + 1]
                d = s.px[o + w]
                e = s.px[o + w + 1]
            } else {
                a = texel(s, x, y)
                b = texel(s, x + 1, y)
                d = texel(s, x, y + 1)
                e = texel(s, x + 1, y + 1)
            }
            if (a | b | d | e) != 0 {
                wx := u32((iu >> 8) & 0xFF)
                wy := u32((iv >> 8) & 0xFF)
                t: u32 = 0
                if mask {
                    // grey: one channel is enough, in plain integers
                    top := (a & 0xFF) * (256 - wx) + (b & 0xFF) * wx
                    bottom := (d & 0xFF) * (256 - wx) + (e & 0xFF) * wx
                    g := (top * (256 - wy) + bottom * wy) >> 16
                    t = scale4(k, g + (g >> 7))
                } else {
                    t = lerp4(lerp4(a, b, wx), lerp4(d, e, wx), wy)
                    if k < 256 {
                        t = scale4(t, k)
                    }
                }
                put(c, out + i, t, blend)
            }
            iu += du
            iv += dv
        }
    }
}

// The steps t in lo..hi (a range of a row) for which a + b * t lies in -1..size, with a step
// to spare on either side.
priv fn span(a: f32, b: f32, size: f32, lo: i64, hi: i64) -> (i64, i64) {
    if fabs(b) < 0.000001 {
        if a > -1.0 && a < size {
            return (lo, hi)
        }
        return (0, 0)
    }
    t1 := (-1.0 - a) / b
    t2 := (size - a) / b
    first := i64(floor(fmax(fmin(t1, t2), -1.0)))
    last := i64(ceil(fmin(fmax(t1, t2), f32(hi + 1))))
    (max(lo, first), min(hi, last + 1))
}

// Multiplies the rows y0..y1 of the canvas by k / 256 (for bands behind text).
fn darken_rows(c: *Canvas, y0: i64, y1: i64, k: u32) {
    for i in max(y0, 0) * c.w..min(y1, c.h) * c.w {
        c.px[i] = scale4(c.px[i], k)
    }
}
