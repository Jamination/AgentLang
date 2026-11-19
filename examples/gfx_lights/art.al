// The art of the chamber, made in code at start-up: no image files. The whole room is baked
// into one albedo picture (what the surfaces look like under white light): flagstones with
// mortar, bevelled edges, grain, cracks and moss; brick wall tops with a coping rim; carved
// pillars; plank crates; iron torch brackets; a rune circle cut into the floor; ambient
// occlusion where the floor meets anything that stands on it. Besides it: the sprites of the
// lights (a soft glow, a tongue of flame), the glow of the runes and a vignette.
use std.image

const GLOW_SIZE = 128
const FLAME_W = 48
const FLAME_H = 96
const RUNE_SIZE = 352                    // the rune glow textures, centred on ROOM_CENTER
const RUNE_SECTORS = 12

struct Art {
    albedo: Image       // RGBA, VW x VH
    runes: [RUNE_SECTORS]Image   // one channel each: the glow of the carving, by angle (see bake_art)
    glow: Image         // RGBA white, alpha a soft round falloff
    disc: Image         // RGBA white, alpha a disc with an anti-aliased edge
    flame: Image        // RGBA white, alpha a tongue of flame pointing up
    vignette: Image     // RGBA black, alpha darkening towards the corners
}

// A value in [0, 1) for an integer point: per-stone and per-brick randomness without storing it.
fn h01(x: i64, y: i64, seed: u32) -> f32 { f32(noise_hash(x, y, 0, seed) & 0xFFFFFF) / 16777216.0 }

fn seg_dist(p: vec2, a: vec2, b: vec2) -> f32 {
    ab := b - a
    t := saturate(dot(p - a, ab) / fmax(dot(ab, ab), 1e-6))
    length(p - (a + ab * t))
}

// ---- distance fields ----------------------------------------------------------------------

// Distance (in pixels, chamfer 1 / 1.41) from every pixel to the nearest pixel where `src` is
// true. Two passes over the image.
fn distance_field(src: []bool) -> []f32 {
    d := alloc[f32](VW * VH)
    for i in 0..VW * VH {
        d[i] = if src[i] { 0.0 } else { 1e6 }
    }
    for y in 0..VH {
        for x in 0..VW {
            i := y * VW + x
            v := d[i]
            if x > 0 { v = fmin(v, d[i - 1] + 1.0) }
            if y > 0 {
                v = fmin(v, d[i - VW] + 1.0)
                if x > 0 { v = fmin(v, d[i - VW - 1] + 1.4142) }
                if x < VW - 1 { v = fmin(v, d[i - VW + 1] + 1.4142) }
            }
            d[i] = v
        }
    }
    for y in VH - 1..=0 by -1 {
        for x in VW - 1..=0 by -1 {
            i := y * VW + x
            v := d[i]
            if x < VW - 1 { v = fmin(v, d[i + 1] + 1.0) }
            if y < VH - 1 {
                v = fmin(v, d[i + VW] + 1.0)
                if x < VW - 1 { v = fmin(v, d[i + VW + 1] + 1.4142) }
                if x > 0 { v = fmin(v, d[i + VW - 1] + 1.4142) }
            }
            d[i] = v
        }
    }
    d
}

// ---- the floor ----------------------------------------------------------------------------

// Irregular flagstones: the cells of a jittered grid of points (a Voronoi diagram), each the
// stone nearest to its point, the mortar where two cells meet.
const CELL: f32 = 66.0
const CELLS_X = 21                       // VW / CELL, rounded up, plus a border
const CELLS_Y = 13

// A crack: a short jagged polyline over a stone.
struct Crack { pts: [6]vec2, n: i64 }

struct FloorPlan { pts: []vec2, cracks: []Crack }

fn cell_index(ix: i64, iy: i64) -> i64 { (iy + 1) * (CELLS_X + 2) + ix + 1 }

