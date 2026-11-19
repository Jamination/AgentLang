// The art of the software starter (game.al), all of it made by code when the program starts:
// nothing is loaded and nothing is computed per pixel per frame that could be computed here.
//   - a nebula tile that repeats vertically, from domain-warped 3D noise, with the faint far
//     stars baked in; two lists of nearer stars that scroll faster (parallax)
//   - the ship in seven roll angles, painted from polygons with 4 x 4 samples per pixel and a
//     small lighting model (key light from the upper left, a cool rim light from the lower right)
//   - five kinds of asteroid, each pre-lit in 32 turns at three sizes from a radius profile and
//     a height map of craters, plus the glowing cracks a damaged one shows
//   - the engine flame, the shot, and grey masks (glow, shock ring, star flare, smoke) that the
//     effects tint as they draw them
use std.image
use "blit.al"

const PX = 3                         // framebuffer pixels per world unit
const FB_W = WORLD_W * PX            // 960 x 540: the window shows it 1:1
const FB_H = WORLD_H * PX
const BG_H = FB_H * 2                // the nebula repeats every BG_H pixels as it scrolls

const ROCK_KINDS = 5
const ROCK_ANGLES = 32
const ROCK_SIZES = [_]f32{14.0, 20.0, 30.0}   // radii in pixels of the pre-lit rocks
const ROCK_LOOK = 1.12               // drawn radius / collision radius (the outline is lumpy)
const SHIP_FRAMES = 7                // roll from hard left to hard right
const SHIP_ROLL = 0.55               // radians at either end
const SHIP_W = 54
const SHIP_H = 56
const SHIP_SCALE = 1.2               // the ship is drawn at 1.2 times the size of its plan below
const FLAME_FRAMES = 8

// The palette. Space is a deep blue-violet; the player is gold (its colour in logic.al),
// shots and engine are cyan, fire is orange: the warm and cool lights keep things apart.
const SPACE = vec3(0.010, 0.012, 0.035)
const NEB_TEAL = vec3(0.03, 0.34, 0.46)
const NEB_VIOLET = vec3(0.36, 0.06, 0.56)
const NEB_ROSE = vec3(0.95, 0.28, 0.55)
const KEY_LIGHT = vec3(1.05, 0.95, 0.82)
const AMBIENT = vec3(0.10, 0.10, 0.18)
const RIM_LIGHT = vec3(0.35, 0.65, 1.15)
const HULL = vec3(0.80, 0.84, 0.90)
const WING = vec3(0.46, 0.53, 0.68)
const GUNMETAL = vec3(0.24, 0.26, 0.32)
const GOLD = vec3(1.0, 0.80, 0.28)
const CYAN = vec3(0.30, 0.85, 1.0)
const ROCK_TONES = [_]vec3{
    vec3(0.52, 0.44, 0.36), vec3(0.30, 0.29, 0.32), vec3(0.58, 0.34, 0.22),
    vec3(0.60, 0.55, 0.46), vec3(0.36, 0.39, 0.47),
}

struct Star { pos: vec2, speed: f32, size: f32, color: u32, phase: f32 }

struct Art {
    nebula: Sprite               // FB_W x BG_H, opaque
    stars: []Star                // mid layer: points that twinkle
    streaks: []Star              // near layer: fast faint streaks
    glow: Mips                   // soft round light (grey mask)
    ring: Mips                   // shock wave (grey mask)
    flare: Mips                  // star with four spikes (grey mask)
    smoke: []Mips                // puffs (grey masks)
    ship: []Sprite               // SHIP_FRAMES rolls
    ship_white: []Sprite         // the same shapes in white, for the hit flash
    icon: Sprite                 // a small ship for the HUD
    icon_off: Sprite             // a lost one
    flame: []Sprite              // FLAME_FRAMES, additive, the nozzle at the top centre
    shot: Sprite                 // additive, the head at (w / 2, SHOT_HEAD)
    rocks: []Sprite              // [kind][size][angle]
    cracks: []Sprite             // [kind], grey masks at the largest size, unturned
    shards: []Sprite             // pieces of the ship
    vignette: []u32              // per framebuffer pixel: weight 0..=256 that darkens the edges
}

const SHOT_HEAD = 11

