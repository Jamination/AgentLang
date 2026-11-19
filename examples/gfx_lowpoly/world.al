// The landscape of examples/gfx_lowpoly: an endless heightfield of fractal noise, the material
// of every facet (sand, grass, forest, rock, snow by height and slope), the trees and rocks
// standing on it, and ring caches of the vertices and cells around the camera, so that the
// noise is computed only for the rows and columns that come into view. There is a cache per
// level of detail: cells of 1, 2 and 4 units (LEVELS), each cache addressed in its own grid
// units. Heights are in world units. Nothing here draws: render.al reads the cells.

const SEA_LEVEL: f32 = 0.0
const LEVELS = 3
const RING = 256                         // cache slots per axis: a power of two above 2 * VIEW + 6
const EMPTY_KEY = 0x7FFF_FFFF_FFFF_FFFF  // no cell has this key

// What stands on a cell (only cells of level 0 carry objects).
const OBJ_NONE = 0
const OBJ_PINE = 1
const OBJ_ROUND = 2
const OBJ_ROCK = 3

// Corners of a cell, indices into Cell.h: 0 (x, z), 1 (x + 1, z), 2 (x, z + 1), 3 (x + 1, z + 1).
// The two triangles A and B for each diagonal: from corner 0 to 3, or from corner 1 to 2.
const TRI_CORNERS = [12]i64{0, 2, 3, 0, 3, 1, 0, 2, 1, 1, 2, 3}
const CORNER_X = [4]f32{0.0, 1.0, 0.0, 1.0}
const CORNER_Z = [4]f32{0.0, 0.0, 1.0, 1.0}

// One cell of a cache: its corner heights, the colour and normal of its two triangles, how
// much of the sun reaches them, and the object on it.
struct Cell {
    key: i64
    flip: bool            // diagonal from corner 1 to 2 instead of 0 to 3
    h: [4]f32
    alb: [2]vec3          // material colour of triangles A and B
    nrm: [2]vec3
    sun_ver: i64          // the sun direction the shadows were computed for
    shadow: [4]f32        // at each corner: 1 in full sun, 0 in shadow
    obj: i64
    opos: vec3            // where it stands
    osize: f32
    ohash: u32
}

// One level of detail: vertices `step` units apart.
struct Grid {
    step: i64
    vkey: []i64           // the cached vertex heights, slot by (x, z) modulo RING
    vh: []f32
    cells: []Cell
}

struct World {
    seed: u32
    grids: [LEVELS]Grid
    sun: vec3             // towards the sun, for the shadows
    sun_ver: i64
}

fn world_new(seed: u32) -> World {
    w := World{seed: seed, sun: vec3(0.0, 1.0, 0.0), sun_ver: 1}
    for l in 0..LEVELS {
        gr := &w.grids[l]
        gr.step = 1 << l
        gr.vkey = alloc[i64](RING * RING)
        gr.vh = alloc[f32](RING * RING)
        gr.cells = alloc[Cell](RING * RING)
        fill(gr.vkey, EMPTY_KEY)
        for i in 0..gr.cells.len {
            gr.cells[i].key = EMPTY_KEY
        }
    }
    w
}

// A new light direction: the shadows of the cached cells are computed again when next drawn.
fn world_set_sun(w: *World, sun: vec3) {
    if sun != w.sun {
        w.sun = sun
        w.sun_ver += 1
    }
}

priv inline fn key(x: i64, z: i64) -> i64 {
    (x << 32) ^ (z & 0xFFFF_FFFF)
}

priv inline fn slot(x: i64, z: i64) -> i64 {
    (z & (RING - 1)) * RING + (x & (RING - 1))
}

// A number in [0, 1) from a hash.
inline fn unit(h: u32) -> f32 {
    f32(i64(h >> 8)) * (1.0 / 16777216.0)
}

// The height of the land at (x, z): a continental field decides between basins (lakes),
// rolling lowland and mountain ranges; the ranges are ridged multifractal noise (sharp crests,
// smooth valleys), the lowland gentle hills.
fn terrain_height(seed: u32, x: f32, z: f32) -> f32 {
    c := fbm2(x * 0.0042 + 17.3, z * 0.0042 - 4.1, 4, seed) * 1.6
    ridge: f32 = 0.0
    amp: f32 = 1.0
    weight: f32 = 1.0
    f: f32 = 0.017
    for o in 0..5 {
        n := 1.0 - fabs(noise2(x * f, z * f, seed + 7 + u32(o)))
        n = n * n * weight
        weight = saturate(n * 1.8)
        ridge += n * amp
        amp = amp * 0.5
        f = f * 2.03
    }
    hills := fbm2(x * 0.035 + 3.7, z * 0.035, 3, seed + 31)
    mountains := smoothstep(-0.3, 0.45, c)
    lowland := c * 11.0 + 1.6 + hills * 3.0
    lowland + mountains * mountains * ridge * 24.0
}