fn floor_plan(r: *Rng) -> FloorPlan {
    n := (CELLS_X + 2) * (CELLS_Y + 2)
    plan := FloorPlan{pts: alloc[vec2](n), cracks: alloc[Crack](n)}
    for iy in -1..CELLS_Y + 1 {
        for ix in -1..CELLS_X + 1 {
            i := cell_index(ix, iy)
            // rows of slightly stretched cells, every other row shifted: closer to laid stone
            // than a plain jittered grid
            shift := if iy % 2 == 0 { 0.0 } else { 0.5 }
            c := vec2((f32(ix) + 0.5 + shift) * CELL * 1.12, (f32(iy) + 0.5) * CELL * 0.9)
            plan.pts[i] = c + vec2(r.range(-0.36, 0.36) * CELL, r.range(-0.26, 0.26) * CELL)
            ck := &plan.cracks[i]
            if r.chance(0.3) {
                p := plan.pts[i] + r.in_circle() * CELL * 0.25
                a := r.range(0.0, TAU)
                ck.n = r.range(3, 7)
                for j in 0..ck.n {
                    ck.pts[j] = p
                    a += r.range(-0.9, 0.9)
                    p = p + vec2(cos(a), sin(a)) * r.range(5.0, 13.0)
                }
            }
        }
    }
    plan
}

const STONE_WARM = vec3(0.50, 0.45, 0.39)
const STONE_COOL = vec3(0.41, 0.42, 0.45)
const MORTAR = vec3(0.2, 0.18, 0.155)
const MOSS = vec3(0.21, 0.28, 0.11)
const DIRT = vec3(0.19, 0.155, 0.12)
const SUN = vec2(-0.7071, -0.7071)       // the bevels are shaded as if lit from the top left

fn floor_px(plan: *FloorPlan, x: i64, y: i64, ao_dist: f32) -> vec3 {
    p := vec2(f32(x) + 0.5, f32(y) + 0.5)
    // the cell whose point is nearest (search the cells around p's own)
    gx := i64(p.x / (CELL * 1.12))
    gy := i64(p.y / (CELL * 0.9))
    best := -1
    bd: f32 = 1e9
    for iy in gy - 1..=gy + 1 {
        for ix in gx - 2..=gx + 1 {
            if ix < -1 || iy < -1 || ix > CELLS_X || iy > CELLS_Y {
                continue
            }
            i := cell_index(ix, iy)
            d := length_sq(plan.pts[i] - p)
            if d < bd {
                bd = d
                best = i
            }
        }
    }
    // distance to the cell's border: to the bisector with each neighbour, blended softly so
    // that the corners round off; and the direction to the nearest border
    a := plan.pts[best]
    sum: f32 = 0.0
    hard: f32 = 1e9
    out := vec2(0.0)
    for iy in gy - 2..=gy + 2 {
        for ix in gx - 3..=gx + 2 {
            if ix < -1 || iy < -1 || ix > CELLS_X || iy > CELLS_Y {
                continue
            }
            i := cell_index(ix, iy)
            if i == best {
                continue
            }
            b := plan.pts[i]
            n := normalize(b - a)
            d := dot((a + b) * 0.5 - p, n)
            if d < 40.0 {
                sum += exp(-d / 1.1)
                if d < hard {
                    hard = d
                    out = n
                }
            }
        }
    }
    e := if sum > 0.0 { -1.1 * log(sum) } else { 40.0 }
    e += noise2(p.x * 0.12, p.y * 0.12, 11) * 1.4 + noise2(p.x * 0.45, p.y * 0.45, 12) * 0.45
    id := best
    moss_n := fbm2(p.x * 0.011, p.y * 0.011, 3, 77)
    col := vec3(0.0)
    if e < 1.4 {
        // mortar: dark, gritty, mossy in damp patches
        grit := noise2(p.x * 0.7, p.y * 0.7, 13) * 0.05
        col = MORTAR + vec3(grit)
        col = lerp(col, MOSS, saturate((moss_n - 0.0) * 3.0) * 0.8)
    } else {
        h1 := h01(id, 1, 5)
        h2 := h01(id, 2, 5)
        base := lerp(STONE_WARM, STONE_COOL, h1) * (0.84 + 0.3 * h2)
        grain := fbm2(p.x * 0.03 + f32(id) * 1.7, p.y * 0.03, 4, 21) * 0.12 + noise2(p.x * 0.33, p.y * 0.33, 22) * 0.04
        col = base * (1.0 + grain)
        // speckles: tiny pits and bright grains of quartz
        s := h01(x, y, 23)
        if s < 0.014 { col = col * 0.7 }
        if s > 0.993 { col = col * 1.2 }
        // each stone sits a little crooked: one side lighter than the other
        tilt := vec2(h01(id, 3, 5) - 0.5, h01(id, 4, 5) - 0.5)
        col = col * (1.0 + dot(p - a, tilt) * 0.004)
        // bevelled edges: the side facing the top left catches the light
        if e < 8.0 {
            t := 1.0 - (e - 1.4) / 6.6
            col = col * (1.0 + dot(out, SUN) * 0.22 * t * t - 0.03 * t)
        }
        // a crack over the stone
        ck := &plan.cracks[id]
        if ck.n > 1 {
            d: f32 = 1e6
            for j in 0..ck.n - 1 {
                d = fmin(d, seg_dist(p, ck.pts[j], ck.pts[j + 1]))
            }
            col = col * (1.0 - 0.55 * (1.0 - smoothstep(0.4, 1.4, d)) - 0.08 * (1.0 - smoothstep(1.4, 3.0, d)))
        }
        // moss creeping in from the joints
        col = lerp(col, MOSS * (0.9 + grain), saturate((moss_n - 0.18) * 2.5) * (1.0 - smoothstep(1.4, 8.0, e)) * 0.85)
    }
    // dirt and occlusion against anything standing on the floor
    near := 1.0 - smoothstep(0.0, 70.0, ao_dist)
    col = lerp(col, DIRT, near * 0.45 * saturate(0.6 + noise2(p.x * 0.05, p.y * 0.05, 31)))
    ao := 0.38 + 0.62 * smoothstep(0.0, 28.0, ao_dist)
    col * ao
}