fn art_new() -> Art {
    a: Art
    a.nebula = nebula()
    a.stars = star_layer(150, 14.0, 34.0, 1.5, 5.0, 77)
    a.streaks = star_layer(16, 150.0, 280.0, 1.5, 2.6, 78)
    a.glow = mips_of(glow_mask(64))
    a.ring = mips_of(ring_mask(128))
    a.flare = mips_of(flare_mask(32))
    a.smoke = alloc[Mips](3)
    for i in 0..3 {
        a.smoke[i] = mips_of(smoke_mask(64, u32(40 + i)))
    }
    a.ship = alloc[Sprite](SHIP_FRAMES)
    a.ship_white = alloc[Sprite](SHIP_FRAMES)
    for i in 0..SHIP_FRAMES {
        roll := SHIP_ROLL * (f32(i) / f32(SHIP_FRAMES - 1) * 2.0 - 1.0)
        look := ShipLook{roll: roll, scale: SHIP_SCALE, center: vec2(f32(SHIP_W) * 0.5, f32(SHIP_H) * 0.5)}
        a.ship[i] = outlined(paint(SHIP_W, SHIP_H, 4, look, ship_at), vec3(0.02, 0.02, 0.06), 0.85)
        a.ship_white[i] = silhouette(a.ship[i])
    }
    a.icon = outlined(paint(24, 26, 4, ShipLook{scale: 0.55, center: vec2(12.0, 13.5)}, ship_at), vec3(0.0), 0.8)
    a.icon_off = faded(a.icon)
    a.flame = alloc[Sprite](FLAME_FRAMES)
    for i in 0..FLAME_FRAMES {
        a.flame[i] = paint(18, 46, 2, i, flame_at)
    }
    a.shot = paint(21, 58, 2, 0, shot_at)
    a.rocks = alloc[Sprite](ROCK_KINDS * ROCK_SIZES.len * ROCK_ANGLES)
    a.cracks = alloc[Sprite](ROCK_KINDS)
    tmp: Region                                  // the height maps are only needed here
    for k in 0..ROCK_KINDS {
        enter(&tmp)
        shape := rock_shape(k)
        leave()
        for s, r in ROCK_SIZES {
            for t in 0..ROCK_ANGLES {
                a.rocks[(k * ROCK_SIZES.len + s) * ROCK_ANGLES + t] = rock_frame(&shape, r, TAU * f32(t) / f32(ROCK_ANGLES))
            }
        }
        a.cracks[k] = rock_cracks(&shape, ROCK_SIZES[ROCK_SIZES.len - 1], u64(k))
        reset(&tmp)
    }
    region_free(&tmp)
    a.shards = alloc[Sprite](4)
    for i in 0..4 {
        a.shards[i] = paint(11, 11, 4, i, shard_at)
    }
    a.vignette = vignette()
    a
}

// ---- painting ----

// Paints a w x h sprite from a function of the position (pixels, centres at .5) that returns a
// colour with straight alpha; ss x ss samples per pixel smooth the edges.
fn paint[C](w: i64, h: i64, ss: i64, ctx: C, f: fn(C, vec2) -> vec4) -> Sprite {
    s := sprite_new(w, h)
    inv := 1.0 / f32(ss * ss)
    for y in 0..h {
        for x in 0..w {
            acc := vec4(0.0)
            for j in 0..ss {
                for i in 0..ss {
                    c := f(ctx, vec2(f32(x) + (f32(i) + 0.5) / f32(ss), f32(y) + (f32(j) + 0.5) / f32(ss)))
                    acc = acc + vec4(c.xyz * c.w, c.w)
                }
            }
            s.px[y * w + x] = color_u32(acc * inv)
        }
    }
    s
}

// A copy of s with a soft dark rim of one pixel around its shape: it keeps the ship readable
// over bright clouds and explosions.
fn outlined(s: Sprite, rgb: vec3, strength: f32) -> Sprite {
    out := sprite_new(s.w, s.h)
    for y in 0..s.h {
        for x in 0..s.w {
            near: u32 = 0
            for j in -1..=1 {
                for i in -1..=1 {
                    near = max(near, texel(&s, x + i, y + j) >> 24)
                }
            }
            rim := premul(vec4(rgb, f32(near) / 255.0 * strength))
            out.px[y * s.w + x] = over(rim, s.px[y * s.w + x])
        }
    }
    out
}

// White in the shape of s (for an additive flash).
fn silhouette(s: Sprite) -> Sprite {
    out := sprite_new(s.w, s.h)
    for i, p in s.px {
        a := p >> 24
        out.px[i] = a * 0x01010101
    }
    out
}

// s greyed and dimmed: a lost life in the HUD.
fn faded(s: Sprite) -> Sprite {
    out := sprite_new(s.w, s.h)
    for i, p in s.px {
        c := color_vec4(p)
        grey := dot(c.xyz, vec3(0.3, 0.5, 0.2)) * 0.35
        out.px[i] = color_u32(vec4(vec3(grey * 0.8, grey * 0.9, grey * 1.3), c.w * 0.45))
    }
    out
}

// Light falling on a surface with normal n (z towards the viewer).
fn shade(base: vec3, n: vec3, gloss: f32) -> vec3 {
    l := normalize(vec3(-0.45, -0.7, 0.55))
    h := normalize(l + vec3(0.0, 0.0, 1.0))
    diffuse := fmax(dot(n, l), 0.0)
    spec := pow(fmax(dot(n, h), 0.0), 28.0) * gloss
    rim := pow(1.0 - fmax(n.z, 0.0), 2.0) * fmax(dot(vec2(n.x, n.y), vec2(0.6, 0.8)), 0.0)
    base * (AMBIENT + KEY_LIGHT * diffuse) + vec3(spec) + RIM_LIGHT * (rim * 0.7)
}