// The cached height of vertex (x, z) of level l (grid units).
fn vheight(w: *World, l: i64, x: i64, z: i64) -> f32 {
    gr := &w.grids[l]
    s := slot(x, z)
    k := key(x, z)
    if gr.vkey[s] != k {
        gr.vkey[s] = k
        gr.vh[s] = terrain_height(w.seed, f32(x * gr.step), f32(z * gr.step))
    }
    gr.vh[s]
}

// The height of the faceted surface of level l at world (x, z), interpolated in the triangle
// of the cell that holds the point (what an object standing there touches).
fn ground(w: *World, l: i64, x: f32, z: f32) -> f32 {
    sc := 1.0 / f32(w.grids[l].step)
    gx := x * sc
    gz := z * sc
    ix := i64(floor(gx))
    iz := i64(floor(gz))
    u := gx - f32(ix)
    v := gz - f32(iz)
    h00 := vheight(w, l, ix, iz)
    h10 := vheight(w, l, ix + 1, iz)
    h01 := vheight(w, l, ix, iz + 1)
    h11 := vheight(w, l, ix + 1, iz + 1)
    if cell_flip(w.seed, l, ix, iz) {
        if u + v <= 1.0 { h00 + (h10 - h00) * u + (h01 - h00) * v } else { h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v) }
    } else {
        if u >= v { h00 + (h10 - h00) * u + (h11 - h10) * v } else { h00 + (h01 - h00) * v + (h11 - h01) * u }
    }
}

// The diagonal of each cell is chosen at random: the facets look hand-made, not like a grid.
fn cell_flip(seed: u32, l: i64, x: i64, z: i64) -> bool {
    noise_hash(x, z, 1 + l, seed) & 1 == 1
}

// The cell (x, z) of level l, filled on first use; its shadows are brought up to the sun.
fn cell_at(w: *World, l: i64, x: i64, z: i64) -> *Cell {
    c := &w.grids[l].cells[slot(x, z)]
    if c.key != key(x, z) {
        cell_fill(w, l, c, x, z)
    }
    if c.sun_ver != w.sun_ver {
        cell_shadow(w, l, c, x, z)
    }
    c
}

// World position of corner k of the cell at grid (x, z), cells `step` units wide.
inline fn corner(c: *Cell, x: i64, z: i64, k: i64, step: f32) -> vec3 {
    vec3((f32(x) + CORNER_X[k]) * step, c.h[k], (f32(z) + CORNER_Z[k]) * step)
}

// Corner index i (0..3) of triangle t (0: A, 1: B).
inline fn tri_corner(c: *Cell, t: i64, i: i64) -> i64 {
    TRI_CORNERS[(if c.flip { 6 } else { 0 }) + t * 3 + i]
}

priv fn cell_fill(w: *World, l: i64, c: *Cell, x: i64, z: i64) {
    step := f32(w.grids[l].step)
    c.key = key(x, z)
    c.flip = cell_flip(w.seed, l, x, z)
    c.h[0] = vheight(w, l, x, z)
    c.h[1] = vheight(w, l, x + 1, z)
    c.h[2] = vheight(w, l, x, z + 1)
    c.h[3] = vheight(w, l, x + 1, z + 1)
    c.sun_ver = 0
    for t in 0..2 {
        a := corner(c, x, z, tri_corner(c, t, 0), step)
        b := corner(c, x, z, tri_corner(c, t, 1), step)
        d := corner(c, x, z, tri_corner(c, t, 2), step)
        n := normalize(cross(b - a, d - a))
        if n.y < 0.0 {
            n = -n
        }
        c.nrm[t] = n
        c.alb[t] = material(w.seed, (a + b + d) / 3.0, n, noise_hash(x, z, 2 + t + 4 * l, w.seed))
    }
    c.obj = OBJ_NONE
    if l == 0 {
        place_object(w, c, x, z)
    }
}

// The palette: warm, slightly desaturated colours, as in low-poly landscape art.
const SAND = vec3(0.86, 0.74, 0.50)
const SILT = vec3(0.55, 0.52, 0.40)
const GRASS_LUSH = vec3(0.25, 0.54, 0.17)
const GRASS_DRY = vec3(0.58, 0.60, 0.30)
const FOREST = vec3(0.16, 0.40, 0.15)
const ROCK = vec3(0.47, 0.41, 0.37)
const ROCK_DARK = vec3(0.36, 0.33, 0.33)
const SNOW = vec3(0.90, 0.92, 0.96)