// The dais the rune circle is cut into: one disc of dark polished stone with pale veins, set
// into the flagstones with a ring of mortar and a bevelled edge. `around`: the floor there.
const DAIS_R: f32 = 166.0
const DAIS_STONE = vec3(0.45, 0.44, 0.48)

fn dais_px(rel: vec2, around: vec3) -> vec3 {
    r := length(rel)
    p := rel + ROOM_CENTER
    if r > DAIS_R + 3.0 {
        return around * (0.75 + 0.25 * smoothstep(DAIS_R + 3.0, DAIS_R + 6.0, r))   // the gap's shadow
    }
    if r > DAIS_R {
        return MORTAR
    }
    vein := 1.0 - smoothstep(0.0, 0.05, fabs(fbm2(p.x * 0.006, p.y * 0.006, 4, 81)))
    vein2 := 1.0 - smoothstep(0.0, 0.03, fabs(fbm2(p.x * 0.013 + 5.0, p.y * 0.013, 3, 82)))
    col := DAIS_STONE * (1.0 + fbm2(p.x * 0.02, p.y * 0.02, 4, 83) * 0.12)
    col = lerp(col, vec3(0.68, 0.66, 0.70), vein * 0.5 + vein2 * 0.25)
    // polished: a little brighter towards the middle; the edge rounded off
    col = col * (1.0 + 0.08 * (1.0 - r / DAIS_R))
    edge := DAIS_R - r
    if edge < 6.0 {
        n := rel / fmax(r, 1.0)
        t := 1.0 - edge / 6.0
        col = col * (1.0 + dot(n, SUN) * 0.35 * t * t)
    }
    col
}

// ---- the rune circle ----------------------------------------------------------------------

