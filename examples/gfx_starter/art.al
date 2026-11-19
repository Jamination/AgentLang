// The art of the std.gfx starter, painted at start-up into one RGBA atlas (one texture, so the
// batcher draws the whole world in a few draw calls): a shaded ship in five banking frames,
// engine flames, cratered asteroids and their debris, smoke, light sprites (glows, streaks, a
// plasma bolt, a shockwave ring, stars), a gas giant, a tileable nebula, a vignette and the
// rounded panel of the HUD. Nothing is loaded from files.
//
// Every sprite is a small "shader": a function from a point of its cell (-1..1, y down) to a
// colour with straight alpha, sampled several times per texel for smooth edges. Shaded sprites
// (ship, rocks, planet) are height fields lit by a warm key light from the top left and a cool
// rim light from below. The atlas is drawn with linear filtering; std.gfx blends straight
// alpha, so the colour of transparent texels bleeds into the edges of what is drawn: after
// painting, `bleed` gives every transparent texel next to a sprite that sprite's colour.
use std.image
use std.gfx

const ATLAS_W = 1024
const ATLAS_H = 1024
const SHIP_FRAMES = 5            // banked hard left .. level .. hard right
const FLAME_FRAMES = 4
const ROCKS = 8
const CHUNKS = 6
const SMOKES = 4

struct Art {
    tex: Texture
    ship: [SHIP_FRAMES]vec4      // source rectangles in the atlas (x, y, w, h)
    flame: [FLAME_FRAMES]vec4
    rock: [ROCKS]vec4
    chunk: [CHUNKS]vec4
    smoke: [SMOKES]vec4
    glow: vec4                   // soft round light
    core: vec4                   // small hot light
    streak: vec4                 // a spark: bright head on the right, tail to the left
    bolt: vec4                   // the player's plasma shot, pointing up
    ring: vec4                   // shockwave
    star: vec4
    flare: vec4                  // a bright star with four spikes
    planet: vec4
    nebula: vec4                 // opaque, tiles vertically
    vignette: vec4               // transparent in the middle, opaque white at the corners (tinted)
    panel: vec4                  // white rounded rectangle, and its outline: drawn in nine slices
    frame: vec4
}

// ---- painting ------------------------------------------------------------------------------

priv const PAD = 6               // transparent texels around each cell (room for the bleed)

priv struct Packer { x: i64, y: i64, row: i64 }

priv fn cell(p: *Packer, w: i64, h: i64) -> vec4 {
    if p.x + w + PAD > ATLAS_W {
        p.x = PAD
        p.y += p.row + PAD
        p.row = 0
    }
    assert p.y + h + PAD <= ATLAS_H, "art: the atlas is full"
    r := vec4(f32(p.x), f32(p.y), f32(w), f32(h))
    p.x += w + PAD
    p.row = max(p.row, h)
    r
}

priv fn put(img: *Image, x: i64, y: i64, c: vec3, a: f32) {
    i := (y * img.w + x) * 4
    img.pix[i] = u8(saturate(c.x) * 255.0 + 0.5)
    img.pix[i + 1] = u8(saturate(c.y) * 255.0 + 0.5)
    img.pix[i + 2] = u8(saturate(c.z) * 255.0 + 0.5)
    img.pix[i + 3] = u8(saturate(a) * 255.0 + 0.5)
}

// Fills cell r with f(ctx, p), p running over -1..1 across the cell (y down), averaged over
// ss x ss samples per texel. The samples are averaged premultiplied, so an edge that is half
// covered keeps the colour of the sprite and gets half its alpha.
priv fn paint[C](img: *Image, r: vec4, ss: i64, ctx: C, f: fn(C, vec2) -> vec4) {
    x0 := i64(r.x)
    y0 := i64(r.y)
    w := i64(r.z)
    h := i64(r.w)
    n := f32(ss * ss)
    for y in 0..h {
        for x in 0..w {
            acc := vec4(0.0)
            for sy in 0..ss {
                for sx in 0..ss {
                    u := (f32(x) + (f32(sx) + 0.5) / f32(ss)) / f32(w) * 2.0 - 1.0
                    v := (f32(y) + (f32(sy) + 0.5) / f32(ss)) / f32(h) * 2.0 - 1.0
                    c := f(ctx, vec2(u, v))
                    a := saturate(c.w)
                    acc = acc + vec4(c.xyz * a, a)
                }
            }
            rgb := if acc.w > 0.0 { acc.xyz / acc.w } else { vec3(0.0) }
            put(img, x0 + x, y0 + y, rgb, acc.w / n)
        }
    }
}

