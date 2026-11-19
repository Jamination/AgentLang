// The starter's art, painted at start-up with std.image (no asset files; about 0.3 s): a sprite
// atlas of premultiplied-alpha RGBA8 pixels, four texels per virtual pixel (six for the ship),
// filtered bilinearly by the GPU. It holds the text's glyphs as a distance field (text.al),
// the player's ship in five banking poses, engine flames, asteroids that
// tumble (four kinds, 32 frames each: lumpy, cratered potatoes turning about a tilted axis, lit
// per pixel), debris chips, a gas giant, and the shapes of light: glow, fire, flare, bolt,
// streak, ring, smoke, panel. Next to it a tileable noise texture that the background shader
// turns into nebulae (render.al).
//
// Shapes are signed distance functions, so every edge is anti-aliased; glows are white with
// alpha equal to their brightness and get their colour, and whether they add light or cover
// what is below, from the vertex colour (scene.al).
use std.image
use "text.al"

const TEXELS = 4                  // atlas texels per virtual pixel
const ATLAS_W = 2048
const ATLAS_H = 1536
const ROCK_KINDS = 4
const ROCK_FRAMES = 32
const ROCK_CELL = 96              // texels
const ROCK_R: f32 = 33.0          // texels: the radius of a rock's body before its lumps
const SHIP_TEXELS = 6             // the hero gets more: texels per virtual pixel of the ship
const SHIP_W = 96                 // texels (16 virtual pixels); the ship's origin is the centre
const SHIP_H = 114
const SHIP_POSES = 5              // banking -2 .. 2
const FLAME_FRAMES = 4
const CHIPS = 4
const NEBULA_SIZE = 256

// A rectangle of the atlas in texels.
struct Tile { x: f32, y: f32, w: f32, h: f32 }

struct Art {
    atlas: Image                  // ATLAS_W x ATLAS_H, premultiplied alpha
    nebula: Image                 // NEBULA_SIZE square, tileable: r, g two cloud layers, b dust
    text: TextFont                // the glyphs' distance fields and metrics
    white: Tile                   // solid white (rectangles)
    glow: Tile
    fire: [2]Tile                 // a billowing ball of flame
    flare: Tile
    bolt: Tile
    streak: Tile                  // a line of light, bright head on the right
    ring: Tile
    smoke: [2]Tile
    panel: Tile                   // 9-slice: corners of PANEL_EDGE texels
    panel_line: Tile              // the same rounded rectangle as a glowing outline
    planet: Tile
    ship: [SHIP_POSES]Tile
    flame: [FLAME_FRAMES]Tile
    chips: [CHIPS]Tile
    rocks: [ROCK_KINDS][ROCK_FRAMES]Tile
}

const PANEL_EDGE = 16

// ---- painting helpers ------------------------------------------------------------------------

// Shelf packing: tiles go left to right in rows, with 2 clear texels around each.
priv struct Packer { x: i64, y: i64, row: i64 }

priv fn place(p: *Packer, w: i64, h: i64) -> (i64, i64) {
    if p.x + w + 4 > ATLAS_W {
        p.x = 0
        p.y += p.row
        p.row = 0
    }
    assert p.y + h + 4 <= ATLAS_H, "art: the atlas is full"
    at := (p.x + 2, p.y + 2)
    p.x += w + 4
    p.row = max(p.row, h + 4)
    at
}

priv fn tile_at(at: (i64, i64), w: i64, h: i64) -> Tile { Tile{f32(at.0), f32(at.1), f32(w), f32(h)} }

// Stores a colour with straight alpha as premultiplied RGBA8.
priv fn put(img: *Image, x: i64, y: i64, c: vec3, a: f32) {
    a = saturate(a)
    k := (y * img.w + x) * 4
    p := fmin(fmax(c, vec3(0.0)), vec3(1.0)) * (a * 255.0) + vec3(0.5)
    img.pix[k] = u8(i64(p.x))
    img.pix[k + 1] = u8(i64(p.y))
    img.pix[k + 2] = u8(i64(p.z))
    img.pix[k + 3] = u8(i64(a * 255.0 + 0.5))
}