// The colour of a facet with centre p and normal n. Material boundaries are hard (a facet is
// one material), jittered by noise so that they do not follow contour lines; every facet's
// colour is varied slightly by its hash.
fn material(seed: u32, p: vec3, n: vec3, h: u32) -> vec3 {
    slope := 1.0 - n.y
    wobble := noise2(p.x * 0.15, p.z * 0.15, seed + 40) * 0.8
    moist := noise2(p.x * 0.013, p.z * 0.013, seed + 50)
    y := p.y + wobble
    col := lerp(GRASS_LUSH, GRASS_DRY, saturate(0.45 + moist * 1.1 + y * 0.025))
    if forest_density(seed, p.x, p.z) > 0.25 && y < 12.0 {
        col = lerp(col, FOREST, 0.6)
    }
    shore := p.y + wobble * 0.3
    if shore < 0.6 {
        col = SAND
    }
    if shore < -0.5 {
        col = SILT
    }
    // above the tree line an alpine meadow, bare rock where it is steep (steeper still among
    // the snow, which only cliffs break)
    rock_line := 15.0 + noise2(p.x * 0.05, p.z * 0.05, seed + 60) * 4.0
    if y > rock_line {
        col = lerp(GRASS_DRY, ROCK, 0.25)
    }
    snow_line := 27.0 + noise2(p.x * 0.04, p.z * 0.04, seed + 70) * 5.0
    snowy := y > snow_line
    cliff := if snowy { 0.62 } else if y > rock_line { 0.28 } else { 0.33 }
    if slope > cliff + wobble * 0.08 {
        col = lerp(ROCK, ROCK_DARK, unit(h ^ 0x51ED))
        if snowy {
            col = lerp(col, SNOW, 0.4)             // frost on the cliffs
        }
    } else if snowy {
        col = SNOW
    }
    j := unit(h) - 0.5
    col * (1.0 + j * 0.10) + vec3(j * 0.02, 0.0, -j * 0.02)
}

// How wooded the land is around (x, z): above 0.25 a forest.
fn forest_density(seed: u32, x: f32, z: f32) -> f32 {
    fbm2(x * 0.03, z * 0.03, 2, seed + 80)
}

// Trees on grass (dense in forests), rocks on rocky slopes and a few on the shore.
priv fn place_object(w: *World, c: *Cell, x: i64, z: i64) {
    h := noise_hash(x, z, 9, w.seed)
    r := unit(h)
    u := 0.2 + 0.6 * unit(noise_hash(x, z, 10, w.seed))
    v := 0.2 + 0.6 * unit(noise_hash(x, z, 11, w.seed))
    px := f32(x) + u
    pz := f32(z) + v
    gy := ground(w, 0, px, pz)
    ny := fmin(c.nrm[0].y, c.nrm[1].y)
    grassy := gy > 1.0 && gy < 12.5 && ny > 0.8
    forest := forest_density(w.seed, px, pz)
    c.ohash = noise_hash(x, z, 12, w.seed)
    c.opos = vec3(px, gy, pz)
    if grassy && (r < 0.05 || (forest > 0.25 && r < 0.65) || (forest > 0.1 && r < 0.2)) {
        c.obj = if unit(c.ohash) < 0.3 + gy * 0.06 { OBJ_PINE } else { OBJ_ROUND }
        c.osize = 0.75 + 0.55 * unit(c.ohash ^ 0xABCD)
    } else if (ny < 0.75 && gy < 22.0 && r < 0.05) || (gy > 0.0 && gy < 0.6 && r < 0.012) {
        c.obj = OBJ_ROCK
        c.osize = 0.25 + 0.4 * unit(c.ohash ^ 0x1234)
    }
}

// How much sun reaches each corner: a march from it towards the sun over the cached heights
// of its level. Partly hidden corners get a partial shadow, and the facets interpolate the
// corners, so a shadow's edge is a soft band across the facets, not a staircase of cells.
// (A facet turned away from the sun is dark anyway: `lit` in render.al.)
priv fn cell_shadow(w: *World, l: i64, c: *Cell, x: i64, z: i64) {
    c.sun_ver = w.sun_ver
    sun := w.sun
    step := f32(w.grids[l].step)
    for t in 0..4 {
        if sun.y <= 0.02 {
            c.shadow[t] = 0.0
            continue
        }
        p := corner(c, x, z, t, step) + vec3(0.0, 0.15 * step, 0.0)
        occ: f32 = 0.0
        dist: f32 = 0.7 * step
        for k in 0..30 {
            q := p + sun * dist
            if q.y > 60.0 {
                break                               // above every mountain
            }
            above := ground(w, l, q.x, q.z) - q.y
            if above > 0.0 {
                occ = fmax(occ, saturate(above * 1.2 / step))
                if occ >= 1.0 {
                    break
                }
            }
            dist += 0.5 * step + dist * 0.12
        }
        c.shadow[t] = 1.0 - occ
    }
}