// Gives transparent texels the average colour of their coloured neighbours, `passes` texels
// deep, so that linear filtering at the edge of a sprite mixes in its own colour, not black.
priv fn bleed(img: *Image, passes: i64) {
    w := img.w
    h := img.h
    known := alloc[u8](w * h)
    for i in 0..w * h {
        known[i] = if img.pix[i * 4 + 3] > 0 { 1 } else { 0 }
    }
    for pass in 0..passes {
        stamp := u8(pass + 2)                       // filled in this pass: not a source yet
        for y in 0..h {
            for x in 0..w {
                if known[y * w + x] != 0 {
                    continue
                }
                sum := vec3(0.0)
                cnt := 0
                for d in 0..4 {
                    nx := x + [4]i64{1, -1, 0, 0}[d]
                    ny := y + [4]i64{0, 0, 1, -1}[d]
                    if nx < 0 || ny < 0 || nx >= w || ny >= h {
                        continue
                    }
                    k := known[ny * w + nx]
                    if k == 0 || k == stamp {
                        continue
                    }
                    j := (ny * w + nx) * 4
                    sum = sum + vec3(f32(img.pix[j]), f32(img.pix[j + 1]), f32(img.pix[j + 2]))
                    cnt += 1
                }
                if cnt > 0 {
                    c := sum / f32(cnt)
                    j := (y * w + x) * 4
                    img.pix[j] = u8(c.x + 0.5)
                    img.pix[j + 1] = u8(c.y + 0.5)
                    img.pix[j + 2] = u8(c.z + 0.5)
                    known[y * w + x] = stamp
                }
            }
        }
    }
}

// ---- shapes and light ---------------------------------------------------------------------------

priv fn sq(x: f32) -> f32 { x * x }

// Signed distance to a polygon (negative inside), any winding.
priv fn sd_poly(p: vec2, v: []vec2) -> f32 {
    d := dot(p - v[0], p - v[0])
    s: f32 = 1.0
    j := len(v) - 1
    for i in 0..len(v) {
        e := v[j] - v[i]
        w := p - v[i]
        b := w - e * saturate(dot(w, e) / dot(e, e))
        d = fmin(d, dot(b, b))
        c1 := p.y >= v[i].y
        c2 := p.y < v[j].y
        c3 := e.x * w.y > e.y * w.x
        if (c1 && c2 && c3) || (!c1 && !c2 && !c3) {
            s = -s
        }
        j = i
    }
    s * sqrt(d)
}

priv fn sd_round_box(p: vec2, half: vec2, r: f32) -> f32 {
    q := abs(p) - half + vec2(r)
    length(fmax(q, vec2(0.0))) + fmin(fmax(q.x, q.y), 0.0) - r
}

priv fn sd_ellipse(p: vec2, r: vec2) -> f32 {
    (length(p / r) - 1.0) * fmin(r.x, r.y)
}

// The light every shaded sprite shares: warm key from the top left, cool fill, blue rim
// light from below (the nebula), a highlight.
priv const KEY = vec3(-0.45, -0.62, 0.64)

priv fn shade(albedo: vec3, n: vec3, gloss: f32, shine: f32, rim_k: f32) -> vec3 {
    l := normalize(KEY)
    diff := fmax(dot(n, l), 0.0)
    hv := normalize(l + vec3(0.0, 0.0, 1.0))
    spec := pow(fmax(dot(n, hv), 0.0), shine) * gloss
    rim := pow(1.0 - saturate(n.z), 2.2) * saturate(dot(n.xy, vec2(0.35, 0.94)) + 0.15)
    albedo * (vec3(0.13, 0.15, 0.24) + vec3(1.05, 0.98, 0.88) * diff) + vec3(spec) + vec3(0.25, 0.55, 1.0) * rim * rim_k
}

// ---- the ship ------------------------------------------------------------------------------------