fn inside(p: vec2, pts: []vec2) -> bool {
    hit := false
    j := pts.len - 1
    for i in 0..pts.len {
        a := pts[i]
        b := pts[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            hit = !hit
        }
        j = i
    }
    hit
}

fn seg_dist(p: vec2, a: vec2, b: vec2) -> f32 {
    ab := b - a
    t := saturate(dot(p - a, ab) / dot(ab, ab))
    length(p - (a + ab * t))
}

// ---- the ship ----

struct ShipLook { roll: f32, scale: f32, center: vec2 }

// The left half of the ship in its own pixels: y down, the nose at y = -22, the engine at 16.
// The right half is the mirror image.
priv HULL_PTS := [_]vec2{
    vec2(0.0, -22.0), vec2(-3.0, -14.0), vec2(-5.4, -3.0), vec2(-5.8, 8.0), vec2(-4.0, 13.0),
    vec2(0.0, 13.0),
}
priv WING_PTS := [_]vec2{vec2(-3.5, -7.0), vec2(-18.0, 5.0), vec2(-18.0, 13.5), vec2(-3.5, 11.0)}
priv ENGINE_PTS := [_]vec2{vec2(-4.6, 8.0), vec2(0.0, 8.0), vec2(0.0, 16.5), vec2(-3.6, 16.5)}
const POD_A = vec2(-17.8, 0.5)       // the wingtip guns: capsules from A to B
const POD_B = vec2(-17.8, 13.0)
const CANOPY = vec2(0.0, -7.5)

// Half the width of the hull at height y (the hull points in order from the nose).
fn hull_half(y: f32) -> f32 {
    for i in 1..HULL_PTS.len - 1 {
        a := HULL_PTS[i - 1]
        b := HULL_PTS[i]
        if y <= b.y {
            return -lerp(a.x, b.x, saturate((y - a.y) / (b.y - a.y)))
        }
    }
    4.0
}

fn rolled(n: vec3, sr: f32, cr: f32) -> vec3 { normalize(vec3(n.x * cr + n.z * sr, n.y, n.z * cr - n.x * sr)) }

fn ship_at(k: ShipLook, p: vec2) -> vec4 {
    sr, cr := sin_cos(k.roll)
    // into the ship's own pixels; a rolled ship is narrower
    q := vec2((p.x - k.center.x) / (k.scale * cr), (p.y - k.center.y) / k.scale)
    side := if q.x < 0.0 { -1.0 } else { 1.0 }
    m := vec2(-fabs(q.x), q.y)               // mirrored into the left half
    out := vec4(0.0)
    if inside(m, WING_PTS[..]) {
        // two facets split along the wing's spine: the front one faces forward, the rear one back
        front := cross(vec2(-18.0, 10.0) - vec2(-3.5, 2.0), m - vec2(-3.5, 2.0)) > 0.0
        n := normalize(vec3(side * 0.25, if front { -0.45 } else { 0.3 }, 1.0))
        base := WING * (1.0 - 0.3 * saturate((-m.x - 5.0) / 13.0))
        gloss := 0.25
        if seg_dist(m, WING_PTS[0], WING_PTS[1]) < 1.3 {
            base = GOLD
            gloss = 0.8
        } else if seg_dist(m, vec2(-5.0, 4.0), vec2(-15.0, 10.5)) < 0.35 {
            base = base * 0.6                // a panel line
        }
        out = vec4(shade(base, rolled(n, sr, cr), gloss), 1.0)
    }
    pod := seg_dist(m, POD_A, POD_B)
    if pod < 1.8 {
        t := -side * (m.x - POD_A.x) / 1.8
        n := vec3(t, -0.2, sqrt(fmax(1.0 - t * t, 0.05)))
        if m.y < 2.2 {
            out = vec4(GOLD * 1.25 + vec3(0.2), 1.0)       // a lit muzzle
        } else {
            out = vec4(shade(GUNMETAL, rolled(n, sr, cr), 0.6), 1.0)
        }
    }
    if inside(m, ENGINE_PTS[..]) {
        t := q.x / 4.6
        n := vec3(t, 0.3, sqrt(fmax(1.0 - t * t, 0.05)))
        out = vec4(shade(GUNMETAL * 0.9, rolled(n, sr, cr), 0.5), 1.0)
        if m.y > 14.8 {
            out = vec4(CYAN * 0.55 + vec3(0.1, 0.1, 0.2), 1.0)  // the glowing nozzle ring
        }
    }
    if inside(m, HULL_PTS[..]) {
        hw := hull_half(q.y)
        t := clamp(q.x / hw, -1.0, 1.0)
        slope := if q.y < -13.0 { -0.7 } else { -0.12 }
        n := normalize(vec3(t * 0.9, slope, sqrt(fmax(1.0 - t * t * 0.81, 0.0))))
        base := HULL
        gloss := 0.7
        band := q.y - 0.55 * fabs(q.x)
        if band > 3.0 && band < 5.0 {
            base = GOLD                      // the chevron
            gloss = 0.9
        } else if (fabs(q.x) < 0.3 && q.y > 0.0) || fabs(q.y + 14.0) < 0.3 || fabs(band - 9.0) < 0.3 {
            base = HULL * 0.55               // panel lines
        }
        out = vec4(shade(base, rolled(n, sr, cr), gloss), 1.0)
    }
    // the canopy: an ellipsoid of dark glass that mirrors the sky; it sits high, so the roll
    // moves it sideways
    d := (q - CANOPY - vec2(sr * 2.0, 0.0)) / vec2(2.7, 6.2)
    r2 := dot(d, d)
    if r2 < 1.0 {
        n := rolled(vec3(d.x, d.y, sqrt(1.0 - r2)), sr, cr)
        sky := smoothstep(0.2, -0.7, n.y + n.x * 0.5)
        glass := vec3(0.02, 0.10, 0.18) + vec3(0.25, 0.75, 1.0) * sky * 0.55
        hl := length(d - vec2(-0.35, -0.5))
        glass = glass + vec3(1.0) * smoothstep(0.32, 0.12, hl)
        if r2 > 0.8 {
            glass = shade(GUNMETAL, n, 0.4)  // the frame
        }
        out = vec4(glass, 1.0)
    }
    out
}