const RUNE_R1: f32 = 104.0               // the hexagram's circle
const RUNE_R2: f32 = 118.0               // the runes lie between R2 and R3
const RUNE_R3: f32 = 152.0
const RUNES = 28

// How deep the carving is at p (0: none, 1: the middle of a groove), relative to the centre.
fn rune_mask(p: vec2) -> f32 {
    r := length(p)
    if r > RUNE_R3 + 4.0 {
        return 0.0
    }
    d: f32 = 1e6
    d = fmin(d, fabs(r - RUNE_R1))
    d = fmin(d, fabs(r - RUNE_R2) + 0.4)
    d = fmin(d, fabs(r - RUNE_R3) - 0.6)
    if r < RUNE_R1 + 2.0 {
        // two triangles: lines between every other point of six on the inner circle
        for k in 0..6 {
            a0 := f32(k) * TAU / 6.0 - HALF_PI
            a1 := f32(k + 2) * TAU / 6.0 - HALF_PI
            d = fmin(d, seg_dist(p, vec2(cos(a0), sin(a0)) * RUNE_R1, vec2(cos(a1), sin(a1)) * RUNE_R1))
        }
        d = fmin(d, fabs(r - 30.0) + 0.3)
        d = fmin(d, fabs(r - 14.0) + 0.5)
    }
    for k in 0..6 {
        a := f32(k) * TAU / 6.0 - HALF_PI
        d = fmin(d, fabs(length(p - vec2(cos(a), sin(a)) * RUNE_R1) - 7.0) + 0.3)
    }
    if r > RUNE_R2 && r < RUNE_R3 {
        // a rune per sector: three strokes between points of a 3 x 3 grid
        ang := atan2(p.y, p.x) + PI
        sector := i64(ang / TAU * f32(RUNES)) % RUNES
        ac := (f32(sector) + 0.5) * TAU / f32(RUNES) - PI
        rm := (RUNE_R2 + RUNE_R3) * 0.5
        local := vec2(wrap_angle(atan2(p.y, p.x) - ac) * rm, r - rm)
        for s in 0..3 {
            h := noise_hash(sector, s, 0, 41)
            a := i64(h % 9)
            b := i64((h >> 8) % 9)
            if a == b { b = (b + 4) % 9 }
            pa := vec2(f32(a % 3 - 1) * 5.0, f32(a / 3 - 1) * 9.0)
            pb := vec2(f32(b % 3 - 1) * 5.0, f32(b / 3 - 1) * 9.0)
            d = fmin(d, seg_dist(local, pa, pb))
        }
    }
    1.0 - smoothstep(0.6, 1.9, d)
}

// ---- blocks -------------------------------------------------------------------------------

const BRICK = vec3(0.34, 0.32, 0.33)
const COPING = vec3(0.47, 0.45, 0.43)
const PILLAR_STONE = vec3(0.55, 0.51, 0.46)
const WOOD = vec3(0.56, 0.37, 0.20)
const IRON = vec3(0.21, 0.21, 0.23)

// A wall top: bricks in running bond, a coping rim of lighter stone along the floor.
fn wall_px(x: i64, y: i64, rim: f32) -> vec3 {
    p := vec2(f32(x) + 0.5, f32(y) + 0.5)
    row := y / 18
    off := if row % 2 == 0 { 0 } else { 19 }
    bx := (x + off) / 38
    lx := f32((x + off) % 38) + 0.5
    ly := f32(y % 18) + 0.5
    e := fmin(fmin(lx, 38.0 - lx), fmin(ly, 18.0 - ly)) + noise2(p.x * 0.2, p.y * 0.2, 51) * 0.7
    col := BRICK * (0.82 + 0.3 * h01(bx, row, 52))
    col = col * (1.0 + fbm2(p.x * 0.06, p.y * 0.06, 3, 53) * 0.14)
    if e < 1.6 {
        col = MORTAR * 0.9
    } else if e < 4.0 {
        col = col * (1.0 + (if ly < 9.0 { 0.08 } else { -0.12 }) * (1.0 - (e - 1.6) / 2.4))
    }
    if rim < 16.0 {
        // the coping: blocks of dressed stone along the floor, a bright arris where the wall
        // drops to the floor and a dark joint against the bricks behind
        c := COPING * (0.88 + 0.2 * h01(x / 46, y / 46, 54)) * (1.0 + fbm2(p.x * 0.05, p.y * 0.05, 3, 55) * 0.12)
        if x % 46 < 2 || y % 46 < 2 {
            c = MORTAR
        } else if rim < 3.0 {
            c = c * 1.3
        } else if rim < 5.0 {
            c = c * 1.1
        } else if rim > 13.5 {
            c = c * 0.45
        }
        col = c
    }
    col
}