// Stores an already premultiplied colour: light that covers less than it adds (halos).
priv fn put_premul(img: *Image, x: i64, y: i64, c: vec3, a: f32) {
    k := (y * img.w + x) * 4
    p := fmin(fmax(c, vec3(0.0)), vec3(1.0)) * 255.0 + vec3(0.5)
    img.pix[k] = u8(i64(p.x))
    img.pix[k + 1] = u8(i64(p.y))
    img.pix[k + 2] = u8(i64(p.z))
    img.pix[k + 3] = u8(i64(saturate(a) * 255.0 + 0.5))
}

// A white light of brightness i: what additive sprites are made of.
priv fn put_light(img: *Image, x: i64, y: i64, i: f32) { put(img, x, y, vec3(1.0), i) }

priv fn sd_box(p: vec2, half: vec2, r: f32) -> f32 {
    q := abs(p) - half + vec2(r)
    length(fmax(q, vec2(0.0))) + fmin(fmax(q.x, q.y), 0.0) - r
}

// Signed distance to a closed polygon (negative inside).
priv fn sd_polygon(p: vec2, v: []vec2) -> f32 {
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

priv fn sd_segment(p: vec2, a: vec2, b: vec2) -> f32 {
    pa := p - a
    ba := b - a
    length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)))
}

// Value noise that repeats every `period` cells (a tileable texture), in 0..1.
priv fn tile_noise(x: f32, y: f32, period: i64, seed: u32) -> f32 {
    xi := i64(floor(x))
    yi := i64(floor(y))
    fx := x - floor(x)
    fy := y - floor(y)
    fn corner(x: i64, y: i64, period: i64, seed: u32) -> f32 {
        f32(noise_hash((x % period + period) % period, (y % period + period) % period, 0, seed) & 0xFFFF) / 65535.0
    }
    ux := fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
    uy := fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)
    a := lerp(corner(xi, yi, period, seed), corner(xi + 1, yi, period, seed), ux)
    b := lerp(corner(xi, yi + 1, period, seed), corner(xi + 1, yi + 1, period, seed), ux)
    lerp(a, b, uy)
}

priv fn tile_fbm(x: f32, y: f32, period: i64, octaves: i64, seed: u32) -> f32 {
    sum: f32 = 0.0
    amp: f32 = 0.5
    total: f32 = 0.0
    f: f32 = 1.0
    p := period
    for o in 0..octaves {
        sum += tile_noise(x * f, y * f, p, seed + u32(o) * 17) * amp
        total += amp
        amp *= 0.5
        f *= 2.0
        p *= 2
    }
    sum / total
}

priv fn fbm3(q: vec3, octaves: i64, seed: u32) -> f32 {
    sum: f32 = 0.0
    amp: f32 = 0.5
    p := q
    for o in 0..octaves {
        sum += noise3(p.x, p.y, p.z, seed + u32(o)) * amp
        amp *= 0.5
        p = p * 2.03
    }
    sum
}

// ---- lights ----------------------------------------------------------------------------------

// A ball of flame: a disc frayed and mottled by noise (white; coloured when drawn).
priv fn paint_fire(img: *Image, at: (i64, i64), n: i64, seed: u32) {
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            r := length(p)
            billow := fbm2(p.x * 2.2, p.y * 2.2, 4, seed)
            d := r + billow * 0.45
            body := smoothstep(0.95, 0.25, d)
            mottle := 0.55 + 0.45 * (fbm2(p.x * 5.0 + 3.0, p.y * 5.0, 3, seed + 1) * 0.5 + 0.5)
            put_light(img, at.0 + x, at.1 + y, body * mottle * saturate((1.0 - r) * 5.0))
        }
    }
}

priv fn paint_glow(img: *Image, at: (i64, i64), n: i64) {
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            r2 := dot(p, p)
            i := (exp(-r2 * 5.0) - exp(-5.0)) / (1.0 - exp(-5.0))
            put_light(img, at.0 + x, at.1 + y, if r2 >= 1.0 { 0.0 } else { i })
        }
    }
}