// The engine flame: hot white at the nozzle, cyan, then blue at the tip; the frames differ in
// the noise that makes it lick and flicker.
fn flame_at(frame: i64, p: vec2) -> vec4 {
    x := p.x - 9.0
    y := p.y - 1.0
    t := y / 44.0
    if t < 0.0 || t > 1.0 {
        return vec4(0.0)
    }
    f := f32(frame)
    wobble := noise3(y * 0.09 - f * 1.7, f * 0.61, 3.3, 21) * 1.8 * t
    width := 5.4 * pow(1.0 - t, 0.7) * (0.85 + 0.35 * noise3(y * 0.13, f * 0.9, 0.0, 22)) + 0.4
    across := (x - wobble) / width
    heat := exp(-across * across * 2.2) * pow(1.0 - t, 1.1) * 1.5
    tongue := saturate(0.6 + noise3(x * 0.3, y * 0.11 - f * 2.3, f, 23))
    heat = heat * lerp(0.75, 1.15, tongue)
    rgb := vec3(0.10, 0.25, 1.0) * heat + CYAN * smoothstep(0.25, 0.75, heat) * 0.9 + vec3(0.9) * smoothstep(0.7, 1.15, heat)
    vec4(rgb, fmin(max_component(rgb), 1.0))
}

// The shot: a white-hot head in a cyan glow, its trail fading below it.
fn shot_at(unused: i64, p: vec2) -> vec4 {
    head := vec2(10.5, f32(SHOT_HEAD))
    d := seg_dist(p, head - vec2(0.0, 4.0), head + vec2(0.0, 5.0))
    core := smoothstep(2.4, 1.3, d)
    glow := exp(-d * d / 14.0) * 0.9 + exp(-d * d / 50.0) * 0.25
    trail := 0.0
    if p.y > head.y {
        t := (p.y - head.y) / 44.0
        w := 2.6 * (1.0 - t) + 0.4
        x := p.x - head.x
        trail = exp(-x * x / (w * w)) * pow(saturate(1.0 - t), 1.6) * 1.1
    }
    rgb := vec3(1.0) * core + CYAN * glow + vec3(0.25, 0.65, 1.0) * trail
    rgb = fmin(rgb, vec3(1.0))
    vec4(rgb, fmin(max_component(rgb), 1.0))
}

// A splinter of hull plating, steel or gold.
fn shard_at(kind: i64, p: vec2) -> vec4 {
    r := rng(u64(300 + kind))
    pts := [3]vec2{}
    for i in 0..3 {
        a := TAU * f32(i) / 3.0 + r.range(-0.6, 0.6)
        pts[i] = vec2(5.5, 5.5) + vec2(cos(a), sin(a)) * r.range(2.5, 5.0)
    }
    if !inside(p, pts[..]) {
        return vec4(0.0)
    }
    base := if kind % 2 == 0 { HULL } else { GOLD }
    n := normalize(vec3((p.x - 5.5) * 0.15, (p.y - 5.5) * 0.15, 1.0))
    vec4(shade(base, n, 0.8), 1.0)
}

// ---- masks ----

fn grey(v: f32) -> u32 {
    g := u32(saturate(v) * 255.0 + 0.5)
    g * 0x01010101
}

