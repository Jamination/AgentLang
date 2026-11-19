// Drawing the show with std.gfx: procedural art made at start-up, then per frame a bright pass
// and a bloom chain of render textures, the scene above the water, and the screen with its
// reflection. Nothing here changes the show, and nothing allocates per frame.
//
//   glow[0] 640 x 360   bright pass: what emits light (sparks, flashes, the moon, beacons)
//   glow[1..4]          each half the size of the one before: down with a 4-tap blur, then
//                       back up, each level added into the one above (a "dual filter" bloom)
//   scene 1280 x 720    sky, stars, moon, smoke, the skyline in three hazy layers lit by the
//                       bursts, the sparks (additive), and glow[0] added on top
//   screen              the scene above the horizon, then below it the scene mirrored in 2-pixel
//                       strips displaced by travelling ripples, the water's tint, glints of
//                       the bursts and the shore lamps, a vignette, and the HUD
use std.image
use std.gfx

const ATLAS_W = 512
const ATLAS_H = 256
const LEVELS = 5

// Regions of the atlas (x, y, w, h). Every shape is white with its form in alpha, and fades
// to zero before the region's edge, so linear filtering never bleeds between regions.
fn r_spark() -> vec4 { vec4(0.0, 0.0, 32.0, 32.0) }      // a soft point with a hot core
fn r_streak() -> vec4 { vec4(32.0, 0.0, 64.0, 16.0) }    // a tapered tail, its head at the right end
fn r_flare() -> vec4 { vec4(96.0, 0.0, 64.0, 64.0) }     // a four-pointed twinkle
fn r_glow() -> vec4 { vec4(160.0, 0.0, 64.0, 64.0) }     // a wide gaussian
fn r_smoke() -> vec4 { vec4(0.0, 64.0, 128.0, 128.0) }   // a puff of fractal noise
fn r_moon() -> vec4 { vec4(128.0, 64.0, 96.0, 96.0) }    // the crescent moon (in colour)
fn r_cloud() -> vec4 { vec4(256.0, 0.0, 256.0, 96.0) }   // a long, thin wisp of cloud

struct Star { pos: vec2, size: f32, bright: f32, tint: vec3, rate: f32, phase: f32 }
struct Block { r: vec4, layer: i64 }                       // a building or a setback on top of one
struct Spire { base: vec2, half: f32, h: f32, layer: i64 }
struct Win { r: vec4, col: vec3, layer: i64, id: i64 }
struct Cloud { pos: vec2, size: vec2, alpha: f32, speed: f32 }

struct Art {
    atlas: Texture
    scene: Texture
    glow: [LEVELS]Texture
    gw: [LEVELS]f32          // their sizes
    gh: [LEVELS]f32
    stars: Vec[Star]
    blocks: Vec[Block]
    spires: Vec[Spire]
    beacons: Vec[vec2]
    wins: Vec[Win]
    lamps: Vec[vec2]
    clouds: Vec[Cloud]
}

// ---- colour helpers --------------------------------------------------------------------------

fn rgba(c: vec3, a: f32) -> u32 { color_u32(vec4(c, a)) }

// The night sky from the zenith down to the horizon, where the city's light warms it.
fn sky_color(y: f32) -> vec3 {
    t := y / HORIZON
    if t < 0.45 {
        return lerp(vec3(0.006, 0.010, 0.032), vec3(0.020, 0.028, 0.080), t / 0.45)
    }
    if t < 0.80 {
        return lerp(vec3(0.020, 0.028, 0.080), vec3(0.070, 0.055, 0.140), (t - 0.45) / 0.35)
    }
    if t < 0.95 {
        return lerp(vec3(0.070, 0.055, 0.140), vec3(0.200, 0.100, 0.160), (t - 0.80) / 0.15)
    }
    lerp(vec3(0.200, 0.100, 0.160), vec3(0.330, 0.170, 0.150), saturate((t - 0.95) / 0.05))
}

// The three layers of the skyline, far to near: colour and how much burst light they take.
fn layer_color(layer: i64) -> vec3 {
    match layer {
        0 => vec3(0.085, 0.060, 0.125)
        1 => vec3(0.034, 0.030, 0.066)
        _ => vec3(0.010, 0.010, 0.020)
    }
}