priv fn paint_flare(img: *Image, at: (i64, i64), n: i64) {
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            r := length(p)
            core := exp(-r * r * 60.0) + 0.35 * exp(-r * r * 9.0)
            rays := exp(-fabs(p.y) * 40.0) * (1.0 - fabs(p.x)) + exp(-fabs(p.x) * 40.0) * (1.0 - fabs(p.y))
            put_light(img, at.0 + x, at.1 + y, (core + 0.7 * rays * rays) * saturate((1.0 - r) * 4.0))
        }
    }
}

// A vertical bolt of light: a capsule with a soft edge and a hot centre line.
priv fn paint_bolt(img: *Image, at: (i64, i64), w: i64, h: i64) {
    r := f32(w) / 2.0
    for y in 0..h {
        for x in 0..w {
            p := vec2(f32(x) + 0.5, f32(y) + 0.5)
            d := sd_segment(p, vec2(r, r), vec2(r, f32(h) - r)) / r      // 0 on the axis, 1 at the edge
            i := saturate(1.0 - d)
            put_light(img, at.0 + x, at.1 + y, i * i * (0.6 + 0.4 * exp(-d * d * 12.0)))
        }
    }
}

priv fn paint_streak(img: *Image, at: (i64, i64), w: i64, h: i64) {
    for y in 0..h {
        for x in 0..w {
            u := (f32(x) + 0.5) / f32(w)
            v := (f32(y) + 0.5) / f32(h) * 2.0 - 1.0
            across := exp(-v * v * 5.0) * (1.0 - v * v)
            along := pow(u, 1.6) * saturate((1.0 - u) * 10.0)
            put_light(img, at.0 + x, at.1 + y, across * along)
        }
    }
}

priv fn paint_ring(img: *Image, at: (i64, i64), n: i64) {
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            r := length(p)
            e := (r - 0.84) / 0.07
            i := exp(-e * e) + 0.18 * exp(-(r - 0.75) * (r - 0.75) * 30.0)
            put_light(img, at.0 + x, at.1 + y, i * saturate((1.0 - r) * 12.0))
        }
    }
}

// A puff of smoke: a noisy soft disc (white; tinted dark when drawn).
priv fn paint_smoke(img: *Image, at: (i64, i64), n: i64, seed: u32) {
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            r := length(p)
            wob := fbm2(p.x * 2.5, p.y * 2.5, 4, seed)
            d := saturate(1.0 - r * 1.25 + wob * 0.55)
            a := smoothstep(0.0, 0.8, d) * saturate((1.0 - r) * 6.0)
            shade := 0.75 + 0.25 * saturate(0.5 - p.y * 0.5 - p.x * 0.3 + wob)
            put(img, at.0 + x, at.1 + y, vec3(shade), a * 0.9)
        }
    }
}

// A rounded rectangle filling the tile (inset 8 texels), as a solid or as a glowing outline.
priv fn paint_panel(img: *Image, at: (i64, i64), n: i64, outline: bool) {
    half := f32(n) / 2.0
    for y in 0..n {
        for x in 0..n {
            p := vec2(f32(x) + 0.5 - half, f32(y) + 0.5 - half)
            d := sd_box(p, vec2(half - 8.0), 7.0)
            if outline {
                line := saturate(1.4 - fabs(d))
                glow := exp(-fmax(d, 0.0) * 0.45) * 0.35 * saturate(1.0 + d * 0.15)
                put_light(img, at.0 + x, at.1 + y, line + glow * saturate(d + 1.0))
            } else {
                put(img, at.0 + x, at.1 + y, vec3(1.0), saturate(0.5 - d))
            }
        }
    }
}

// ---- the ship --------------------------------------------------------------------------------
// In ship units (one virtual pixel), +y forward (up the screen), symmetric in x.