priv struct ShipCtx { bank: f32, texel: f32 }
priv struct ShipHit { h: f32, d: f32, mat: i64, q: vec2 }

priv const HULL = 1
priv const WING = 2
priv const POD = 3
priv const GLASS = 4
priv const GUN = 5

priv fn part(s: *ShipHit, d: f32, height: f32, width: f32, mat: i64) {
    s.d = fmin(s.d, d)
    if d < 0.0 {
        t := saturate(-d / width)
        hh := height * (1.0 - sq(1.0 - t))
        if hh > s.h {
            s.h = hh
            s.mat = mat
        }
    }
}

// The ship's height field at p. Banking squeezes the wing that dips away from the viewer.
priv fn ship_at(c: *ShipCtx, p: vec2) -> ShipHit {
    b := c.bank
    side := if p.x * b > 0.0 { 1.0 - 0.34 * fabs(b) } else { 1.0 - 0.06 * fabs(b) }
    q := vec2((p.x + b * 0.04) / side, p.y)
    a := vec2(fabs(q.x), q.y)
    s := ShipHit{d: 10.0, q: q}
    hull := [_]vec2{
        vec2(0.0, -0.95), vec2(0.09, -0.72), vec2(0.15, -0.35), vec2(0.17, 0.25), vec2(0.13, 0.62),
        vec2(0.06, 0.70), vec2(-0.06, 0.70), vec2(-0.13, 0.62), vec2(-0.17, 0.25), vec2(-0.15, -0.35),
        vec2(-0.09, -0.72),
    }
    wing := [_]vec2{
        vec2(0.12, -0.14), vec2(0.32, 0.06), vec2(0.82, 0.38), vec2(0.89, 0.50), vec2(0.85, 0.60),
        vec2(0.62, 0.58), vec2(0.30, 0.50), vec2(0.12, 0.45),
    }
    part(&s, sd_poly(a, wing[..]), 0.20, 0.07, WING)
    part(&s, sd_round_box(a - vec2(0.80, 0.27), vec2(0.024, 0.17), 0.02), 0.26, 0.03, GUN)
    part(&s, sd_round_box(a - vec2(0.29, 0.40), vec2(0.075, 0.26), 0.06), 0.42, 0.08, POD)
    part(&s, sd_poly(q, hull[..]), 0.55, 0.15, HULL)
    dc := sd_ellipse(q - vec2(0.0, -0.33), vec2(0.07, 0.17))
    if dc < 0.0 {
        s.h += 0.12 * (1.0 - sq(1.0 - saturate(-dc / 0.05)))
        s.mat = GLASS
    }
    s
}

priv fn ship_pixel(c: *ShipCtx, p: vec2) -> vec4 {
    s := ship_at(c, p)
    if s.d >= 0.0 {
        return vec4(0.0)
    }
    e := c.texel
    gx := (ship_at(c, p + vec2(e, 0.0)).h - ship_at(c, p - vec2(e, 0.0)).h) / (2.0 * e)
    gy := (ship_at(c, p + vec2(0.0, e)).h - ship_at(c, p - vec2(0.0, e)).h) / (2.0 * e)
    n := normalize(vec3(-gx * 0.35 + c.bank * 0.45, -gy * 0.35, 1.0))
    q := s.q
    ax := fabs(q.x)
    albedo := vec3(0.86, 0.88, 0.92)
    glow := vec3(0.0)
    gloss: f32 = 0.35
    match s.mat {
        HULL => {
            if ax < 0.014 && q.y > -0.15 && q.y < 0.6 { albedo = albedo * 0.5 }      // spine seam
            if fabs(q.y - 0.08) < 0.013 || fabs(q.y - 0.40) < 0.013 { albedo = albedo * 0.6 }
            if q.y < -0.78 { albedo = vec3(0.30, 0.33, 0.38) }                       // nose cone
            if fabs(q.y + 0.60) < 0.035 && ax < 0.12 { albedo = vec3(0.10, 0.75, 1.0); glow = vec3(0.05, 0.35, 0.5) }
        }
        WING => {
            albedo = vec3(0.56, 0.61, 0.70)
            // a cyan stripe along the leading edge
            t := (ax - 0.32) / 0.5
            edge_y := 0.06 + t * 0.32
            if t > 0.06 && t < 0.92 && q.y > edge_y + 0.035 && q.y < edge_y + 0.085 {
                albedo = vec3(0.12, 0.80, 1.0)
                glow = vec3(0.05, 0.40, 0.55)
            }
            if fabs(q.y - 0.53) < 0.012 && ax > 0.36 { albedo = albedo * 0.6 }
        }
        POD => {
            albedo = vec3(0.30, 0.33, 0.40)
            gloss = 0.5
            if q.y > 0.56 { albedo = vec3(0.08, 0.1, 0.12); glow = vec3(0.25, 0.75, 1.0) * saturate((q.y - 0.56) / 0.08) }
        }
        GLASS => {
            albedo = vec3(0.03, 0.08, 0.14)
            glow = vec3(0.05, 0.35, 0.55) * saturate(0.4 + q.y * -1.2)
            gloss = 1.2
        }
        GUN => { albedo = vec3(0.24, 0.26, 0.30) }
        _ => {}
    }
    // navigation lights on the wing tips: red to port, green to starboard
    if length(vec2(ax, q.y) - vec2(0.86, 0.53)) < 0.04 {
        glow = if q.x < 0.0 { vec3(1.0, 0.25, 0.2) } else { vec3(0.3, 1.0, 0.45) }
    }
    col := shade(albedo, n, gloss, if s.mat == GLASS { 40.0 } else { 18.0 }, 0.9)
    edge := smoothstep(-0.05, 0.0, s.d)                            // a dark line around the hull
    vec4(col * (1.0 - edge * 0.55) + glow, 1.0)
}