fn layer_albedo(layer: i64) -> f32 {
    match layer {
        0 => 0.10
        1 => 0.20
        _ => 0.34
    }
}

// ---- art made at start-up --------------------------------------------------------------------

priv fn texel(img: *Image, r: vec4, fx: i64, fy: i64, c: vec4) {
    img.set(i64(r.x) + fx, i64(r.y) + fy, c)
}

fn make_atlas() -> Image {
    img := image_new(ATLAS_W, ATLAS_H, 4)
    for i in 0..ATLAS_W * ATLAS_H {                  // white everywhere, so filtering mixes in no dark
        img.pix[i * 4] = 255
        img.pix[i * 4 + 1] = 255
        img.pix[i * 4 + 2] = 255
    }
    // spark: a gaussian with a hot pinpoint in the middle
    r := r_spark()
    for y in 0..32 {
        for x in 0..32 {
            d := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(16.0)) / 16.0
            a := fmin(0.55 * exp(-d * d * 7.0) + 0.7 * exp(-d * d * 45.0), 1.0) * (1.0 - smoothstep(0.8, 1.0, d))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, a))
        }
    }
    // streak: thin at the tail (left), wider and brighter towards the head (right)
    r = r_streak()
    for y in 0..16 {
        for x in 0..64 {
            u := saturate((f32(x) + 0.5 - 2.0) / 58.0)
            w := 0.7 + 2.6 * u
            dy := (f32(y) + 0.5 - 8.0) / w
            end := 1.0 - smoothstep(0.93, 1.0, f32(x) / 63.0)
            a := exp(-dy * dy * 1.6) * pow(u, 1.8) * end * (1.0 - smoothstep(0.0, 2.0, 2.0 - f32(x)))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, saturate(a)))
        }
    }
    // flare: two thin crossed rays and a core
    r = r_flare()
    for y in 0..64 {
        for x in 0..64 {
            p := (vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(32.0)) / 32.0
            ax := fabs(p.x)
            ay := fabs(p.y)
            rays := exp(-p.y * p.y * 1400.0) * pow(1.0 - ax, 3.0) + exp(-p.x * p.x * 1400.0) * pow(1.0 - ay, 3.0)
            core := exp(-dot(p, p) * 60.0) + 0.25 * exp(-dot(p, p) * 9.0)
            a := saturate(rays + core) * (1.0 - smoothstep(0.85, 1.0, fmax(ax, ay)))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, a))
        }
    }
    // glow: a wide, soft gaussian that reaches zero at the edge
    r = r_glow()
    k := exp(-4.5)
    for y in 0..64 {
        for x in 0..64 {
            d := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(32.0)) / 31.0
            a := saturate((exp(-d * d * 4.5) - k) / (1.0 - k))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, a))
        }
    }
    // smoke: a round puff whose density is fractal noise
    r = r_smoke()
    for y in 0..128 {
        for x in 0..128 {
            p := vec2(f32(x) + 0.5, f32(y) + 0.5)
            d := length(p - vec2(64.0)) / 62.0
            warp := vec2(fbm2(p.x * 0.02, p.y * 0.02, 3, 4), fbm2(p.x * 0.02 + 5.2, p.y * 0.02 + 1.3, 3, 4)) * 40.0
            n := fbm2((p.x + warp.x) * 0.03, (p.y + warp.y) * 0.03, 5, 3) * 0.5 + 0.5
            a := saturate((1.0 - smoothstep(0.0, 0.95, d)) * (n * 2.6 - 0.75)) * (1.0 - smoothstep(0.85, 0.98, d))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, a))
        }
    }
    // the moon: a sphere lit from behind and to the right (a crescent), with faint maria
    // and the earthshine on its dark side
    r = r_moon()
    light := normalize(vec3(0.95, -0.22, -0.55))
    for y in 0..96 {
        for x in 0..96 {
            p := (vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(48.0)) / 40.0
            cover := saturate((1.0 - length(p)) * 40.0 + 0.5)
            if dot(p, p) > 0.998 {                   // outside: the colour of the rim, for the filter
                p = p / length(p) * 0.999
            }
            n := vec3(p.x, p.y, sqrt(fmax(1.0 - dot(p, p), 0.0)))
            albedo := 0.78 + 0.22 * fbm2(p.x * 3.0 + 7.0, p.y * 3.0, 4, 21)
            lit := smoothstep(-0.02, 0.18, dot(n, light))
            c := vec3(1.0, 0.95, 0.84) * albedo * lit + vec3(0.016, 0.02, 0.032) * albedo
            texel(&img, r, x, y, vec4(c, cover))
        }
    }
    // cloud: a stretched band of fractal noise, thin at the ends
    r = r_cloud()
    for y in 0..96 {
        for x in 0..256 {
            u := (f32(x) + 0.5) / 256.0 * 2.0 - 1.0
            v := (f32(y) + 0.5) / 96.0 * 2.0 - 1.0
            n := fbm2(f32(x) * 0.02, f32(y) * 0.06, 5, 9) * 0.5 + 0.5
            shape := (1.0 - smoothstep(0.4, 1.0, fabs(u))) * (1.0 - smoothstep(0.1, 0.95, fabs(v + 0.15 * sin(u * 3.0))))
            texel(&img, r, x, y, vec4(1.0, 1.0, 1.0, saturate(shape * (n * 2.0 - 0.6))))
        }
    }
    img
}

