// Crypt's surface materials, painted at start-up from noise (no image files): stone blocks for
// the walls, flagstones for the floor and a coffered wooden ceiling. Each is a height field
// first; the albedo, the roughness and the normal map are derived from it, so the colours,
// the shine and the relief agree (mortar is low, rough and dark; puddles are low, smooth and
// dark; bevelled stone edges catch the light). Every texture tiles: the noise is periodic over
// the tile. Pure AL (std.image only), so it runs anywhere; render.al uploads the result.
use std.image

const TEX_SIZE = 512
const MAT_FLOOR = 0
const MAT_WALL = 1
const MAT_CEILING = 2
const MATERIALS = 3

// One material, TEX_SIZE square. albedo: RGB colour (sRGB-encoded), A: roughness (0 mirror,
// 1 chalk). normal: RGB the tangent-space normal (x along u, y along v, z out of the surface,
// each * 0.5 + 0.5), A: how open the relief is (cavity occlusion: 0 deep in a crack, 1 on top).
struct Material { albedo: Image, normal: Image }

// ---- noise -----------------------------------------------------------------------------------

// A well-mixed 64-bit hash of a lattice point and a seed (splitmix64's finaliser).
priv fn hash3(x: i64, y: i64, s: i64) -> u64 {
    h := u64(x) * 0x9E3779B97F4A7C15 + u64(y) * 0xC2B2AE3D27D4EB4F + u64(s) * 0x165667B19E3779F9
    h ^= h >> 31
    h *= 0xBF58476D1CE4E5B9
    h ^= h >> 29
    h *= 0x94D049BB133111EB
    h ^ (h >> 32)
}

// A random number 0..1 for a lattice point.
priv fn rnd(x: i64, y: i64, s: i64) -> f32 { f32(hash3(x, y, s) >> 40) / 16777216.0 }

priv fn wrapi(i: i64, p: i64) -> i64 { ((i % p) + p) % p }

// Value noise 0..1 with a period of px x py lattice cells (so a tile of them wraps seamlessly).
priv fn noise(x: f32, y: f32, px: i64, py: i64, s: i64) -> f32 {
    fx := floor(x)
    fy := floor(y)
    ix := i64(fx)
    iy := i64(fy)
    tx := x - fx
    ty := y - fy
    tx = tx * tx * (3.0 - 2.0 * tx)
    ty = ty * ty * (3.0 - 2.0 * ty)
    x0 := wrapi(ix, px)
    x1 := wrapi(ix + 1, px)
    y0 := wrapi(iy, py)
    y1 := wrapi(iy + 1, py)
    a := lerp(rnd(x0, y0, s), rnd(x1, y0, s), tx)
    b := lerp(rnd(x0, y1, s), rnd(x1, y1, s), tx)
    lerp(a, b, ty)
}

// Fractal noise 0..1 over the tile (u, v in 0..1): `octaves` layers of value noise, each of
// twice the frequency and half the weight of the one before; the first has px x py cells.
priv fn fbm(u: f32, v: f32, px: i64, py: i64, octaves: i64, s: i64) -> f32 {
    sum: f32 = 0.0
    amp: f32 = 0.5
    norm: f32 = 0.0
    fx := px
    fy := py
    for o in 0..octaves {
        sum += amp * noise(u * f32(fx), v * f32(fy), fx, fy, s + o * 101)
        norm += amp
        amp *= 0.5
        fx *= 2
        fy *= 2
    }
    sum / norm
}

// Thin bright lines where the noise crosses its middle: cracks and veins (0..1, 1 on a line).
priv fn ridge(u: f32, v: f32, px: i64, py: i64, s: i64) -> f32 {
    n := fbm(u, v, px, py, 4, s)
    r := 1.0 - fabs(n * 2.0 - 1.0)
    r * r * r * r * r
}

// ---- from height to normal map ---------------------------------------------------------------