// A pillar: a square base, a bevelled plinth and a round column top with a carved ring.
fn pillar_px(p: vec2, r: vec4) -> vec3 {
    q := p - vec2(r.x, r.y)
    e := fmin(fmin(q.x, r.z - q.x), fmin(q.y, r.w - q.y))
    m := fmin(q.x, q.y)
    lit := m < fmin(r.z - q.x, r.w - q.y)                 // the half facing the top left
    col := PILLAR_STONE * (1.0 + fbm2(p.x * 0.07, p.y * 0.07, 3, 61) * 0.14)
    c := r.zw * 0.5
    rr := length(q - c)
    if e < 3.0 {
        col = col * (if lit { 1.22 } else { 0.7 })
    } else if e < 5.0 {
        col = col * 0.55
    } else if rr < 22.0 {
        // the column seen from above: shaded like a dome, a carved ring and a cap
        n := (q - c) / 22.0
        col = col * (1.05 + 0.22 * dot(n, vec2(-0.7, -0.7)))
        if fabs(rr - 15.0) < 1.2 { col = col * 0.6 }
        if rr < 4.0 { col = col * 1.1 }
    } else if rr < 24.0 {
        col = col * 0.55                                   // the shadow line around the column
    } else {
        col = col * (if lit { 1.04 } else { 0.92 })
    }
    col
}

// A crate: a frame of dark planks around lighter boards, a diagonal brace, iron corners.
fn crate_px(p: vec2, r: vec4, id: i64) -> vec3 {
    q := p - vec2(r.x, r.y)
    e := fmin(fmin(q.x, r.z - q.x), fmin(q.y, r.w - q.y))
    plank := i64(q.y / 8.0)
    wood := WOOD * (0.8 + 0.3 * h01(id, plank, 71))
    grain := noise2(p.x * 0.08, p.y * 0.9 + f32(plank) * 3.0, 72) * 0.12 + noise2(p.x * 0.4, p.y * 2.0, 73) * 0.05
    col := wood * (1.0 + grain)
    if fract(q.y / 8.0) < 0.13 {
        col = col * 0.45                                   // the gaps between the boards
    }
    // the brace from corner to corner
    if seg_dist(q, vec2(4.0, 4.0), r.zw - vec2(4.0)) < 3.2 {
        col = WOOD * (0.62 + 0.1 * h01(id, 99, 74)) * (1.0 + grain)
    }
    if e < 5.0 {
        col = WOOD * 0.62 * (1.0 + grain)
        if e < 1.2 { col = col * 0.6 }
    }
    // iron corners with a rivet
    corner := fmin(q.x, r.z - q.x) < 8.0 && fmin(q.y, r.w - q.y) < 8.0
    if corner {
        col = IRON * (1.0 + noise2(p.x * 0.5, p.y * 0.5, 75) * 0.1)
        cx := if q.x < r.z * 0.5 { 4.0 } else { r.z - 4.0 }
        cy := if q.y < r.w * 0.5 { 4.0 } else { r.w - 4.0 }
        dd := length(q - vec2(cx, cy))
        if dd < 1.8 { col = vec3(0.5, 0.5, 0.52) }
    }
    col
}