// ---- flames and lights -------------------------------------------------------------------

priv fn flame_pixel(frame: f32, p: vec2) -> vec4 {
    y := (p.y + 1.0) * 0.5                                         // 0 at the nozzle, 1 at the tip
    width := 0.42 * (1.0 - 0.75 * y) + 0.04
    flick := 0.75 + 0.25 * noise2(p.x * 3.0, y * 5.0 - frame * 1.9, 7)
    i := exp(-sq(p.x / width) * 1.6) * pow(1.0 - y, 1.4) * flick
    hot := saturate(i * 1.6 - 0.45)
    c := lerp(vec3(0.15, 0.45, 1.0), vec3(0.55, 0.95, 1.0), saturate(i * 1.8))
    vec4(lerp(c, vec3(1.0), hot), saturate(i * 1.3))
}

priv fn glow_pixel(k: f32, p: vec2) -> vec4 { vec4(1.0, 1.0, 1.0, exp(-dot(p, p) * k)) }

priv fn streak_pixel(none: i64, p: vec2) -> vec4 {
    along := smoothstep(-1.0, 0.7, p.x) * (1.0 - smoothstep(0.82, 1.0, p.x))
    vec4(1.0, 1.0, 1.0, exp(-sq(p.y) * 9.0) * along)
}

priv fn bolt_pixel(none: i64, p: vec2) -> vec4 {
    t := vec2(p.x * 12.0, p.y * 36.0)                               // texels of the 24 x 72 cell
    y := clamp(t.y, -26.0, 26.0)
    d := length(t - vec2(0.0, y)) - 2.6
    tail := 1.0 - 0.75 * saturate((p.y + 0.3) / 1.3)
    core := saturate(1.0 - d / 1.5)
    halo := exp(-fmax(d, 0.0) / 3.2)
    c := lerp(vec3(0.25, 0.80, 1.0), vec3(1.0), core)
    vec4(c, saturate(fmax(core, halo * 0.85) * tail))
}

priv fn ring_pixel(none: i64, p: vec2) -> vec4 {
    r := length(p)
    a := exp(-sq((r - 0.84) / 0.06)) + 0.35 * exp(-sq((r - 0.78) / 0.16))
    vec4(1.0, 1.0, 1.0, a * (1.0 - smoothstep(0.96, 1.0, r)))
}

priv fn flare_pixel(none: i64, p: vec2) -> vec4 {
    ax := fabs(p.x)
    ay := fabs(p.y)
    spikes := exp(-ax * 38.0) * exp(-ay * 3.2) + exp(-ay * 38.0) * exp(-ax * 3.2)
    a := exp(-dot(p, p) * 30.0) + 0.6 * exp(-dot(p, p) * 6.0) * 0.3 + spikes * 0.75
    vec4(1.0, 1.0, 1.0, a * (1.0 - smoothstep(0.85, 1.0, length(p))))
}