// The normal map of a height field (n x n, wrapping): the normal is (-dh/du, -dh/dv, 1)
// scaled by `strength`, the slopes taken with a Sobel filter (3 x 3 texels), so that an edge in
// the height turns the normal over a few texels rather than one (one-texel creases alias into
// stair-stepped black seams when a wall is seen up close). A holds the cavity term: the height
// compared with its neighbourhood.
priv fn normal_map(h: []f32, n: i64, strength: f32) -> Image {
    img := image_new(n, n, 4)
    for y in 0..n {
        for x in 0..n {
            ym := wrapi(y - 1, n) * n
            y0 := y * n
            yp := wrapi(y + 1, n) * n
            xm := wrapi(x - 1, n)
            xp := wrapi(x + 1, n)
            dx := (h[ym + xm] + 2.0 * h[y0 + xm] + h[yp + xm] - h[ym + xp] - 2.0 * h[y0 + xp] - h[yp + xp]) * 0.25
            dy := (h[ym + xm] + 2.0 * h[ym + x] + h[ym + xp] - h[yp + xm] - 2.0 * h[yp + x] - h[yp + xp]) * 0.25
            nv := normalize(vec3(dx * strength, dy * strength, 1.0))
            // cavity: lower than the average of a wider ring of neighbours is darker
            ring: f32 = 0.0
            for k in 0..8 {
                a := f32(k) * 0.785398
                ring += h[wrapi(y + i64(round(sin(a) * 5.0)), n) * n + wrapi(x + i64(round(cos(a) * 5.0)), n)]
            }
            cav := saturate(0.8 + (h[y * n + x] - ring / 8.0) * 2.2)
            img.set(x, y, vec4(nv.x * 0.5 + 0.5, nv.y * 0.5 + 0.5, nv.z * 0.5 + 0.5, cav))
        }
    }
    img
}

// ---- the walls: courses of stone blocks ----------------------------------------------------

// The wall tile spans one cell (2 m) across and the full wall height (2.4 m) up: five courses
// of blocks in running bond, three or four blocks a course, with chipped bevelled edges,
// cracks, recessed mortar, and damp creeping up from the floor with streaks running down.
priv fn make_wall() -> Material {
    n := TEX_SIZE
    h := alloc[f32](n * n)
    alb := image_new(n, n, 4)
    courses := 5
    for y in 0..n {
        v := (f32(y) + 0.5) / f32(n)
        course := min(i64(v * f32(courses)), courses - 1)
        cv := v * f32(courses) - f32(course)
        blocks := 3 + i64(hash3(course, 7, 1) % 2)
        offset := rnd(course, 3, 2)
        for x in 0..n {
            u := (f32(x) + 0.5) / f32(n)
            wob := (fbm(u, v, 6, 6, 2, 11) - 0.5) * 0.05
            bu := fract(u + offset + wob) * f32(blocks)
            block := min(i64(bu), blocks - 1)
            bx := bu - f32(block)
            id := course * 8 + block
            // distance to the nearest joint, in texels, with chipped edges
            ex := fmin(bx, 1.0 - bx) * f32(n) / f32(blocks)
            ey := fmin(cv, 1.0 - cv) * f32(n) / f32(courses)
            chip := (fbm(u, v, 20, 20, 4, 5) - 0.5) * 5.0 - 2.5 * smoothstep(0.6, 0.85, fbm(u, v, 9, 9, 3, 6))
            edge := fmin(ex, ey) + chip
            mortar: f32 = 3.0
            // soft transitions (a few texels): a hard step aliases when magnified
            bevel := smoothstep(mortar, mortar + 10.0, edge)
            stone := smoothstep(mortar - 2.0, mortar + 2.0, edge)
            grain := fbm(u, v, 16, 16, 5, 21)
            pits := fbm(u, v, 64, 64, 3, 23)
            crack := ridge(u, v, 5, 5, 31 + id) * smoothstep(0.55, 0.8, rnd(id, 9, 4))
            // a block's face is not flat: each tilted its own way, with a broad undulation
            tilt := ((rnd(id, 1, 6) - 0.5) * (bx - 0.5) + (rnd(id, 2, 6) - 0.5) * (cv - 0.5)) * 0.3
            hm := 0.08 + 0.06 * fbm(u, v, 32, 32, 3, 41)
            hs := 0.6 + 0.3 * bevel + 0.22 * (grain - 0.5) + 0.08 * (pits - 0.5) + tilt - 0.3 * crack
            height := lerp(hm, hs, stone)
            h[y * n + x] = height

            // colour: grey, brownish and ochre stones, mottled, darker at the joints
            k := rnd(id, 5, 7)
            base := lerp(vec3(0.42, 0.40, 0.37), vec3(0.31, 0.32, 0.34), k)
            if rnd(id, 6, 8) > 0.75 {
                base = vec3(0.44, 0.39, 0.32)
            }
            base = base * (0.8 + 0.35 * rnd(id, 10, 8))
            mottle := 0.7 + 0.45 * fbm(u, v, 12, 12, 4, 51) + 0.25 * (pits - 0.5)
            speck := 0.92 + 0.16 * rnd(x, y, 77)
            col := base * mottle * speck * (0.85 + 0.15 * smoothstep(0.0, 10.0, edge)) * (1.0 - 0.35 * crack)
            mcol := vec3(0.33, 0.31, 0.27) * (0.8 + 0.35 * fbm(u, v, 40, 40, 3, 61)) * speck
            col = lerp(mcol, col, stone)
            // damp: rising from the floor, and streaks running down from the joints
            streak := noise(u * 28.0, v * 2.0, 28, 2, 71)
            wet := saturate(smoothstep(0.62, 1.0, v) * 1.3 + (streak - 0.62) * 2.2 * v)
            wet = saturate(wet * (0.6 + 0.6 * fbm(u, v, 8, 8, 3, 81)))
            moss := saturate(wet * 1.6 - 0.5) * (1.0 - stone * 0.6) * smoothstep(0.4, 0.7, fbm(u, v, 10, 10, 4, 91))
            col = lerp(col, vec3(0.17, 0.21, 0.12), moss * 0.8)
            col = col * (1.0 - 0.38 * wet)
            rough := lerp(0.95, 0.68 + 0.18 * grain, stone)
            rough = lerp(rough, 0.28, wet * 0.85)
            alb.set(x, y, vec4(col, rough))
        }
    }
    Material{alb, normal_map(h, n, 5.0)}
}