// The skyline, the stars, the clouds and the lamps on the shore, from a seed of their own.
priv fn make_city(a: *Art, seed: u64) {
    r := rng(seed)
    for layer in 0..3 {
        x := -20.0
        while x < VW + 20.0 {
            w := 0.0
            h := 0.0
            gap := 0.0
            match layer {
                0 => {
                    w = r.range(14.0, 42.0)
                    h = r.range(30.0, 100.0) + (if r.chance(0.12) { 50.0 } else { 0.0 })
                    gap = r.range(0.0, 3.0)
                }
                1 => {
                    w = r.range(22.0, 58.0)
                    h = r.range(40.0, 130.0) + 110.0 * exp(-sq((x - 980.0) / 140.0)) * r.range(0.4, 1.0)
                    gap = r.range(2.0, 14.0)
                }
                _ => {
                    w = r.range(30.0, 82.0)
                    h = r.range(22.0, 95.0) + 230.0 * exp(-sq((x - 660.0) / 150.0)) * r.range(0.45, 1.0) +
                        120.0 * exp(-sq((x - 250.0) / 80.0)) * r.range(0.3, 1.0)
                    gap = r.range(8.0, 46.0)
                }
            }
            x = floor(x)
            w = floor(w)
            h = floor(h)
            top := HORIZON - h
            a.blocks.push(Block{vec4(x, top, w, h), layer})
            windows(a, &r, vec4(x, top, w, h), layer)
            roof := r.below(10)
            if roof <= 2 && w > 24.0 {               // setbacks
                h2 := floor(h * r.range(0.08, 0.16) + 4.0)
                a.blocks.push(Block{vec4(x + floor(w * 0.16), top - h2, floor(w * 0.68), h2), layer})
                if roof == 0 {
                    h3 := floor(h2 * 0.7)
                    a.blocks.push(Block{vec4(x + floor(w * 0.32), top - h2 - h3, floor(w * 0.36), h3), layer})
                    top -= h3
                }
                top -= h2
            }
            if roof == 3 && h > 110.0 {
                a.spires.push(Spire{vec2(x + w * 0.5, top), w * 0.2, h * r.range(0.2, 0.4), layer})
            } else if (roof == 4 || roof == 5) && layer > 0 && h > 70.0 {
                tall := r.range(14.0, 40.0)
                a.spires.push(Spire{vec2(x + w * 0.5, top), 0.8, tall, layer})
                if roof == 4 {
                    a.beacons.push(vec2(x + w * 0.5, top - tall))
                }
            }
            x += w + gap
        }
    }
    // the far shore: a lamp every 20-34 pixels
    lx := 6.0
    while lx < VW {
        a.lamps.push(vec2(lx, HORIZON - 2.5))
        lx += r.range(20.0, 34.0)
    }
    // stars, denser towards the zenith, fewer where the city's glow drowns them
    for i in 0..520 {
        b := pow(r.next_f32(), 3.5)
        warm := r.next_f32()
        a.stars.push(Star{pos: vec2(r.range(0.0, VW), pow(r.next_f32(), 1.5) * (HORIZON - 40.0)), size: 1.1 + 2.6 * b,
            bright: 0.25 + 0.75 * b, tint: lerp(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.88, 0.74), warm),
            rate: r.range(0.6, 3.0), phase: r.range(0.0, TAU)})
    }
    for i in 0..7 {
        a.clouds.push(Cloud{pos: vec2(r.range(-200.0, VW), r.range(50.0, 330.0)), size: vec2(r.range(380.0, 720.0), r.range(40.0, 90.0)),
            alpha: r.range(0.25, 0.5), speed: r.range(2.0, 5.0)})
    }
}