priv const HULL = [_]vec2{
    vec2(0.0, 9.0), vec2(1.0, 6.6), vec2(1.9, 3.0), vec2(2.3, -1.5), vec2(2.1, -6.2), vec2(1.3, -7.4),
    vec2(-1.3, -7.4), vec2(-2.1, -6.2), vec2(-2.3, -1.5), vec2(-1.9, 3.0), vec2(-1.0, 6.6),
}
priv const WING = [_]vec2{vec2(1.6, 2.2), vec2(7.2, -3.8), vec2(7.7, -5.9), vec2(6.4, -6.2), vec2(1.6, -4.6)}
priv const POD = vec2(3.2, -5.9)
priv const POD_HALF = vec2(0.85, 1.8)

priv enum Part { PHull, PWing, PPod, PGlass, PNone }

struct ShipSample { d: f32, h: f32, part: Part }

// Distance to the outline, height of the surface and which part a point lies on.
priv fn ship_at(p: vec2) -> ShipSample {
    s := vec2(fabs(p.x), p.y)
    d_hull := sd_polygon(p, HULL[..]) - 0.3
    d_wing := sd_polygon(s, WING[..]) - 0.25
    d_pod := sd_box(s - POD, POD_HALF, 0.7)
    d := fmin(d_hull, fmin(d_wing, d_pod))
    glass := length((p - vec2(0.0, 2.7)) / vec2(0.95, 2.2))
    // heights: a rounded fuselage, wings bevelled at their edges, pods as cylinders
    h_hull := sqrt(saturate(1.0 - (p.x / 2.4) * (p.x / 2.4))) * 1.6 * smoothstep(0.0, 1.2, -d_hull)
    h_wing := smoothstep(0.0, 0.9, -d_wing) * 0.45
    h_pod := sqrt(saturate(1.0 - ((s.x - POD.x) / 0.95) * ((s.x - POD.x) / 0.95))) * 1.0 * smoothstep(0.0, 0.5, -d_pod)
    h := fmax(h_hull, fmax(h_wing, h_pod))
    // the part on top: the highest one, or near the outline the nearest
    part := PWing
    if h > 0.0 {
        if h == h_hull {
            part = PHull
        } else if h == h_pod {
            part = PPod
        }
    } else if d_hull <= d_wing && d_hull <= d_pod {
        part = PHull
    } else if d_pod <= d_wing {
        part = PPod
    }
    if glass < 1.0 {
        part = PGlass
        h += sqrt(1.0 - glass * glass) * 0.7
    }
    ShipSample{d, h, part}
}

// One pose of the ship; `bank` -2 .. 2 (right wing down when positive).
priv fn paint_ship(img: *Image, at: (i64, i64), bank: f32) {
    squash := 1.0 - 0.085 * fabs(bank)
    light := normalize(vec3(-0.45 + 0.28 * bank, 0.55, 0.72))
    half := normalize(light + vec3(0.0, 0.0, 1.0))
    ss := 2
    k := f32(SHIP_TEXELS)
    for y in 0..SHIP_H {
        for x in 0..SHIP_W {
            acc := vec4(0.0)
            for sy in 0..ss {
                for sx in 0..ss {
                    tx := f32(x) + (f32(sx) + 0.5) / f32(ss)
                    ty := f32(y) + (f32(sy) + 0.5) / f32(ss)
                    p := vec2((tx - f32(SHIP_W) / 2.0) / k / squash, (f32(SHIP_H) / 2.0 - ty) / k)
                    c := ship_at(p)
                    cover := saturate(0.5 - c.d * k)
                    if cover <= 0.0 {
                        continue
                    }
                    e: f32 = 0.08
                    gx := (ship_at(p + vec2(e, 0.0)).h - c.h) / e
                    gy := (ship_at(p + vec2(0.0, e)).h - c.h) / e
                    n := normalize(vec3(-gx * squash, -gy, 1.0))
                    col := shade_ship(p, c, n, light, half, bank)
                    acc = acc + vec4(col * cover, cover)
                }
            }
            acc = acc / f32(ss * ss)
            if acc.w > 0.0 {
                put(img, at.0 + x, at.1 + y, acc.xyz / acc.w, acc.w)
            }
        }
    }
}