// ---- the floor: flagstones ------------------------------------------------------------------

// Irregular flagstones from a Voronoi pattern of 3 x 3 jittered points per tile (one cell of
// the maze): each slab tilted and coloured its own way, sunk grout between them, worn surface,
// and puddles in the low places, which are dark and smooth (they mirror the torches).
priv fn make_floor() -> Material {
    n := TEX_SIZE
    h := alloc[f32](n * n)
    alb := image_new(n, n, 4)
    g := 3
    for y in 0..n {
        v := (f32(y) + 0.5) / f32(n)
        for x in 0..n {
            u := (f32(x) + 0.5) / f32(n)
            p := vec2(u * f32(g), v * f32(g)) + vec2(fbm(u, v, 8, 8, 2, 3) - 0.5, fbm(u, v, 8, 8, 2, 4) - 0.5) * 0.12
            cx := i64(floor(p.x))
            cy := i64(floor(p.y))
            // the nearest feature point
            best: f32 = 1.0e9
            fa := vec2(0.0)
            ida := 0
            for dy in -1..2 {
                for dx in -1..2 {
                    i := cx + dx
                    j := cy + dy
                    wi := wrapi(i, g)
                    wj := wrapi(j, g)
                    f := vec2(f32(i) + 0.2 + 0.6 * rnd(wi, wj, 13), f32(j) + 0.2 + 0.6 * rnd(wi, wj, 14))
                    d := length_sq(f - p)
                    if d < best {
                        best = d
                        fa = f
                        ida = wj * g + wi
                    }
                }
            }
            // the distance to the border with the other slabs
            border: f32 = 1.0e9
            for dy in -2..3 {
                for dx in -2..3 {
                    i := cx + dx
                    j := cy + dy
                    wi := wrapi(i, g)
                    wj := wrapi(j, g)
                    f := vec2(f32(i) + 0.2 + 0.6 * rnd(wi, wj, 13), f32(j) + 0.2 + 0.6 * rnd(wi, wj, 14))
                    e := f - fa
                    if length_sq(e) < 0.0001 {
                        continue
                    }
                    border = fmin(border, dot((fa + f) * 0.5 - p, normalize(e)))
                }
            }
            bt := border * f32(n) / f32(g)                   // in texels
            grout: f32 = 3.5
            slab := smoothstep(grout - 2.0, grout + 2.0, bt)
            bevel := smoothstep(grout, grout + 12.0, bt)
            rel := p - fa
            tilt := (rel.x * (rnd(ida, 1, 15) - 0.5) + rel.y * (rnd(ida, 2, 15) - 0.5)) * 0.35
            wear := fbm(u, v, 10, 10, 5, 25)
            crack := ridge(u, v, 4, 4, 35 + ida) * smoothstep(0.5, 0.75, rnd(ida, 3, 15))
            hs := 0.55 + 0.3 * bevel + tilt + 0.16 * (wear - 0.5) - 0.3 * crack
            hg := 0.08 + 0.05 * fbm(u, v, 48, 48, 2, 45)
            height := lerp(hg, hs, slab)
            // puddles fill the low places
            pool := smoothstep(0.58, 0.66, fbm(u, v, 3, 3, 4, 55))
            water := 0.5
            wet := pool * smoothstep(water + 0.1, water - 0.05, height)
            height = fmax(height, water * pool)
            h[y * n + x] = height

            k := rnd(ida, 4, 16)
            base := lerp(vec3(0.38, 0.35, 0.31), vec3(0.31, 0.31, 0.32), k) * (0.85 + 0.3 * rnd(ida, 5, 16))
            speck := 0.92 + 0.16 * rnd(x, y, 78)
            col := base * (0.75 + 0.45 * wear) * speck * (0.82 + 0.18 * smoothstep(0.0, 12.0, bt)) * (1.0 - 0.35 * crack)
            gcol := vec3(0.22, 0.2, 0.17) * (0.8 + 0.4 * fbm(u, v, 32, 32, 3, 65))
            col = lerp(gcol, col, slab)
            col = col * (1.0 - 0.5 * fmax(wet, pool * 0.35))
            rough := lerp(0.9, 0.62 + 0.25 * wear, slab)
            rough = lerp(rough, 0.06, wet)
            rough = lerp(rough, 0.4, pool * (1.0 - wet) * 0.6)
            alb.set(x, y, vec4(col, rough))
        }
    }
    Material{alb, normal_map(h, n, 6.0)}
}