// The iron bracket that holds a torch, from the wall to the flame, ending in a cup: how much
// of it covers p, and a highlight along the bar and the rim of the cup.
fn bracket(p: vec2) -> (f32, f32) {
    m: f32 = 0.0
    shine: f32 = 0.0
    for t in TORCHES {
        // the wall the torch stands at is the nearest side of the room
        dir := vec2(0.0, -1.0)
        if t.x < ROOM_MIN.x + 40.0 { dir = vec2(-1.0, 0.0) }
        if t.x > ROOM_MAX.x - 40.0 { dir = vec2(1.0, 0.0) }
        if t.y > ROOM_MAX.y - 40.0 { dir = vec2(0.0, 1.0) }
        cup := t + dir * 3.0
        d := seg_dist(p, t + dir * 30.0, cup)
        rc := length(p - cup)
        m = fmax(m, fmax(1.0 - smoothstep(2.2, 3.4, d), 1.0 - smoothstep(4.5, 5.8, rc)))
        shine = fmax(shine, fmax(1.0 - smoothstep(0.0, 1.3, d), 1.0 - smoothstep(0.0, 1.0, fabs(rc - 4.0))))
    }
    (m, shine)
}

// ---- the whole room -----------------------------------------------------------------------

fn bake_art(seed: u64) -> Art {
    r := rng(seed)
    plan := floor_plan(&r)
    // which block every pixel belongs to (-1: floor)
    owner := alloc[i16](VW * VH)
    solid := alloc[bool](VW * VH)
    open := alloc[bool](VW * VH)
    for y in 0..VH {
        for x in 0..VW {
            p := vec2(f32(x) + 0.5, f32(y) + 0.5)
            o: i16 = -1
            for bi, b in BLOCKS {
                if p.x >= b.r.x && p.x < b.r.x + b.r.z && p.y >= b.r.y && p.y < b.r.y + b.r.w {
                    o = i16(bi)
                    break
                }
            }
            owner[y * VW + x] = o
            solid[y * VW + x] = o >= 0
            open[y * VW + x] = o < 0
        }
    }
    to_solid := distance_field(solid)                     // floor: how far to the nearest block
    to_floor := distance_field(open)                      // blocks: how far to the floor
    albedo := image_new(VW, VH, 4)
    runes: [RUNE_SECTORS]Image
    for k in 0..RUNE_SECTORS {
        runes[k] = image_new(RUNE_SIZE, RUNE_SIZE, 1)
    }
    for y in 0..VH {
        for x in 0..VW {
            i := y * VW + x
            p := vec2(f32(x) + 0.5, f32(y) + 0.5)
            o := i64(owner[i])
            col := vec3(0.0)
            if o < 0 {
                rel := p - ROOM_CENTER
                col = if length(rel) < DAIS_R + 6.0 { dais_px(rel, floor_px(&plan, x, y, to_solid[i])) } else { floor_px(&plan, x, y, to_solid[i]) }
                if fabs(rel.x) < f32(RUNE_SIZE / 2) && fabs(rel.y) < f32(RUNE_SIZE / 2) {
                    m := rune_mask(rel)
                    if m > 0.0 {
                        col = col * (1.0 - 0.6 * m)
                        rx := x - i64(ROOM_CENTER.x) + RUNE_SIZE / 2
                        ry := y - i64(ROOM_CENTER.y) + RUNE_SIZE / 2
                        if rx >= 0 && rx < RUNE_SIZE && ry >= 0 && ry < RUNE_SIZE {
                            // shared between the two sectors whose middles the angle lies
                            // between: the sectors add up to the whole carving, and a glow
                            // that differs per sector changes smoothly around the circle
                            s := (atan2(rel.y, rel.x) + PI) / TAU * f32(RUNE_SECTORS) - 0.5
                            k0 := i64(floor(s))
                            f := s - floor(s)
                            ka := (k0 + RUNE_SECTORS) % RUNE_SECTORS
                            kb := (k0 + 1 + RUNE_SECTORS) % RUNE_SECTORS
                            runes[ka].pix[ry * RUNE_SIZE + rx] = u8(m * (1.0 - f) * 255.0)
                            runes[kb].pix[ry * RUNE_SIZE + rx] = u8(m * f * 255.0)
                        }
                    }
                }
            } else {
                b := BLOCKS[o]
                col = match b.kind {
                    Wall => wall_px(x, y, to_floor[i])
                    Pillar => pillar_px(p, b.r)
                    Crate => crate_px(p, b.r, o)
                }
            }
            bm, shine := bracket(p)
            if bm > 0.0 {
                col = lerp(col, IRON * (1.0 + 0.7 * shine), bm)
            }
            albedo.set(x, y, vec4(col, 1.0))
        }
    }
    Art{albedo: albedo, runes: runes, glow: glow_image(), disc: disc_image(), flame: flame_image(), vignette: vignette_image()}
}