// A soft round light, zero at the edge.
fn glow_mask(n: i64) -> Sprite {
    s := sprite_new(n, n)
    edge := exp(-4.0)
    for y in 0..n {
        for x in 0..n {
            d := (vec2(f32(x), f32(y)) + 0.5) / f32(n) * 2.0 - 1.0
            r2 := dot(d, d)
            s.px[y * n + x] = grey((exp(-4.0 * r2) - edge) / (1.0 - edge))
        }
    }
    s
}

fn ring_mask(n: i64) -> Sprite {
    s := sprite_new(n, n)
    for y in 0..n {
        for x in 0..n {
            r := length((vec2(f32(x), f32(y)) + 0.5) / f32(n) * 2.0 - 1.0)
            band := (r - 0.84) / 0.07
            fill := smoothstep(0.35, 0.84, r) * 0.18 * step(r, 0.84)
            s.px[y * n + x] = grey(exp(-band * band) + fill)
        }
    }
    s
}

fn flare_mask(n: i64) -> Sprite {
    s := sprite_new(n, n)
    for y in 0..n {
        for x in 0..n {
            d := (vec2(f32(x), f32(y)) + 0.5) / f32(n) * 2.0 - 1.0
            r2 := dot(d, d)
            spikes := exp(-fabs(d.x) * 30.0) * exp(-fabs(d.y) * 3.5) + exp(-fabs(d.y) * 30.0) * exp(-fabs(d.x) * 3.5)
            core := exp(-r2 * 30.0)
            s.px[y * n + x] = grey((core + spikes * 0.7) * smoothstep(1.0, 0.7, sqrt(r2)))
        }
    }
    s
}

fn smoke_mask(n: i64, seed: u32) -> Sprite {
    s := sprite_new(n, n)
    for y in 0..n {
        for x in 0..n {
            d := (vec2(f32(x), f32(y)) + 0.5) / f32(n) * 2.0 - 1.0
            r := length(d)
            billow := fbm2(d.x * 2.2, d.y * 2.2, 4, seed)
            v := smoothstep(1.0, 0.25, r + billow * 0.45) * (0.75 + billow * 0.5)
            s.px[y * n + x] = grey(v)
        }
    }
    s
}

// ---- space ----

fn fbm3(p: vec3, octaves: i64, seed: u32) -> f32 {
    sum := 0.0
    amp := 0.5
    q := p
    for i in 0..octaves {
        sum += amp * noise3(q.x, q.y, q.z, seed + u32(i))
        q = q * 2.03
        amp *= 0.5
    }
    sum
}

// The far background: clouds of gas and dust and countless faint stars, FB_W x BG_H. The top
// and the bottom row join without a seam, so it can scroll for ever.
fn nebula() -> Sprite {
    out := sprite_new(FB_W, BG_H)
    m := mark()
    // the clouds are soft: computed at a third of the resolution, then enlarged
    lw := FB_W / 3
    lh := BG_H / 3
    low := alloc[vec3](lw * lh)
    f := 1.0 / 75.0
    radius := f32(lh) / TAU * f
    for y in 0..lh {
        sa, ca := sin_cos(TAU * f32(y) / f32(lh))
        for x in 0..lw {
            // a cylinder in 3D noise: going round it once is going down the tile once
            p := vec3(f32(x) * f, ca * radius, sa * radius)
            warp := vec3(fbm3(p * 0.6, 3, 11), fbm3(p * 0.6 + 5.2, 3, 12), fbm3(p * 0.6 + 9.7, 3, 17))
            n := fbm3(p + warp * 1.4, 5, 13)
            density := smoothstep(-0.25, 0.55, n)
            hue := smoothstep(-0.18, 0.18, fbm3(p * 0.35 + 2.0, 3, 14))
            cloud := lerp(NEB_TEAL, NEB_VIOLET, hue)
            core := pow(density, 5.0)                            // the bright hearts of the clouds
            ridge := 1.0 - fabs(fbm3(p * 1.8 + warp * 0.8, 4, 15)) * 2.2
            filament := pow(saturate(ridge), 12.0) * density * density
            dust := smoothstep(0.02, 0.35, fbm3(p * 1.3 + 9.0, 4, 16))
            c := cloud * pow(density, 1.8) * 1.5 + lerp(vec3(0.3, 0.9, 1.0), NEB_ROSE, hue) * (filament * 0.45 + core * 0.4)
            c = c * (1.0 - 0.7 * dust)
            // a faint wash of blue so that no part of the sky is dead black
            glow := 0.5 + 0.5 * fbm3(p * 0.25 + 4.0, 2, 18)
            low[y * lw + x] = SPACE + vec3(0.012, 0.014, 0.045) * glow + c
        }
    }
    // enlarged three times with cubic B-spline weights, rows first, then columns: smooth, where
    // straight-line (bilinear) blending would show the grid of the small picture
    wide := alloc[vec3](FB_W * lh)
    for y in 0..lh {
        for x in 0..FB_W {
            f := (f32(x) + 0.5) / 3.0 - 0.5
            x0 := i64(floor(f))
            w := bspline(f - f32(x0))
            sum := vec3(0.0)
            for k in 0..4 {
                sum = sum + low[y * lw + clamp(x0 - 1 + k, 0, lw - 1)] * w[k]
            }
            wide[y * FB_W + x] = sum
        }
    }
    big := alloc[vec3](FB_W * BG_H)
    for y in 0..BG_H {
        f := (f32(y) + 0.5) / 3.0 - 0.5
        y0 := i64(floor(f))
        w := bspline(f - f32(y0))
        for x in 0..FB_W {
            sum := vec3(0.0)
            for k in 0..4 {
                sum = sum + wide[((y0 - 1 + k) % lh + lh) % lh * FB_W + x] * w[k]   // (wrapping)
            }
            big[y * FB_W + x] = sum
        }
    }
    // the far stars: most faint, a few bright; colours from blue-white to orange
    r := rng(5)
    for i in 0..2600 {
        at := vec2(r.range(0.0, f32(FB_W)), r.range(0.0, f32(BG_H)))
        b := pow(r.next_f32(), 7.0) * 1.3 + 0.03
        tint := star_tint(r.next_f32())
        splat(big, at, 0.45 + b * 0.5, tint * b)
    }
    for i in 0..18 {
        at := vec2(r.range(0.0, f32(FB_W)), r.range(0.0, f32(BG_H)))
        tint := star_tint(r.next_f32())
        splat(big, at, 1.6, tint * 0.25)
        splat(big, at, 0.6, tint * 1.4)
        len := r.range(5.0, 11.0)
        for k in 1..i64(len) {
            fade := pow(1.0 - f32(k) / len, 2.0) * 0.35
            for dir in [_]vec2{vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0)} {
                splat(big, at + dir * f32(k), 0.45, tint * fade)
            }
        }
    }
    // to 8 bits with a little noise: dark gradients would show bands otherwise
    for i in 0..FB_W * BG_H {
        dither := (r.next_f32() - r.next_f32()) / 255.0
        out.px[i] = color_u32(vec4(linear_ish(big[i]) + vec3(dither), 1.0))
    }
    release(m)
    out
}