priv fn shade_ship(p: vec2, c: ShipSample, n: vec3, light: vec3, half: vec3, bank: f32) -> vec3 {
    s := vec2(fabs(p.x), p.y)
    base := vec3(0.80, 0.84, 0.90)
    shine: f32 = 0.55
    gold := vec3(1.0, 0.70, 0.22)
    match c.part {
        PHull => {
            if p.y > 4.0 && p.y < 4.8 || p.y > 7.3 {
                base = gold
            }
            if fabs(p.x) < 0.09 && p.y < 0.4 && p.y > -6.5 {
                base = base * 0.55                            // the spine's panel line
            }
            if fabs(p.y + 2.6) < 0.1 {
                base = base * 0.6
            }
        }
        PWing => {
            base = vec3(0.56, 0.61, 0.72)
            if sd_segment(s, WING[0], WING[1]) < 0.55 || s.x > 6.6 {
                base = gold
            } else if sd_segment(s, vec2(2.6, -1.4), vec2(5.9, -5.0)) < 0.09 {
                base = base * 0.6
            }
            base = base * (1.0 - 0.09 * bank * sign(p.x))   // the lowered wing turns from the light
        }
        PPod => {
            base = vec3(0.30, 0.32, 0.38)
            shine = 0.8
            if p.y < -7.0 {
                base = vec3(1.0, 0.55, 0.25)                   // the hot nozzle
            }
        }
        PGlass => {
            t := saturate(0.5 + (p.y - 2.7) * 0.25 - p.x * 0.2)
            base = lerp(vec3(0.02, 0.10, 0.20), vec3(0.25, 0.85, 1.0), t * t)
            shine = 1.4
        }
        PNone => {}
    }
    diffuse := saturate(dot(n, light) * 0.85 + 0.15)
    spec := pow(saturate(dot(n, half)), 28.0) * shine
    col := base * (0.18 + 0.95 * diffuse) + vec3(spec)
    // a dark rim keeps the silhouette readable over bright explosions
    if c.d > -0.32 {
        col = col * 0.45
    }
    col
}

// ---- engine flames ---------------------------------------------------------------------------

// A flame pointing down from its nozzle at the top, white; frames differ in their flicker.
priv fn paint_flame(img: *Image, at: (i64, i64), w: i64, h: i64, frame: i64) {
    for y in 0..h {
        for x in 0..w {
            u := (f32(x) + 0.5) / f32(w) * 2.0 - 1.0
            v := (f32(y) + 0.5) / f32(h)
            wob := noise2(u * 1.5, v * 5.0 - f32(frame) * 1.7, 31) * 0.25
            width := 0.85 * pow(1.0 - v, 0.55) * (0.55 + 0.45 * saturate(v * 7.0)) * (1.0 + wob)
            body := smoothstep(width, width * 0.25, fabs(u + wob * 0.3 * v))
            i := body * pow(1.0 - v, 1.2) * (0.75 + 0.25 * noise2(u * 3.0, v * 9.0 - f32(frame) * 2.3, 32))
            put_light(img, at.0 + x, at.1 + y, i)
        }
    }
}

// ---- asteroids -------------------------------------------------------------------------------

priv struct Crater { c: vec3, r: f32, depth: f32 }

priv struct RockKind {
    seed: u32
    axis: vec3
    shape: vec3                   // radii of the ellipsoid
    albedo: vec3
    craters: [10]Crater
    n_craters: i64
}

priv fn rock_kind(k: i64) -> RockKind {
    r := rng(u64(1000 + k * 77))
    albedos := [4]vec3{vec3(0.50, 0.43, 0.37), vec3(0.44, 0.43, 0.45), vec3(0.55, 0.38, 0.29), vec3(0.36, 0.35, 0.40)}
    shapes := [4]vec3{vec3(1.0, 0.78, 0.86), vec3(0.92, 0.9, 0.8), vec3(1.0, 0.7, 0.75), vec3(0.95, 0.82, 0.9)}
    kind := RockKind{seed: u32(40 + k * 9), axis: normalize(vec3(r.range(-1.0, 1.0), r.range(-0.6, 0.6), r.range(0.4, 1.0))),
        shape: shapes[k], albedo: albedos[k]}
    kind.n_craters = 6 + k % 3 * 2
    for i in 0..kind.n_craters {
        kind.craters[i] = Crater{r.unit_vec3(), r.range(0.18, 0.45), r.range(0.16, 0.30)}
    }
    kind
}