// One channel of the albedo, inverted: a coverage texture whose alpha is 1 - albedo (see the
// composite in lighting.al).
fn inverse_channel(albedo: Image, c: i64) -> Image {
    img := image_new(albedo.w, albedo.h, 1)
    for i in 0..albedo.w * albedo.h {
        img.pix[i] = 255 - albedo.pix[i * 4 + c]
    }
    img
}

// ---- sprites ------------------------------------------------------------------------------

// White everywhere (no dark fringe under the linear filter), the shape in alpha.
fn glow_image() -> Image {
    img := image_new(GLOW_SIZE, GLOW_SIZE, 4)
    c := f32(GLOW_SIZE) * 0.5
    for y in 0..GLOW_SIZE {
        for x in 0..GLOW_SIZE {
            r := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c)) / c
            q := saturate(1.0 - r)
            a := q * q * (0.55 + 0.45 * q) + 0.35 * exp(-r * r * 60.0)
            img.set(x, y, vec4(1.0, 1.0, 1.0, saturate(a)))
        }
    }
    img
}

fn flame_image() -> Image {
    img := image_new(FLAME_W, FLAME_H, 4)
    for y in 0..FLAME_H {
        for x in 0..FLAME_W {
            // in units of half the width: a round bulb at the bottom drawn out into a tip
            u := (f32(x) + 0.5) / f32(FLAME_W) * 2.0 - 1.0
            v := 1.0 - (f32(y) + 0.5) / f32(FLAME_H)       // 0 at the bottom, 1 at the tip
            yy := v * 4.0
            hw := if yy < 1.0 { sqrt(fmax(0.81 - (yy - 1.0) * (yy - 1.0), 0.0)) } else { 0.9 * pow(saturate(1.0 - (yy - 1.0) / 2.9), 1.4) }
            a := if hw > 0.0 { 1.0 - smoothstep(0.3, 1.0, fabs(u) / hw) } else { 0.0 }
            a = a * (0.6 + 0.4 * (1.0 - v))
            img.set(x, y, vec4(1.0, 1.0, 1.0, saturate(a)))
        }
    }
    img
}

fn vignette_image() -> Image {
    w := 320
    h := 180
    img := image_new(w, h, 4)
    for y in 0..h {
        for x in 0..w {
            q := vec2((f32(x) + 0.5) / f32(w) - 0.5, (f32(y) + 0.5) / f32(h) - 0.5) * vec2(1.7, 1.5)
            a := smoothstep(0.42, 1.08, length(q)) * 0.82
            img.set(x, y, vec4(0.0, 0.0, 0.0, a))
        }
    }
    img
}

const DISC_SIZE = 64

fn disc_image() -> Image {
    img := image_new(DISC_SIZE, DISC_SIZE, 4)
    c := f32(DISC_SIZE) * 0.5
    for y in 0..DISC_SIZE {
        for x in 0..DISC_SIZE {
            r := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c))
            img.set(x, y, vec4(1.0, 1.0, 1.0, saturate(c - 1.0 - r)))
        }
    }
    img
}