priv fn sq(x: f32) -> f32 { x * x }

// The lit windows of one building: floors that are lit or dark, a warm or a cool building.
priv fn windows(a: *Art, r: *Rng, b: vec4, layer: i64) {
    cw := if layer == 2 { 6.0 } else if layer == 1 { 4.0 } else { 3.0 }
    ch := if layer == 2 { 8.0 } else if layer == 1 { 6.0 } else { 5.0 }
    ww := if layer == 2 { 3.0 } else if layer == 1 { 2.0 } else { 1.0 }
    wh := if layer == 2 { 4.0 } else if layer == 1 { 3.0 } else { 2.0 }
    dim := if layer == 2 { 1.0 } else if layer == 1 { 0.75 } else { 0.5 }
    busy := r.range(0.05, 0.55)
    warm := r.chance(0.7)
    cols := i64((b.z - 4.0) / cw)
    rows := i64((b.w - 8.0) / ch)
    x0 := b.x + floor((b.z - f32(cols) * cw + (cw - ww)) * 0.5)
    for row in 0..rows {
        floor_lit := r.chance(0.6)
        for c in 0..cols {
            if !r.chance(if floor_lit { busy * 1.6 } else { 0.03 }) {
                continue
            }
            tone := if warm != r.chance(0.12) { vec3(1.0, 0.72, 0.40) } else { vec3(0.70, 0.84, 1.0) }
            a.wins.push(Win{vec4(x0 + f32(c) * cw, b.y + 5.0 + f32(row) * ch, ww, wh), tone * dim * r.range(0.45, 1.0), layer, a.wins.len})
        }
    }
}

fn art_new(g: *Gfx, seed: u64) -> Art {
    a := Art{}
    a.atlas = g.texture(make_atlas(), FilterLinear)
    a.scene = g.render_texture(i64(VW), i64(VH), FilterLinear)
    w := VW / 2.0
    h := VH / 2.0
    for i in 0..LEVELS {
        a.gw[i] = w
        a.gh[i] = h
        a.glow[i] = g.render_texture(i64(w), i64(h), FilterLinear)
        w = ceil(w / 2.0)
        h = ceil(h / 2.0)
    }
    make_city(&a, seed)
    a
}

// ---- drawing helpers -------------------------------------------------------------------------

// A region of the atlas centred on p, d pixels across.
fn blob(g: *Gfx, a: *Art, src: vec4, p: vec2, d: f32, tint: u32) {
    g.sprite(a.atlas, src, vec4(p.x - d * 0.5, p.y - d * 0.5, d, d), tint)
}

// A quad with a colour per corner (top left, top right, bottom left, bottom right).
fn grad_quad(g: *Gfx, r: vec4, tl: u32, tr: u32, bl: u32, br: u32) {
    p0 := r.xy
    p1 := vec2(r.x + r.z, r.y)
    p2 := vec2(r.x, r.y + r.w)
    p3 := vec2(r.x + r.z, r.y + r.w)
    g.triangle(p0, p1, p2, tl, tr, bl)
    g.triangle(p1, p3, p2, tr, br, bl)
}