// The weights of the four samples around a point a fraction t past the second one.
fn bspline(t: f32) -> [4]f32 {
    u := 1.0 - t
    [4]f32{u * u * u / 6.0, (3.0 * t * t * t - 6.0 * t * t + 4.0) / 6.0, (3.0 * u * u * u - 6.0 * u * u + 4.0) / 6.0, t * t * t / 6.0}
}

// A gentle highlight roll-off: bright cores stay coloured instead of clipping to white.
fn linear_ish(c: vec3) -> vec3 { c / (vec3(1.0) + c * 0.25) * 1.25 }

fn star_tint(t: f32) -> vec3 {
    if t < 0.45 {
        vec3(0.75, 0.85, 1.0)
    } else if t < 0.8 {
        vec3(1.0, 0.97, 0.92)
    } else if t < 0.93 {
        vec3(1.0, 0.85, 0.62)
    } else {
        vec3(1.0, 0.62, 0.45)
    }
}

// Adds a small gaussian of light at a sub-pixel position (wrapping vertically).
fn splat(buf: []vec3, at: vec2, sigma: f32, rgb: vec3) {
    reach := i64(ceil(sigma * 2.5))
    cx := i64(floor(at.x))
    cy := i64(floor(at.y))
    total := 0.0
    for j in -reach..=reach {
        for i in -reach..=reach {
            d := vec2(f32(cx + i) + 0.5, f32(cy + j) + 0.5) - at
            total += exp(-dot(d, d) / (2.0 * sigma * sigma))
        }
    }
    for j in -reach..=reach {
        for i in -reach..=reach {
            x := cx + i
            if x < 0 || x >= FB_W {
                continue
            }
            y := ((cy + j) % BG_H + BG_H) % BG_H
            d := vec2(f32(cx + i) + 0.5, f32(cy + j) + 0.5) - at
            w := exp(-dot(d, d) / (2.0 * sigma * sigma)) / total * fmin(sigma * sigma * 2.0, 1.0) * 2.0
            buf[y * FB_W + x] = buf[y * FB_W + x] + rgb * w
        }
    }
}

fn star_layer(n: i64, slow: f32, fast: f32, small: f32, large: f32, seed: u64) -> []Star {
    r := rng(seed)
    stars := alloc[Star](n)
    for i in 0..n {
        t := r.next_f32()
        b := 0.35 + 0.65 * pow(r.next_f32(), 2.0)
        stars[i] = Star{
            pos: vec2(r.range(0.0, f32(FB_W)), r.range(0.0, f32(FB_H + 40))),
            speed: lerp(slow, fast, t),
            size: lerp(small, large, pow(r.next_f32(), 3.0)),
            color: light(star_tint(r.next_f32()), b),
            phase: r.range(0.0, TAU),
        }
    }
    stars
}