priv fn rock_height(q: vec3, k: *RockKind) -> f32 {
    h := fbm3(q * 1.7, 3, k.seed) * 0.34
    for i in 0..k.n_craters {
        cr := &k.craters[i]
        x := length(q - cr.c) / cr.r
        if x < 1.7 {
            if x < 1.0 {
                h -= cr.depth * (1.0 - x * x)
            }
            e := (x - 1.0) * 3.2
            h += cr.depth * 0.5 * exp(-e * e)
        }
    }
    h
}

// How far out the silhouette reaches in the object-space direction d (1: the plain sphere).
priv fn rock_reach(d: vec3, k: *RockKind) -> f32 {
    e := d / k.shape
    1.0 / length(e) * (1.0 + 0.22 * fbm3(d * 1.4, 2, k.seed + 20))
}

// One frame of a tumbling rock: the kind turned by `angle` about its axis. Lit from the upper
// left (the key light of the whole scene) with a cool rim light from the nebulae behind.
priv fn paint_rock(img: *Image, at: (i64, i64), k: *RockKind, angle: f32) {
    turn := quat_axis_angle(k.axis, angle)
    back := conjugate(turn)
    light := normalize(vec3(-0.55, 0.6, 0.58))
    rim_dir := normalize(vec2(0.7, -0.7))
    c := f32(ROCK_CELL) / 2.0
    for y in 0..ROCK_CELL {
        for x in 0..ROCK_CELL {
            p := vec2((f32(x) + 0.5 - c) / ROCK_R, (c - f32(y) - 0.5) / ROCK_R)
            r := length(p)
            dir := if r > 0.0 { p / r } else { vec2(1.0, 0.0) }
            reach := rock_reach(back * vec3(dir, 0.0), k)
            cover := saturate((reach - r) * ROCK_R + 0.5)
            if cover <= 0.0 {
                continue
            }
            rho := fmin(r / reach, 0.999)
            v := vec3(dir * rho, sqrt(1.0 - rho * rho))             // on the unit sphere, view space
            q := back * v                                         // the same point on the rock
            t1 := normalize(cross(q, if fabs(q.y) < 0.9 { vec3(0.0, 1.0, 0.0) } else { vec3(1.0, 0.0, 0.0) }))
            t2 := cross(q, t1)
            e: f32 = 0.025
            h := rock_height(q, k)
            d1 := (rock_height(normalize(q + t1 * e), k) - h) / e
            d2 := (rock_height(normalize(q + t2 * e), k) - h) / e
            n := turn * normalize(q - (t1 * d1 + t2 * d2) * 0.38)
            detail := noise3(q.x * 9.0, q.y * 9.0, q.z * 9.0, k.seed + 7) * 0.5 + 0.5
            speck := noise3(q.x * 23.0, q.y * 23.0, q.z * 23.0, k.seed + 8)
            albedo := k.albedo * (0.72 + 0.5 * detail) * (if speck > 0.45 { 1.25 } else { 1.0 })
            ao := saturate(0.8 + h * 1.1)
            diffuse := saturate(dot(n, light) * 0.9 + 0.1)
            spec := pow(saturate(dot(n, normalize(light + vec3(0.0, 0.0, 1.0)))), 12.0) * 0.12
            rim := pow(1.0 - saturate(n.z), 3.5) * saturate(dot(normalize(vec2(n.x, n.y) + vec2(0.0001)), rim_dir) * 0.7 + 0.3)
            col := albedo * (vec3(0.08, 0.085, 0.13) + vec3(1.40, 1.26, 1.08) * diffuse) * ao + vec3(spec)
            col = col + vec3(0.40, 0.50, 0.95) * rim * 0.55
            put(img, at.0 + x, at.1 + y, col, cover)
        }
    }
}