// What a spark looks like now: its colour and brightness. Born white hot, it burns in its own
// colour and cools to a dim red at the end; glitter blinks.
fn spark_look(p: Particle, steps: i64) -> (vec3, f32) {
    t := p.age / p.life
    if p.flags & F_POP != 0 {
        return (p.col, 1.0 - t)
    }
    if p.flags & F_EMBER != 0 {
        return (lerp(p.col, p.col * vec3(1.0, 0.4, 0.2), t), (1.0 - t) * 0.8)
    }
    // white hot for a moment; dimmer while the stars are still packed together, so a fresh
    // burst is a bright knot and not a white ball
    heat := saturate(1.0 - p.age / 0.16)
    c := lerp(p.col, vec3(1.0, 0.97, 0.9), heat * 0.6)
    c = lerp(c, p.col * vec3(1.0, 0.45, 0.25), smoothstep(0.5, 1.0, t) * 0.75)
    b := (1.0 - smoothstep(0.6, 1.0, t)) * (0.4 + 0.6 * smoothstep(0.0, 0.3, p.age))
    if p.flags & F_STROBE != 0 && t > 0.4 {
        on := noise_hash(i64(p.seed), steps / 3, 0, 7) % 6 == 0
        b *= if on { 1.0 } else { 0.05 }
    }
    (c, b)
}

// ---- the bright pass and the bloom chain ------------------------------------------------------

fn bright_pass(g: *Gfx, a: *Art, s: *Show, alpha: f32) {
    g.set_target(a.glow[0])
    g.clear(0xFF000000)
    g.set_transform(xform_scale(vec2(0.5)))
    g.set_blend(BlendAdd)
    blob(g, a, r_glow(), MOON, 90.0, rgba(vec3(0.6, 0.65, 0.8), 0.10))
    for f in s.flashes[..s.nflashes] {
        blob(g, a, r_glow(), f.pos, 170.0 * sqrt(f.power), rgba(f.col, fmin(0.2 * flash_power(f), 0.4)))
    }
    blink := fract(f32(s.time) * 0.6) < 0.35
    if blink {
        for b in a.beacons {
            blob(g, a, r_glow(), b, 16.0, 0xC02020FF)
        }
    }
    for l in a.lamps {
        blob(g, a, r_glow(), l, 12.0, rgba(vec3(1.0, 0.7, 0.4), 0.25))
    }
    for sh in s.shells[..s.nshells] {
        blob(g, a, r_glow(), sh.pos + sh.vel * (alpha * DT), 26.0, rgba(vec3(1.0, 0.7, 0.4), 0.55))
    }
    for p in s.parts[..s.nparts] {
        if p.age < 0.0 {
            continue
        }
        c, b := spark_look(p, s.steps)
        if b < 0.02 {
            continue
        }
        pos := p.pos + p.vel * (alpha * DT)
        if p.flags & F_POP != 0 {
            blob(g, a, r_glow(), pos, 14.0, rgba(c, 0.3 * b))
        } else if p.flags & F_STROBE != 0 && b > 0.5 {
            blob(g, a, r_glow(), pos, 16.0, rgba(c, 0.35 * b))
        } else {
            k := if p.flags & F_EMBER != 0 { 0.10 } else { 0.18 * smoothstep(0.05, 0.5, p.age) }
            blob(g, a, r_glow(), pos, p.size * 9.0, rgba(c, k * b))
        }
    }
}

// Down: each level is the one above at half size, blurred by four taps half a pixel apart.
// Up: each level is added into the one above, stretched (four taps again, to keep it smooth).
fn bloom_chain(g: *Gfx, a: *Art) {
    g.set_blend(BlendAdd)
    for i in 1..LEVELS {
        g.set_target(a.glow[i])
        g.clear(0xFF000000)
        src := vec4(0.0, 0.0, a.gw[i - 1], a.gh[i - 1])
        for k in 0..4 {
            o := vec2(f32(k & 1) - 0.5, f32(k >> 1) - 0.5)
            g.sprite(a.glow[i - 1], src, vec4(o.x, o.y, a.gw[i], a.gh[i]), 0x40FFFFFF)
        }
    }
    for i in LEVELS - 1..=1 by -1 {
        g.set_target(a.glow[i - 1])
        src := vec4(0.0, 0.0, a.gw[i], a.gh[i])
        for k in 0..4 {
            o := vec2(f32(k & 1) * 2.0 - 1.0, f32(k >> 1) * 2.0 - 1.0)
            g.sprite(a.glow[i], src, vec4(o.x, o.y, a.gw[i - 1], a.gh[i - 1]), 0x38FFFFFF)
        }
    }
}