priv fn smoke_pixel(seed: u32, p: vec2) -> vec4 {
    r := length(p)
    n := fbm2(p.x * 2.2 + f32(seed), p.y * 2.2, 4, seed) * 0.5 + 0.5
    a := pow(saturate(1.0 - r * r * (0.8 + 0.5 * n)), 1.6) * (0.35 + 0.65 * n)
    vec4(vec3(0.85 + 0.15 * n), a)
}

priv fn vignette_pixel(none: i64, p: vec2) -> vec4 {
    vec4(1.0, 1.0, 1.0, pow(smoothstep(0.40, 1.45, length(p)), 1.35) * 0.85)
}

priv fn panel_pixel(outline: bool, p: vec2) -> vec4 {
    d := sd_round_box(p * 24.0, vec2(23.0), 11.0)                  // texels of the 48 x 48 cell
    a := if outline { saturate(1.2 - fabs(d + 1.4)) } else { saturate(0.5 - d) }
    vec4(1.0, 1.0, 1.0, a)
}

// ---- asteroids -------------------------------------------------------------------------------

priv struct RockCtx { seed: u32, jag: f32, elong: vec2, base: vec3, craters: [8]vec3, n: i64, texel: f32 }

priv fn rock_ctx(seed: u32, jag: f32, ncraters: i64, texel: f32) -> RockCtx {
    r := rng(u64(seed) * 7919 + 17)
    c := RockCtx{seed: seed, jag: jag, texel: texel, n: ncraters}
    c.elong = vec2(r.range(0.85, 1.0), r.range(0.85, 1.0))
    tones := [4]vec3{vec3(0.50, 0.40, 0.33), vec3(0.54, 0.37, 0.30), vec3(0.42, 0.43, 0.47), vec3(0.58, 0.50, 0.40)}
    c.base = tones[seed % 4] * r.range(0.9, 1.1)
    for i in 0..ncraters {
        at := r.in_circle() * 0.55
        c.craters[i] = vec3(at.x, at.y, r.range(0.08, 0.24))
    }
    c
}

// (height, signed distance to the outline, how deep in a crater)
priv fn rock_at(c: *RockCtx, p: vec2) -> vec3 {
    q := p / c.elong
    r := length(q)
    ang := atan2(q.y, q.x)
    cs := cos(ang)
    sn := sin(ang)
    s := f32(c.seed % 97) * 0.37
    big := c.jag * noise2(cs * 1.3 + s, sn * 1.3 - s, c.seed)
    small := 0.04 * noise2(cs * 4.0 + s, sn * 4.0 + s, c.seed + 1)
    rr := 0.70 + big + small
    t := saturate(r / rr)
    h := sqrt(fmax(1.0 - t * t, 0.0)) * 0.8 + fbm2(p.x * 3.5 + s, p.y * 3.5 - s, 4, c.seed + 2) * 0.07
    cav: f32 = 0.0
    for i in 0..c.n {
        cr := c.craters[i]
        dist := length(p - cr.xy) / cr.z * (1.0 + 0.18 * noise2(p.x * 9.0, p.y * 9.0, c.seed + 5))
        if dist < 1.8 {
            bowl := saturate(1.0 - dist * dist)
            h += cr.z * (-0.6 * bowl + 0.24 * exp(-sq((dist - 1.0) / 0.3)))
            cav = fmax(cav, bowl)
        }
    }
    vec3(h, r - rr, cav)
}