// A chip of rock flying from an explosion: an irregular, faceted polygon.
priv fn paint_chip(img: *Image, at: (i64, i64), n: i64, seed: u64) {
    r := rng(seed)
    corners: [7]vec2
    for i in 0..7 {
        a := f32(i) / 7.0 * TAU + r.range(-0.25, 0.25)
        corners[i] = vec2(cos(a), sin(a)) * r.range(0.55, 0.95)
    }
    light := normalize(vec2(-0.6, -0.8))
    for y in 0..n {
        for x in 0..n {
            p := (vec2(f32(x), f32(y)) + vec2(0.5)) / f32(n) * 2.0 - vec2(1.0)
            d := sd_polygon(p, corners[..])
            cover := saturate(0.5 - d * f32(n) / 2.0)
            if cover <= 0.0 {
                continue
            }
            face := floor((atan2(p.y, p.x) + PI) / TAU * 5.0)
            facet := 0.75 + 0.25 * sin(face * 2.3 + f32(seed))
            lit := saturate(0.55 + dot(p, light) * 0.6) * facet
            put(img, at.0 + x, at.1 + y, vec3(0.62, 0.56, 0.50) * (0.35 + 0.9 * lit), cover)
        }
    }
}

// ---- the gas giant ---------------------------------------------------------------------------

priv fn paint_planet(img: *Image, at: (i64, i64), n: i64) {
    radius := f32(n) * 0.39
    c := f32(n) / 2.0
    light := normalize(vec3(-0.75, 0.45, 0.5))
    tilt := 0.38
    for y in 0..n {
        for x in 0..n {
            p := vec2((f32(x) + 0.5 - c) / radius, (c - f32(y) - 0.5) / radius)
            r := length(p)
            if r >= 1.0 {
                // the atmosphere's halo, only light: on the sunny side
                lit := saturate(dot(p / r, normalize(light.xy)) * 0.6 + 0.4)
                i := exp(-(r - 1.0) * 16.0) * lit * saturate((1.0 - r * 0.78) * 8.0)
                put_premul(img, at.0 + x, at.1 + y, vec3(0.35, 0.55, 1.0) * i * 0.8, i * 0.1)
                continue
            }
            v := vec3(p, sqrt(1.0 - r * r))
            q := vec3(v.x * cos(tilt) - v.y * sin(tilt), v.x * sin(tilt) + v.y * cos(tilt), v.z)
            turb := fbm3(q * 3.0, 4, 77) * 0.9
            lat := q.y * 9.0 + turb
            b := 0.5 + 0.5 * sin(lat * 1.7)
            b2 := 0.5 + 0.5 * sin(lat * 4.3 + 1.0)
            col := lerp(vec3(0.45, 0.28, 0.42), vec3(0.88, 0.62, 0.46), b)
            col = lerp(col, vec3(0.30, 0.20, 0.34), b2 * 0.45)
            storm := length((q.xy - vec2(0.35, -0.28)) / vec2(0.2, 0.09))
            if storm < 1.0 {
                col = lerp(col, vec3(0.95, 0.5, 0.35), (1.0 - storm) * 0.8)
            }
            diffuse := saturate(dot(v, light) * 1.1 + 0.05)
            rim := pow(1.0 - v.z, 3.0) * saturate(dot(normalize(p), normalize(light.xy)) + 0.4)
            out := col * (0.04 + diffuse) + vec3(0.30, 0.50, 1.0) * rim * 0.9
            put(img, at.0 + x, at.1 + y, out, saturate((1.0 - r) * radius + 0.5))
        }
    }
}

// ---- nebula data -----------------------------------------------------------------------------