// ---- the ceiling: dark boards between beams --------------------------------------------------

// A coffered ceiling: a beam along every edge of a cell (so they meet where the cells meet)
// and boards between them, with grain, seams and a darkening of soot towards the middle.
priv fn make_ceiling() -> Material {
    n := TEX_SIZE
    h := alloc[f32](n * n)
    alb := image_new(n, n, 4)
    planks := 7
    for y in 0..n {
        v := (f32(y) + 0.5) / f32(n)
        for x in 0..n {
            u := (f32(x) + 0.5) / f32(n)
            // the beams: distance from the tile edge, in texels
            eu := fmin(u, 1.0 - u) * f32(n)
            ev := fmin(v, 1.0 - v) * f32(n)
            beam_w: f32 = 34.0
            on_u := smoothstep(beam_w + 2.0, beam_w - 2.0, eu)    // a beam along v at the u edges
            on_v := smoothstep(beam_w + 2.0, beam_w - 2.0, ev)
            beam := fmax(on_u, on_v)
            // the boards between: along u, with seams and a random shift each
            pv := v * f32(planks)
            plank := min(i64(pv), planks - 1)
            within := pv - f32(plank)
            seam := smoothstep(0.0, 0.06, fmin(within, 1.0 - within))
            sh := rnd(plank, 1, 17)
            grain := fbm(fract(u + sh), v, 4, 64, 4, 27 + plank)
            rings := 0.5 + 0.5 * sin((grain * 9.0 + u * 3.0) * 6.2832)
            board_h := 0.35 + 0.1 * seam + 0.06 * rings
            // the grain of the beams runs along them
            bgrain := if on_u > on_v { fbm(u, v, 64, 4, 4, 37) } else { fbm(u, v, 4, 64, 4, 47) }
            beam_edge := fmin(fabs(eu - beam_w), fabs(ev - beam_w))
            beam_h := 0.85 + 0.08 * bgrain - 0.15 * smoothstep(6.0, 0.0, beam_edge) * (1.0 - fmin(on_u, on_v))
            height := lerp(board_h, beam_h, beam)
            h[y * n + x] = height

            wood := vec3(0.26, 0.17, 0.11) * (0.75 + 0.35 * grain) * (0.85 + 0.15 * rings) * (0.85 + 0.3 * sh)
            wood = wood * (0.55 + 0.45 * seam)
            bwood := vec3(0.3, 0.21, 0.14) * (0.7 + 0.5 * bgrain)
            col := lerp(wood, bwood, beam)
            // soot from the torches darkens the middle of each bay
            soot := smoothstep(0.1, 0.45, fmin(fmin(u, 1.0 - u), fmin(v, 1.0 - v))) * (1.0 - beam)
            col = col * (1.0 - 0.35 * soot * fbm(u, v, 6, 6, 3, 57))
            alb.set(x, y, vec4(col, 0.7 + 0.2 * grain))
        }
    }
    Material{alb, normal_map(h, n, 5.0)}
}

// The three materials in the order MAT_FLOOR, MAT_WALL, MAT_CEILING.
fn make_materials() -> [MATERIALS]Material {
    [MATERIALS]Material{make_floor(), make_wall(), make_ceiling()}
}