priv fn rock_pixel(c: *RockCtx, p: vec2) -> vec4 {
    f := rock_at(c, p)
    if f.y >= 0.0 {
        return vec4(0.0)
    }
    e := c.texel
    gx := (rock_at(c, p + vec2(e, 0.0)).x - rock_at(c, p - vec2(e, 0.0)).x) / (2.0 * e)
    gy := (rock_at(c, p + vec2(0.0, e)).x - rock_at(c, p - vec2(0.0, e)).x) / (2.0 * e)
    n := normalize(vec3(-gx, -gy, 1.0))
    grain := fbm2(p.x * 6.0, p.y * 6.0, 3, c.seed + 9) * 0.5 + 0.5
    albedo := c.base * (0.75 + 0.5 * grain) * (1.0 - 0.3 * f.z)
    // the rim light only along the outline, from below right
    rim := smoothstep(-0.14, 0.0, f.y) * saturate(dot(normalize(p), vec2(0.45, 0.89)))
    col := shade(albedo, n, 0.06, 8.0, 0.0) + vec3(0.30, 0.60, 1.0) * rim * 0.45
    edge := smoothstep(-0.06, 0.0, f.y)
    vec4(col * (1.0 - 0.35 * edge), 1.0)
}

// ---- planet and nebula ----------------------------------------------------------------------

priv fn planet_pixel(none: i64, p: vec2) -> vec4 {
    rad: f32 = 0.80
    r := length(p)
    l := normalize(vec3(-0.75, -0.45, 0.5))
    if r > rad {
        // the atmosphere outside the disc, brightest on the lit side
        lit := saturate(dot(normalize(p), normalize(l.xy)) * 0.8 + 0.35)
        a := exp(-(r - rad) / 0.035) * lit
        return vec4(0.55, 0.65, 1.0, a * 0.9)
    }
    z := sqrt(fmax(rad * rad - r * r, 0.0)) / rad
    n := vec3(p.x / rad, p.y / rad, z)
    // bands along the tilted latitude, stirred by noise
    tilt := rotate(p, 0.32)
    lat := tilt.y / rad
    warp := fbm2(tilt.x * 2.5, lat * 6.0, 4, 31) * 0.6
    band := sin(lat * 15.0 + warp * 2.4) * 0.5 + 0.5
    fine := fbm2(tilt.x * 6.0, lat * 22.0, 3, 32) * 0.5 + 0.5
    albedo := lerp(vec3(0.42, 0.30, 0.46), vec3(0.88, 0.70, 0.62), band * 0.75 + fine * 0.25)
    storm := exp(-sq((tilt.x - 0.25) / 0.10) - sq((lat - 0.30) / 0.06))
    albedo = lerp(albedo, vec3(0.95, 0.55, 0.42), storm * 0.8)
    diff := smoothstep(-0.12, 0.65, dot(n, l))
    rim := pow(1.0 - z, 3.0) * 0.8
    col := albedo * (0.04 + 0.95 * diff) + vec3(0.40, 0.55, 1.0) * rim * (0.25 + diff)
    vec4(col, saturate((rad - r) * 300.0))
}

// The clouds of the nebula at (x, y) in 0..1: (violet density, teal density, dust).
priv fn nebula_at(x: f32, y: f32) -> vec3 {
    wx := fbm2(x * 2.0, y * 2.0, 4, 11)
    wy := fbm2(x * 2.0 + 5.2, y * 2.0 + 1.3, 4, 12)
    a := fbm2(x * 2.6 + wx * 1.3, y * 2.6 + wy * 1.3, 5, 13)
    b := fbm2(x * 1.7 - wy * 1.1, y * 1.7 + wx * 1.1, 4, 14)
    d := fbm2(x * 5.0 + wx * 2.0, y * 5.0 + wy, 4, 15)
    vec3(a, b, d)
}

priv fn nebula_pixel(none: i64, p: vec2) -> vec4 {
    x := p.x * 0.5 + 0.5
    y := p.y * 0.5 + 0.5
    // seamless from bottom to top: fade into the field one tile further up
    f := lerp(nebula_at(x, y), nebula_at(x, y - 1.0), y)
    ca := smoothstep(-0.25, 0.50, f.x)
    cb := smoothstep(-0.10, 0.55, f.y)
    dust := smoothstep(0.0, 0.45, f.z)
    col := vec3(0.014, 0.016, 0.040)
    col = col + vec3(0.36, 0.09, 0.48) * ca * ca * 1.1
    col = col + vec3(0.03, 0.30, 0.42) * cb * cb * 1.2
    col = col + vec3(1.00, 0.45, 0.55) * pow(ca, 5.0) * 0.55
    col = col * (1.0 - 0.65 * dust * fmax(ca, cb))
    vec4(col, 1.0)
}

// ---- the atlas -----------------------------------------------------------------------------------