// Weights 0..=256 per framebuffer pixel: 1 in the middle, darker towards the corners.
fn vignette() -> []u32 {
    v := alloc[u32](FB_W * FB_H)
    for y in 0..FB_H {
        for x in 0..FB_W {
            d := (vec2(f32(x), f32(y)) + 0.5) / vec2(f32(FB_W), f32(FB_H)) * 2.0 - 1.0
            r := length(d * vec2(1.0, 0.8))
            v[y * FB_W + x] = u32((1.0 - 0.6 * smoothstep(0.45, 1.3, r)) * 256.0)
        }
    }
    v
}

// ---- asteroids ----

const HMAP = 64                      // height map resolution over the square [-1.2, 1.2]^2

struct RockShape {
    outline: [256]f32                // radius by angle, 1 at the widest
    height: []f32                    // HMAP x HMAP, in rock radii
    tone: []f32                      // brightness of the surface, the same grid
    base: vec3
}

fn rock_shape(kind: i64) -> RockShape {
    r := rng(u64(1000 + kind * 17))
    s: RockShape
    s.base = ROCK_TONES[kind % ROCK_TONES.len]
    // lumps: a few harmonics with random phases
    amps: [8]f32
    phases: [8]f32
    for h in 2..8 {
        amps[h] = r.range(0.02, 0.11) / pow(f32(h), 0.5)
        phases[h] = r.range(0.0, TAU)
    }
    widest := 0.0
    for i in 0..256 {
        a := TAU * f32(i) / 256.0
        v := 1.0
        for h in 2..8 {
            v += amps[h] * sin(f32(h) * a + phases[h])
        }
        v += 0.035 * noise2(cos(a) * 3.0, sin(a) * 3.0, u32(kind + 50))
        s.outline[i] = v
        widest = fmax(widest, v)
    }
    for i in 0..256 {
        s.outline[i] = s.outline[i] / widest
    }
    // craters: (centre, radius, depth)
    craters := vec[vec4]()
    for i in 0..r.range(4, 7) {
        craters.push(vec4(r.range(-0.6, 0.6), r.range(-0.6, 0.6), r.range(0.16, 0.36), 0.0))
    }
    for i in 0..r.range(7, 12) {
        craters.push(vec4(r.range(-0.8, 0.8), r.range(-0.8, 0.8), r.range(0.05, 0.12), 0.0))
    }
    s.height = alloc[f32](HMAP * HMAP)
    s.tone = alloc[f32](HMAP * HMAP)
    seed := u32(kind * 7 + 3)
    for y in 0..HMAP {
        for x in 0..HMAP {
            p := (vec2(f32(x), f32(y)) / f32(HMAP - 1) * 2.0 - 1.0) * 1.2
            h := fbm2(p.x * 2.2, p.y * 2.2, 4, seed) * 0.10 + fbm2(p.x * 9.0, p.y * 9.0, 2, seed + 9) * 0.012
            floor_dark := 0.0
            for c in craters {
                d := length(p - c.xy) / c.z
                if d < 1.0 {
                    h += c.z * 0.45 * (d * d - 1.0)              // the bowl
                    floor_dark = fmax(floor_dark, 1.0 - d)
                }
                rim := (d - 1.0) / 0.22
                h += c.z * 0.18 * exp(-rim * rim)                // the raised rim
            }
            s.height[y * HMAP + x] = h
            grain := 0.9 + 0.2 * noise2(p.x * 16.0, p.y * 16.0, seed + 6)
            s.tone[y * HMAP + x] = (0.92 + 0.32 * fbm2(p.x * 1.6, p.y * 1.6, 3, seed + 4)) * (1.0 - 0.3 * floor_dark) * grain
        }
    }
    s
}

// A grid value at a position in rock radii (bilinear).
fn grid(g: []f32, p: vec2) -> f32 {
    f := (clamp(p, vec2(-1.2), vec2(1.2)) / 1.2 * 0.5 + 0.5) * f32(HMAP - 1)
    x := min(i64(f.x), HMAP - 2)
    y := min(i64(f.y), HMAP - 2)
    wx := f.x - f32(x)
    wy := f.y - f32(y)
    a := lerp(g[y * HMAP + x], g[y * HMAP + x + 1], wx)
    b := lerp(g[(y + 1) * HMAP + x], g[(y + 1) * HMAP + x + 1], wx)
    lerp(a, b, wy)
}

fn outline_at(s: *RockShape, a: f32) -> f32 {
    f := fract(a / TAU) * 256.0
    i := i64(f) & 255
    lerp(s.outline[i], s.outline[(i + 1) & 255], f - floor(f))
}

fn rock_size(r: f32) -> i64 { i64(ceil(r)) * 2 + 4 }