priv fn paint_nebula() -> Image {
    img := image_new(NEBULA_SIZE, NEBULA_SIZE, 4)
    n := f32(NEBULA_SIZE)
    for y in 0..NEBULA_SIZE {
        for x in 0..NEBULA_SIZE {
            u := f32(x) / n * 4.0
            v := f32(y) / n * 4.0
            // domain warping makes the clouds billow instead of looking like plain noise
            wx := tile_fbm(u, v, 4, 3, 5) * 2.0
            wy := tile_fbm(u + 1.7, v + 9.2, 4, 3, 6) * 2.0
            a := tile_fbm(u + wx, v + wy, 4, 5, 11)
            b := tile_fbm(u * 1.0 + wy * 0.7 + 3.1, v + wx * 0.7, 4, 5, 23)
            d := tile_fbm(u * 2.0, v * 2.0, 8, 4, 37)
            k := (y * NEBULA_SIZE + x) * 4
            // raw values: the shader shapes them after filtering, so edges stay smooth
            img.pix[k] = u8(i64(saturate(a) * 255.0 + 0.5))
            img.pix[k + 1] = u8(i64(saturate(b) * 255.0 + 0.5))
            img.pix[k + 2] = u8(i64(saturate(d) * 255.0 + 0.5))
            img.pix[k + 3] = 255
        }
    }
    img
}

// ---- the whole atlas -------------------------------------------------------------------------

fn make_art() -> Art {
    a: Art
    a.atlas = image_new(ATLAS_W, ATLAS_H, 4)
    img := &a.atlas
    p: Packer
    at := place(&p, TEXT_W, TEXT_H)
    a.text = bake_text(img, at, load_font())
    at = place(&p, 256, 256)
    paint_planet(img, at, 256)
    a.planet = tile_at(at, 256, 256)
    for i in 0..2 {
        at = place(&p, 64, 64)
        paint_fire(img, at, 64, u32(60 + i * 5))
        a.fire[i] = tile_at(at, 64, 64)
    }
    at = place(&p, 8, 8)
    for y in 0..8 {
        for x in 0..8 {
            put(img, at.0 + x, at.1 + y, vec3(1.0), 1.0)
        }
    }
    a.white = Tile{f32(at.0) + 2.0, f32(at.1) + 2.0, 4.0, 4.0}
    at = place(&p, 64, 64)
    paint_glow(img, at, 64)
    a.glow = tile_at(at, 64, 64)
    at = place(&p, 64, 64)
    paint_flare(img, at, 64)
    a.flare = tile_at(at, 64, 64)
    at = place(&p, 16, 48)
    paint_bolt(img, at, 16, 48)
    a.bolt = tile_at(at, 16, 48)
    at = place(&p, 64, 12)
    paint_streak(img, at, 64, 12)
    a.streak = tile_at(at, 64, 12)
    at = place(&p, 128, 128)
    paint_ring(img, at, 128)
    a.ring = tile_at(at, 128, 128)
    for i in 0..2 {
        at = place(&p, 64, 64)
        paint_smoke(img, at, 64, u32(50 + i))
        a.smoke[i] = tile_at(at, 64, 64)
    }
    at = place(&p, 48, 48)
    paint_panel(img, at, 48, false)
    a.panel = tile_at(at, 48, 48)
    at = place(&p, 48, 48)
    paint_panel(img, at, 48, true)
    a.panel_line = tile_at(at, 48, 48)
    for i in 0..SHIP_POSES {
        at = place(&p, SHIP_W, SHIP_H)
        paint_ship(img, at, f32(i - 2))
        a.ship[i] = tile_at(at, SHIP_W, SHIP_H)
    }
    for i in 0..FLAME_FRAMES {
        at = place(&p, 24, 64)
        paint_flame(img, at, 24, 64, i)
        a.flame[i] = tile_at(at, 24, 64)
    }
    for i in 0..CHIPS {
        at = place(&p, 24, 24)
        paint_chip(img, at, 24, u64(90 + i))
        a.chips[i] = tile_at(at, 24, 24)
    }
    for k in 0..ROCK_KINDS {
        kind := rock_kind(k)
        for f in 0..ROCK_FRAMES {
            at = place(&p, ROCK_CELL, ROCK_CELL)
            paint_rock(img, at, &kind, f32(f) / f32(ROCK_FRAMES) * TAU)
            a.rocks[k][f] = tile_at(at, ROCK_CELL, ROCK_CELL)
        }
    }
    a.nebula = paint_nebula()
    a
}