// Paints every sprite and uploads the atlas (about half a second of work, most of it the nebula).
fn make_art(g: *Gfx) -> Art {
    m := mark()                                     // the image is only needed until the upload
    img := image_new(ATLAS_W, ATLAS_H, 4)
    pk := Packer{x: PAD, y: PAD}
    a: Art
    a.nebula = cell(&pk, 512, 512)
    paint(&img, a.nebula, 1, 0, nebula_pixel)
    a.planet = cell(&pk, 256, 256)
    paint(&img, a.planet, 2, 0, planet_pixel)
    a.ring = cell(&pk, 128, 128)
    paint(&img, a.ring, 1, 0, ring_pixel)
    for i in 0..SHIP_FRAMES {
        a.ship[i] = cell(&pk, 72, 72)
        c := ShipCtx{bank: f32(i - SHIP_FRAMES / 2) / f32(SHIP_FRAMES / 2), texel: 2.0 / 72.0}
        paint(&img, a.ship[i], 3, &c, ship_pixel)
    }
    for i in 0..ROCKS {
        a.rock[i] = cell(&pk, 96, 96)
        c := rock_ctx(u32(100 + i * 13), 0.09 + 0.02 * f32(i % 3), 4 + i % 4, 2.0 / 96.0)
        paint(&img, a.rock[i], 2, &c, rock_pixel)
    }
    for i in 0..FLAME_FRAMES {
        a.flame[i] = cell(&pk, 32, 64)
        paint(&img, a.flame[i], 2, f32(i), flame_pixel)
    }
    for i in 0..SMOKES {
        a.smoke[i] = cell(&pk, 64, 64)
        paint(&img, a.smoke[i], 1, u32(40 + i), smoke_pixel)
    }
    a.glow = cell(&pk, 64, 64)
    paint(&img, a.glow, 1, f32(5.5), glow_pixel)
    a.flare = cell(&pk, 64, 64)
    paint(&img, a.flare, 2, 0, flare_pixel)
    a.vignette = cell(&pk, 64, 64)
    paint(&img, a.vignette, 1, 0, vignette_pixel)
    a.bolt = cell(&pk, 24, 72)
    paint(&img, a.bolt, 2, 0, bolt_pixel)
    a.panel = cell(&pk, 48, 48)
    paint(&img, a.panel, 2, false, panel_pixel)
    a.frame = cell(&pk, 48, 48)
    paint(&img, a.frame, 2, true, panel_pixel)
    a.core = cell(&pk, 32, 32)
    paint(&img, a.core, 1, f32(12.0), glow_pixel)
    a.streak = cell(&pk, 64, 16)
    paint(&img, a.streak, 2, 0, streak_pixel)
    for i in 0..CHUNKS {
        a.chunk[i] = cell(&pk, 24, 24)
        c := rock_ctx(u32(300 + i * 7), 0.16, 1, 2.0 / 24.0)
        paint(&img, a.chunk[i], 3, &c, rock_pixel)
    }
    a.star = cell(&pk, 16, 16)
    paint(&img, a.star, 1, f32(7.0), glow_pixel)
    bleed(&img, PAD - 1)
    a.tex = g.texture(img, FilterLinear)
    release(m)
    a
}

// A panel of any size from the nine slices of a rounded rectangle cell (corners kept round).
fn nine_slice(g: *Gfx, t: Texture, src: vec4, dst: vec4, corner: f32, tint: u32) {
    k := src.z / 2.0 - 1.0                           // texels of a corner slice
    sx := [4]f32{src.x, src.x + k, src.x + src.z - k, src.x + src.z}
    sy := [4]f32{src.y, src.y + k, src.y + src.w - k, src.y + src.w}
    dx := [4]f32{dst.x, dst.x + corner, dst.x + dst.z - corner, dst.x + dst.z}
    dy := [4]f32{dst.y, dst.y + corner, dst.y + dst.w - corner, dst.y + dst.w}
    for j in 0..3 {
        for i in 0..3 {
            g.sprite(t, vec4(sx[i], sy[j], sx[i + 1] - sx[i], sy[j + 1] - sy[j]),
                vec4(dx[i], dy[j], dx[i + 1] - dx[i], dy[j + 1] - dy[j]), tint)
        }
    }
}