// The rock lit from the upper left, turned by `angle` (its features turn, the light does not).
fn rock_frame(s: *RockShape, r: f32, angle: f32) -> Sprite {
    n := rock_size(r)
    out := sprite_new(n, n)
    sn, cs := sin_cos(angle)
    key := normalize(vec3(-0.55, -0.7, 0.5))
    fill := normalize(vec3(0.5, 0.7, 0.3))
    centre := f32(n) * 0.5
    e := 0.04
    for y in 0..n {
        for x in 0..n {
            d := vec2(f32(x) + 0.5 - centre, f32(y) + 0.5 - centre)
            l := vec2(cs * d.x + sn * d.y, cs * d.y - sn * d.x) / r      // in the rock's own frame
            rho := length(l)
            edge := outline_at(s, atan2(l.y, l.x))
            cover := saturate((edge - rho) * r + 0.5)
            if cover <= 0.0 {
                continue
            }
            // a sphere squashed to the outline, then the slopes of the height map on it
            q := fmin(rho / edge, 1.0)
            nrm := vec3(d.x / (edge * r), d.y / (edge * r), sqrt(fmax(1.0 - q * q, 0.0)) + 0.12)
            gx := (grid(s.height, l + vec2(e, 0.0)) - grid(s.height, l - vec2(e, 0.0))) / (2.0 * e)
            gy := (grid(s.height, l + vec2(0.0, e)) - grid(s.height, l - vec2(0.0, e))) / (2.0 * e)
            slope := vec2(cs * gx - sn * gy, sn * gx + cs * gy)          // back to the screen
            nrm = normalize(nrm - vec3(slope.x, slope.y, 0.0) * 0.9)
            h := grid(s.height, l)
            ao := clamp(1.0 + h * 2.5, 0.45, 1.08)
            albedo := s.base * grid(s.tone, l)
            diffuse := pow(saturate((dot(nrm, key) + 0.05) / 1.05), 1.3)
            bounce := saturate(dot(nrm, fill)) * 0.22
            rim := pow(1.0 - saturate(nrm.z), 4.0) * saturate(dot(normalize(vec2(nrm.x, nrm.y)), vec2(0.55, 0.83)))
            c := albedo * (KEY_LIGHT * diffuse * 1.05 + vec3(0.32, 0.18, 0.42) * bounce + AMBIENT * 0.45) * ao
            c = c + RIM_LIGHT * rim * 0.7
            out.px[y * n + x] = premul(vec4(fmin(c, vec3(1.0)), cover))
        }
    }
    out
}

// Glowing cracks for a damaged rock, as a grey mask unturned at radius r.
fn rock_cracks(s: *RockShape, r: f32, seed: u64) -> Sprite {
    rand := rng(seed * 31 + 7)
    segs := vec[vec4]()
    start := rand.in_circle() * 0.25
    for b in 0..4 {
        p := start
        dir := TAU * f32(b) / 4.0 + rand.range(-0.5, 0.5)
        for k in 0..8 {
            dir += rand.range(-0.6, 0.6)
            next := p + vec2(cos(dir), sin(dir)) * rand.range(0.1, 0.17)
            if length(next) > outline_at(s, atan2(next.y, next.x)) * 0.9 {
                break
            }
            segs.push(vec4(p.x, p.y, next.x, next.y))
            p = next
        }
    }
    n := rock_size(r)
    out := sprite_new(n, n)
    centre := f32(n) * 0.5
    for y in 0..n {
        for x in 0..n {
            l := vec2(f32(x) + 0.5 - centre, f32(y) + 0.5 - centre) / r
            d := 99.0
            for sg in segs {
                d = fmin(d, seg_dist(l, sg.xy, sg.zw))
            }
            d = d * r                                            // in pixels
            v := exp(-d * d / 0.8) + 0.35 * exp(-d * d / 9.0)
            inner := smoothstep(0.0, 0.1, outline_at(s, atan2(l.y, l.x)) - length(l))
            out.px[y * n + x] = grey(v * inner)
        }
    }
    out
}

// ---- the HUD ----

// The game-over panel: dark glass with rounded corners and a warm double border.
fn panel_sprite(w: i64, h: i64) -> Sprite { paint(w, h, 2, vec2(f32(w), f32(h)), panel_at) }

fn panel_at(size: vec2, p: vec2) -> vec4 {
    // distance to the edge of a rounded rectangle (negative inside)
    half := size * 0.5 - vec2(2.0)
    q := fabs(p - size * 0.5) - (half - vec2(16.0))
    d := length(fmax(q, vec2(0.0))) + fmin(fmax(q.x, q.y), 0.0) - 16.0
    if d > 0.0 {
        return vec4(0.0)
    }
    t := p.y / size.y
    c := vec4(lerp(vec3(0.05, 0.05, 0.13), vec3(0.03, 0.02, 0.06), t), 0.84)
    if d > -2.5 {
        c = vec4(lerp(vec3(1.0, 0.85, 0.45), vec3(0.9, 0.35, 0.12), t), 1.0)   // the border
    } else if d > -6.0 && d < -5.0 {
        c = vec4(vec3(0.9, 0.45, 0.2) * 0.45, 0.9)                           // the inner line
    }
    c
}
