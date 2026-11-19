// The 3D of examples/gfx_lowpoly on the CPU: a view matrix (std.math's look_at), a perspective
// projection, clipping of polygons at the near plane, back-face culling and the painter's
// algorithm, all ending in std.gfx's 2D `triangle` with a colour per corner.
//
// Order. The terrain is a heightfield: a cell can only hide cells that are farther from the
// camera along both axes, so drawing the cells by falling distance from the camera's cell
// (a list sorted once, `order`) is a correct back-to-front order without sorting per frame;
// in a cell the triangle on the far side of its diagonal goes first, then the water over it,
// then what stands on it. The few loose objects (clouds, the aircraft) are sorted by distance
// each frame and merged into that walk; an object is built of convex parts added back to
// front, or (the aircraft) has its faces sorted.
//
// Distance. The land is drawn in LEVELS rings, each with cells twice as large as the one
// inside it and VIEW cells of radius: 76, 152 and 304 units. The coarsest ring goes first;
// where a ring overlaps the finer one inside it, its vertices are lowered so that it stays
// under the finer surface drawn over it, and its water is cut away there. Towards its outer
// edge a ring's surface morphs into the coarser ring's, so the cells that come and go at the
// edge as the camera moves change nothing on the screen.
//
// Colour. A facet has one lit colour (flat shading: sun, sky and ground light), varied only
// by the ray-marched shadow at its corners (world.al). Fog is per corner, towards the colour
// of the sky behind the corner, and reaches 1 at the edge of the view, where cells come and
// go: far land dissolves into the sky and nothing pops.
use std.gfx

const VIEW = 76                  // radius of each ring of the land in its cells
const FAR: f32 = 304.0           // the edge of the coarsest ring: VIEW << (LEVELS - 1)
const GW = 2 * VIEW + 6          // vertices per row of the frame's vertex grid
const NEAR: f32 = 0.12
const FOV_Y: f32 = 1.0           // vertical field of view, radians (57 degrees)
const MAX_FACES = 160            // faces of one object
const MAX_LOOSE = 160            // loose objects per frame

// ---------- the time of day ----------

struct Light {
    name: str
    sun: vec3            // towards the sun (at night: the moon)
    sun_col: vec3        // its light on a facet facing it
    sky_amb: vec3        // light from the sky above
    ground_amb: vec3     // light bounced from below
    zenith: vec3         // sky straight up
    mid: vec3            // sky a little above the horizon
    horizon: vec3        // sky at the horizon, away from the sun (and the fog)
    glow: vec3           // sky at the horizon below the sun
    disc: vec3           // colour of the sun's disc
    disc_size: f32       // its radius in radians
    halo: f32            // strength of the additive glow around it
    deep: vec3           // water colours
    shallow: vec3
    stars: f32           // 0: none, 1: a clear night
    cloud_lit: vec3
    cloud_shade: vec3
    fog_k: f32           // fog per unit of distance
}

const TOD_GOLDEN = 0
const TOD_NOON = 1
const TOD_NIGHT = 2

fn light_of(tod: i64) -> Light {
    if tod == TOD_NOON {
        return Light{name: "noon", sun: normalize(vec3(0.35, 1.0, 0.55)), sun_col: vec3(0.96, 0.92, 0.84),
            sky_amb: vec3(0.35, 0.42, 0.56), ground_amb: vec3(0.16, 0.15, 0.10),
            zenith: vec3(0.16, 0.38, 0.78), mid: vec3(0.42, 0.62, 0.88), horizon: vec3(0.78, 0.87, 0.95),
            glow: vec3(0.92, 0.94, 0.96), disc: vec3(1.0, 0.98, 0.92), disc_size: 0.035, halo: 0.25,
            deep: vec3(0.05, 0.22, 0.36), shallow: vec3(0.16, 0.55, 0.58), stars: 0.0,
            cloud_lit: vec3(1.0, 1.0, 1.0), cloud_shade: vec3(0.74, 0.79, 0.88), fog_k: 0.004}
    }
    if tod == TOD_NIGHT {
        return Light{name: "night", sun: normalize(vec3(0.45, 0.24, 0.85)), sun_col: vec3(0.58, 0.68, 0.98),
            sky_amb: vec3(0.09, 0.12, 0.25), ground_amb: vec3(0.02, 0.02, 0.04),
            zenith: vec3(0.01, 0.02, 0.06), mid: vec3(0.04, 0.07, 0.16), horizon: vec3(0.10, 0.14, 0.26),
            glow: vec3(0.10, 0.14, 0.24), disc: vec3(0.92, 0.94, 1.0), disc_size: 0.03, halo: 0.25,
            deep: vec3(0.01, 0.03, 0.07), shallow: vec3(0.03, 0.09, 0.14), stars: 1.0,
            cloud_lit: vec3(0.30, 0.34, 0.46), cloud_shade: vec3(0.11, 0.13, 0.21), fog_k: 0.006}
    }
    Light{name: "golden hour", sun: normalize(vec3(0.97, 0.22, -0.12)), sun_col: vec3(1.28, 0.93, 0.62),
        sky_amb: vec3(0.30, 0.37, 0.56), ground_amb: vec3(0.16, 0.10, 0.08),
        zenith: vec3(0.20, 0.36, 0.66), mid: vec3(0.50, 0.62, 0.80), horizon: vec3(0.96, 0.80, 0.66),
        glow: vec3(1.0, 0.68, 0.38), disc: vec3(1.0, 0.90, 0.70), disc_size: 0.04, halo: 0.6,
        deep: vec3(0.06, 0.16, 0.28), shallow: vec3(0.20, 0.42, 0.45), stars: 0.0,
        cloud_lit: vec3(1.0, 0.84, 0.68), cloud_shade: vec3(0.70, 0.62, 0.70), fog_k: 0.006}
}

// The colour of the sky in direction d (unit length). Below the horizon it is the horizon's
// colour: the fog that the far land fades into is the sky behind it.
fn sky_color(lt: *Light, d: vec3) -> vec3 {
    up := saturate(d.y)
    flat := normalize(vec3(d.x, 0.0, d.z))
    sflat := normalize(vec3(lt.sun.x, 0.0, lt.sun.z))
    toward := saturate(dot(flat, sflat) * 0.5 + 0.5)
    horizon := lerp(lt.horizon, lt.glow, pow(toward, 4.0))
    col := lerp(horizon, lt.mid, smoothstep(0.0, 0.25, up))
    col = lerp(col, lt.zenith, smoothstep(0.2, 0.95, up))
    s := saturate(dot(d, lt.sun))
    col + lt.glow * (pow(s, 24.0) * 0.4 * (1.0 - up))
}

// ---------- camera and projection ----------

struct Cam {
    eye: vec3
    view: mat4
    inv: mat4            // view space to world
    fx: f32              // pixels per unit of x / depth
    fy: f32
    cx: f32              // the centre of the screen
    cy: f32
    w: f32
    h: f32
}

fn cam_make(eye: vec3, target: vec3, up: vec3, w: f32, h: f32) -> Cam {
    proj := perspective(FOV_Y, w / h, NEAR, 1000.0)
    view := look_at(eye, target, up)
    Cam{eye: eye, view: view, inv: inverse_affine(view), fx: proj[0].x * w * 0.5, fy: proj[1].y * h * 0.5,
        cx: w * 0.5, cy: h * 0.5, w: w, h: h}
}

inline fn to_view(c: *Cam, p: vec3) -> vec3 {
    transform_point(c.view, p)
}

// Screen position of a view-space point in front of the near plane (view space looks down -z).
inline fn project(c: *Cam, v: vec3) -> vec2 {
    iz := 1.0 / -v.z
    vec2(c.cx + v.x * iz * c.fx, c.cy - v.y * iz * c.fy)
}

// Outcodes for culling a cell whose corners all lie beyond one side of the screen.
const OUT_LEFT: u32 = 1
const OUT_RIGHT: u32 = 2
const OUT_TOP: u32 = 4
const OUT_BOTTOM: u32 = 8
const OUT_NEAR: u32 = 16

fn outcode(c: *Cam, v: vec3) -> u32 {
    if -v.z < NEAR {
        return OUT_NEAR
    }
    p := project(c, v)
    m := c.w * 0.05
    o: u32 = 0
    if p.x < -m { o |= OUT_LEFT }
    if p.x > c.w + m { o |= OUT_RIGHT }
    if p.y < -m { o |= OUT_TOP }
    if p.y > c.h + c.h * 0.35 { o |= OUT_BOTTOM }   // trees may stand up into the view
    o
}

// ---------- the frame ----------

// A vertex of the frame's terrain grid.
struct FV {
    ok: bool
    done: bool           // finish has run
    p: vec3              // world space
    v: vec3              // view space
    h: f32               // height (before a coarse ring is lowered under a finer one)
    dist: f32            // horizontal distance from the eye
    fog: f32
    fogc: vec3
    code: u32
    wet: bool            // at or below the sea: the water vertex is set
    wv: vec3             // the water surface above it, view space
    ww: vec3             // and world space
}

// A corner of a polygon on its way to the screen: view-space position and colour.
struct CV { v: vec3, c: vec4 }

// A face of a loose object or a tree, collected, lit, sorted, drawn.
struct Face {
    p: [3]vec3           // world space, counter-clockwise seen from outside
    alb: vec3
    alpha: f32
    double: bool         // seen from both sides (wings, fins)
    soft: bool           // cloud shading
    depth: f32
}

// Something drawn between the cells by its distance: a cloud (an index into Scene.clouds) or
// the aircraft.
struct Loose { kind: i64, idx: i64, pos: vec3, dist: f32 }
const LOOSE_CLOUD = 0
const LOOSE_PLANE = 1

struct Cloud { pos: vec3, size: vec3, hash: u32 }

struct Off { dx: i64, dz: i64, d: f32 }   // a cell relative to the camera's, d its distance

// The vertices of one ring for this frame.
struct Ring {
    fv: []FV
    gx0: i64             // grid vertex at fv[0]
    gz0: i64
    step: f32            // cell size in world units
    inner: f32           // radius (world) covered by the finer ring inside; 0 for the finest
}

struct Scene {
    cam: Cam
    lt: Light
    wire: bool           // the wireframe mode
    edges: bool          // draw the edges of what is drawn now (wireframe, not for the sky)
    time: f32            // seconds, for the water and the stars
    tris: i64            // triangles sent this frame
    cpu_ns: i64          // time draw_scene took
    px: f32              // target pixels per screen pixel (the supersampling factor)
    rings: [LEVELS]Ring
    order: []Off         // cells around the camera's, farthest first
    fogtab: [(FOG_A + 1) * (FOG_E + 1)]vec3   // the sky's colour, see fog_color
    sun_flat: vec2       // towards the sun on the ground plane
    faces: [MAX_FACES]Face
    nfaces: i64
    loose: [MAX_LOOSE]Loose
    nloose: i64
    clouds: [MAX_LOOSE]Cloud
    nclouds: i64
    stars: []vec3
    plane: PlaneState
}

// What render needs of the aircraft: its position and frame.
struct PlaneState { pos: vec3, right: vec3, up: vec3, fwd: vec3, prop: f32 }

fn scene_new() -> Scene {
    s := Scene{px: 1.0}
    for l in 0..LEVELS {
        step := f32(1 << l)
        s.rings[l] = Ring{fv: alloc[FV](GW * GW), step: step, inner: if l == 0 { 0.0 } else { f32(VIEW) * step * 0.5 }}
    }
    order := vec[Off]()
    for dz in -VIEW..=VIEW {
        for dx in -VIEW..=VIEW {
            d := sqrt(f32(dx * dx + dz * dz))
            if d <= f32(VIEW) {
                order.push(Off{dx, dz, d})
            }
        }
    }
    sort_by(order[..], fn(a: Off, b: Off) -> bool { a.d > b.d })
    s.order = order[..]
    r := rng(77)
    s.stars = alloc[vec3](900)
    for i in 0..s.stars.len {
        d := r.unit_vec3()
        d.y = fabs(d.y) * 0.95 + 0.03
        s.stars[i] = normalize(d)
    }
    s
}

// Fog amount at distance d (horizontal) and height y: aerial haze, low valleys a little
// hazier, and all fog at the edge of the view.
inline fn fog_amount(s: *Scene, d: f32, y: f32) -> f32 {
    base := 1.0 - exp(-d * s.lt.fog_k)
    low := saturate(1.0 - (y - SEA_LEVEL) * 0.1) * saturate(d * 0.02) * 0.12
    edge := smoothstep(FAR * 0.8, FAR - 8.0, d)
    fmax(saturate(base + low), edge)
}

// The colour of the sky behind p, seen from the eye: what p fades into. Looked up in a table
// of sky_color by azimuth (relative to the sun) and elevation, made once per frame. Matching
// the sky behind (not just the horizon) matters for far peaks that rise above the horizon:
// fully fogged, they vanish into the sky instead of standing out as flat silhouettes.
const FOG_A = 64                 // azimuth steps (cosine of the angle to the sun, -1..1)
const FOG_E = 20                 // elevation steps (sine, 0..FOG_TOP)
const FOG_TOP: f32 = 1.0

inline fn fog_color(s: *Scene, p: vec3) -> vec3 {
    sky_lookup(s, p - s.cam.eye)
}

// sky_color in direction d (any length) from the table (below the horizon: the horizon's).
inline fn sky_lookup(s: *Scene, d: vec3) -> vec3 {
    flat := length(vec2(d.x, d.z))
    a := (dot(vec2(d.x, d.z), s.sun_flat) / fmax(flat, 0.001) + 1.0) * f32(FOG_A / 2)
    e := saturate(d.y / fmax(length(d), 0.001) / FOG_TOP) * f32(FOG_E)
    ia := clamp(i64(a), 0, FOG_A - 1)
    ie := clamp(i64(e), 0, FOG_E - 1)
    fa := saturate(a - f32(ia))
    fe := saturate(e - f32(ie))
    r0 := ie * (FOG_A + 1) + ia
    r1 := r0 + FOG_A + 1
    lo := lerp(s.fogtab[r0], s.fogtab[r0 + 1], fa)
    hi := lerp(s.fogtab[r1], s.fogtab[r1 + 1], fa)
    lerp(lo, hi, fe)
}

priv fn fog_table(s: *Scene) {
    sf := normalize(vec3(s.lt.sun.x, 0.0, s.lt.sun.z))
    s.sun_flat = vec2(sf.x, sf.z)
    side := vec3(-sf.z, 0.0, sf.x)
    for j in 0..=FOG_E {
        se := FOG_TOP * f32(j) / f32(FOG_E)
        ce := sqrt(1.0 - se * se)
        for i in 0..=FOG_A {
            c := f32(i) / f32(FOG_A / 2) - 1.0
            d := (sf * c + side * sqrt(fmax(0.0, 1.0 - c * c))) * ce + vec3(0.0, fmin(se, 0.999), 0.0)
            s.fogtab[j * (FOG_A + 1) + i] = sky_color(&s.lt, d)
        }
    }
}

inline fn shade(c: vec3, fog: f32, fogc: vec3, a: f32) -> vec4 {
    vec4(lerp(c, fogc, fog), lerp(a, 1.0, fog))
}

// Clips the polygon v[0..n] at the near plane and draws it as a fan of triangles (and its
// edges in wireframe mode).
fn poly(g: *Gfx, s: *Scene, v: *[8]CV, n: i64) {
    if n == 3 && !s.edges && -v[0].v.z >= NEAR && -v[1].v.z >= NEAR && -v[2].v.z >= NEAR {
        // the common case: a triangle wholly in front of the near plane
        g.triangle(project(&s.cam, v[0].v), project(&s.cam, v[1].v), project(&s.cam, v[2].v),
            color_u32(v[0].c), color_u32(v[1].c), color_u32(v[2].c))
        s.tris += 1
        return
    }
    out: [10]CV
    m := 0
    for i in 0..n {
        a := v[i]
        b := v[(i + 1) % n]
        da := -a.v.z - NEAR
        db := -b.v.z - NEAR
        if da >= 0.0 {
            out[m] = a
            m += 1
        }
        if (da >= 0.0) != (db >= 0.0) {
            t := da / (da - db)
            out[m] = CV{lerp(a.v, b.v, t), lerp(a.c, b.c, t)}
            m += 1
        }
    }
    if m < 3 {
        return
    }
    p: [10]vec2
    c: [10]u32
    for i in 0..m {
        p[i] = project(&s.cam, out[i].v)
        c[i] = color_u32(out[i].c)
    }
    for i in 1..m - 1 {
        g.triangle(p[0], p[i], p[i + 1], c[0], c[i], c[i + 1])
        s.tris += 1
    }
    if s.edges {
        // dark edges that fade with distance, so the far land is not a solid net
        for i in 0..m {
            k := (i + 1) % m
            e := (out[i].c + out[k].c) * 0.5
            depth := -(out[i].v.z + out[k].v.z) * 0.5
            col := vec4(e.xyz * 0.45, 0.7 * e.w * saturate(1.25 - depth / 120.0))
            g.line(p[i], p[k], s.px, color_u32(col))
        }
    }
}

// Clips v[0..n] to the part where the per-corner value f is >= 0 (the underwater part of a
// triangle) into out; returns its corner count.
fn clip_by(v: *[8]CV, f: *[8]f32, n: i64, out: *[8]CV) -> i64 {
    m := 0
    for i in 0..n {
        k := (i + 1) % n
        if f[i] >= 0.0 {
            out[m] = v[i]
            m += 1
        }
        if (f[i] >= 0.0) != (f[k] >= 0.0) {
            t := f[i] / (f[i] - f[k])
            out[m] = CV{lerp(v[i].v, v[k].v, t), lerp(v[i].c, v[k].c, t)}
            m += 1
        }
    }
    m
}

// Light on a facet with normal n and albedo a; `sun` scales the direct light (shadow).
fn lit(lt: *Light, a: vec3, n: vec3, sun: f32) -> vec3 {
    direct := saturate(dot(n, lt.sun)) * sun
    sky := 0.55 + 0.45 * n.y
    a * (lt.sun_col * direct + lt.sky_amb * sky + lt.ground_amb * (1.0 - sky))
}

// ---------- drawing a frame ----------

// Draws the whole scene: sky, sun, the rings of land from the outside in with their water and
// objects, the clouds and the aircraft merged in by distance.
fn draw_scene(g: *Gfx, s: *Scene, w: *World) {
    start := time_ns()
    s.tris = 0
    fog_table(s)
    s.edges = false
    draw_sky(g, s)
    collect_loose(s)
    k := 0
    ex := s.cam.eye.x
    ez := s.cam.eye.z
    for l in LEVELS - 1..=0 by -1 {
        s.edges = s.wire && l < 2
        prepare_ring(s, w, l)
        rg := &s.rings[l]
        step := rg.step
        ccx := i64(floor(ex / step))
        ccz := i64(floor(ez / step))
        skip := if l == 0 { -1.0 } else { f32(VIEW) * 0.5 - 3.0 }   // cells inside the finer ring
        for o in s.order {
            if o.d < skip {
                break                                   // the rest is nearer still
            }
            cx := ccx + o.dx
            cz := ccz + o.dz
            d := length(vec2((f32(cx) + 0.5) * step - ex, (f32(cz) + 0.5) * step - ez))
            while k < s.nloose && s.loose[k].dist > d {
                draw_loose(g, s, w, s.loose[k])
                k += 1
            }
            draw_cell(g, s, w, l, cx, cz)
        }
    }
    while k < s.nloose {
        draw_loose(g, s, w, s.loose[k])
        k += 1
    }
    draw_glare(g, s)
    s.cpu_ns = time_ns() - start
}

// Transforms the vertices of ring l into view space (heights from the world's cache) for
// culling; the rest of a vertex (see finish) is worked out only when a visible cell uses it.
priv fn prepare_ring(s: *Scene, w: *World, l: i64) {
    rg := &s.rings[l]
    step := rg.step
    ccx := i64(floor(s.cam.eye.x / step))
    ccz := i64(floor(s.cam.eye.z / step))
    rg.gx0 = ccx - VIEW - 2
    rg.gz0 = ccz - VIEW - 2
    r2 := f32((VIEW + 2) * (VIEW + 2))
    hole := if l == 0 { -1.0 } else { f32(VIEW) * 0.5 - 5.0 }    // no cell of this ring in there
    hole2 := hole * hole
    for j in 0..GW {
        for i in 0..GW {
            f := &rg.fv[j * GW + i]
            dx := f32(i - VIEW - 2)
            dz := f32(j - VIEW - 2)
            r := dx * dx + dz * dz
            if r > r2 || r < hole2 {
                f.ok = false
                continue
            }
            x := rg.gx0 + i
            z := rg.gz0 + j
            h := vheight(w, l, x, z)
            f.ok = true
            f.done = false
            f.h = h
            f.p = vec3(f32(x) * step, h, f32(z) * step)
            f.dist = length(vec2(f.p.x - s.cam.eye.x, f.p.z - s.cam.eye.z))
            f.v = to_view(&s.cam, f.p)
            f.code = outcode(&s.cam, f.v)
        }
    }
}

// The rest of a vertex of ring l: near the ring's outer edge its height becomes the coarser
// ring's surface, so that the cells that come and go there change nothing (geomorphing);
// inside the finer ring it is lowered under it; then its fog and, at the sea, the moving
// water surface above it.
priv fn finish(s: *Scene, w: *World, rg: *Ring, l: i64, f: *FV) {
    f.done = true
    step := rg.step
    p := f.p
    morph_at := f32(VIEW) * step * 0.7
    if l < LEVELS - 1 && f.dist > morph_at {
        m := smoothstep(morph_at, f32(VIEW - 3) * step, f.dist)
        p.y = lerp(f.h, ground(w, l + 1, p.x, p.z), m)
    }
    sink_at := rg.inner - 3.0 * step
    if f.dist < sink_at {
        p.y -= saturate((sink_at - f.dist) / step) * 3.0 * step
    }
    if p.y != f.h {
        f.v = to_view(&s.cam, p)
    }
    f.fog = fog_amount(s, f.dist, f.h)
    f.fogc = fog_color(s, p)
    f.wet = f.h < SEA_LEVEL + 0.4
    if f.wet {
        t := s.time
        wave := noise3(p.x * 0.45, p.z * 0.45, t * 0.55, 5) * 0.16 + sin(p.x * 0.7 + p.z * 0.3 + t * 1.3) * 0.03
        f.ww = vec3(p.x, SEA_LEVEL + wave, p.z)
        f.wv = to_view(&s.cam, f.ww)
    }
}

priv inline fn fv_at(rg: *Ring, x: i64, z: i64) -> *FV {
    &rg.fv[(z - rg.gz0) * GW + (x - rg.gx0)]
}

priv fn draw_cell(g: *Gfx, s: *Scene, w: *World, l: i64, x: i64, z: i64) {
    rg := &s.rings[l]
    f: [4]*FV
    f[0] = fv_at(rg, x, z)
    f[1] = fv_at(rg, x + 1, z)
    f[2] = fv_at(rg, x, z + 1)
    f[3] = fv_at(rg, x + 1, z + 1)
    if !f[0].ok || !f[1].ok || !f[2].ok || !f[3].ok {
        return
    }
    if f[0].code & f[1].code & f[2].code & f[3].code != 0 {
        return
    }
    for k in 0..4 {
        if !f[k].done {
            finish(s, w, rg, l, f[k])
        }
    }
    c := cell_at(w, l, x, z)
    u := s.cam.eye.x / rg.step - f32(x)
    v := s.cam.eye.z / rg.step - f32(z)
    // the eye on triangle B's side of the diagonal: A is farther, draw it first
    b_near := if c.flip { u + v > 1.0 } else { u > v }
    first := if b_near { 0 } else { 1 }
    for k in 0..2 {
        t := if k == 0 { first } else { 1 - first }
        draw_tri(g, s, rg, c, f, x, z, t)
    }
    if c.obj != OBJ_NONE {
        draw_object(g, s, w, c)
    }
}

priv fn draw_tri(g: *Gfx, s: *Scene, rg: *Ring, c: *Cell, f: [4]*FV, x: i64, z: i64, t: i64) {
    i0 := tri_corner(c, t, 0)
    i1 := tri_corner(c, t, 1)
    i2 := tri_corner(c, t, 2)
    n := c.nrm[t]
    lo := fmin(c.h[i0], fmin(c.h[i1], c.h[i2]))
    // back-face culling (the land is seen from above, but its slopes can face away), on the
    // triangle as drawn: every corner order of TRI_CORNERS turns counter-clockwise seen from
    // above, and the eye is the origin of view space
    v0 := f[i0].v
    if dot(cross(f[i1].v - v0, f[i2].v - v0), v0) < 0.0 {
        // flat shading: one light for the facet, only the shadow differs at the corners
        lt := &s.lt
        alb := c.alb[t]
        amb := alb * (lt.sky_amb * (0.55 + 0.45 * n.y) + lt.ground_amb * (0.45 - 0.45 * n.y))
        sun := alb * lt.sun_col * saturate(dot(n, lt.sun))
        v: [8]CV
        idx := [3]i64{i0, i1, i2}
        for k in 0..3 {
            fk := f[idx[k]]
            ck := amb + sun * c.shadow[idx[k]]
            if fk.h < SEA_LEVEL {
                ck = lerp(ck, lt.deep * 0.8, saturate((SEA_LEVEL - fk.h) * 0.35))   // seen through water
            }
            v[k] = CV{fk.v, shade(ck, fk.fog, fk.fogc, 1.0)}
        }
        poly(g, s, &v, 3)
    }
    if lo < SEA_LEVEL {
        draw_water(g, s, rg, f, [3]i64{i0, i1, i2})
    }
}

// The water over the underwater part of a terrain triangle: its own wavy facets, coloured by
// depth, reflecting the sky at grazing angles (a Fresnel-like blend) and glittering where a
// facet mirrors the sun.
priv fn draw_water(g: *Gfx, s: *Scene, rg: *Ring, f: [4]*FV, idx: [3]i64) {
    lt := &s.lt
    a := f[idx[0]].ww
    b := f[idx[1]].ww
    d := f[idx[2]].ww
    n := normalize(cross(b - a, d - a))
    if n.y < 0.0 {
        n = -n
    }
    if dot(n, s.cam.eye - a) <= 0.0 {
        return
    }
    centre := (a + b + d) / 3.0
    vc := normalize(centre - s.cam.eye)
    r := reflect(vc, n)
    glint := pow(saturate(dot(r, lt.sun)), 90.0) * 3.0 + pow(saturate(dot(r, lt.sun)), 12.0) * 0.25
    if lt.sun.y < 0.05 {
        glint = 0.0
    }
    v: [8]CV
    dep: [8]f32
    for k in 0..3 {
        fk := f[idx[k]]
        depth := SEA_LEVEL - fk.h
        dep[k] = depth
        dv := normalize(fk.ww - s.cam.eye)
        cosv := saturate(-dv.y)
        q := 1.0 - cosv
        fres := 0.03 + 0.97 * q * q * q * q * q
        base := lerp(lt.shallow, lt.deep, saturate(depth * 0.45))
        alpha := lerp(0.25, 0.88, saturate(depth * 0.5))
        rv := reflect(dv, n)                      // the sky this facet mirrors
        sky := sky_lookup(s, vec3(rv.x, fabs(rv.y), rv.z))
        col := lerp(base, sky, saturate(fres * 0.9)) * (0.85 + 0.15 * n.y)
        col = col + lt.sun_col * glint
        alpha = saturate(lerp(alpha, 1.0, fres) + glint)
        v[k] = CV{fk.wv, shade(col, fk.fog, fk.fogc, alpha)}
    }
    out: [8]CV
    m := clip_by(&v, &dep, 3, &out)
    if rg.inner > 0.0 && m >= 3 {
        // a coarse ring: only outside the finer ring, which has water of its own
        o2: [8]CV
        m = clip_ring(s, &out, m, rg.inner - 0.5, &o2)
        out = o2
    }
    if m >= 3 {
        poly(g, s, &out, m)
    }
}

// Clips the view-space polygon v[0..m] to the part farther than radius r (horizontal, world)
// from the eye, into out.
priv fn clip_ring(s: *Scene, v: *[8]CV, m: i64, r: f32, out: *[8]CV) -> i64 {
    f: [8]f32
    for k in 0..m {
        p := transform_point(s.cam.inv, v[k].v)
        f[k] = length(vec2(p.x - s.cam.eye.x, p.z - s.cam.eye.z)) - r
    }
    clip_by(v, &f, m, out)
}

// ---------- objects ----------

priv fn face_begin(s: *Scene) {
    s.nfaces = 0
}

priv fn face(s: *Scene, a: vec3, b: vec3, c: vec3, alb: vec3, alpha: f32, double: bool) {
    if s.nfaces >= MAX_FACES {
        return
    }
    s.faces[s.nfaces] = Face{p: [3]vec3{a, b, c}, alb: alb, alpha: alpha, double: double}
    s.nfaces += 1
}

// Lights and draws the collected faces of an object at `at` (its fog, one for the whole
// object, which is small); `shadow` scales the sun on it. With `sort` the faces are sorted,
// farthest first; without, the object was built in an order that needs none (convex parts
// with back faces culled, added back to front).
priv fn face_flush(g: *Gfx, s: *Scene, shadow: f32, at: vec3, sort: bool) {
    n := s.nfaces
    fog := fog_amount(s, length(vec2(at.x - s.cam.eye.x, at.z - s.cam.eye.z)), at.y)
    fogc := fog_color(s, at)
    if sort {
        for i in 0..n {
            fc := &s.faces[i]
            fc.depth = length_sq((fc.p[0] + fc.p[1] + fc.p[2]) / 3.0 - s.cam.eye)
        }
        for i in 1..n {                     // insertion sort, falling depth
            j := i
            while j > 0 && s.faces[j - 1].depth < s.faces[j].depth {
                swap(&s.faces[j - 1], &s.faces[j])
                j -= 1
            }
        }
    }
    for i in 0..n {
        fc := &s.faces[i]
        a := fc.p[0]
        nrm := normalize(cross(fc.p[1] - a, fc.p[2] - a))
        if dot(nrm, s.cam.eye - a) <= 0.0 {
            if !fc.double {
                continue
            }
            nrm = -nrm
        }
        col := if fc.soft {
            l := saturate(dot(nrm, s.lt.sun) * 0.6 + 0.45 + nrm.y * 0.25)
            lerp(s.lt.cloud_shade, s.lt.cloud_lit, l) * fc.alb
        } else {
            lit(&s.lt, fc.alb, nrm, shadow)
        }
        v: [8]CV
        for k in 0..3 {
            v[k] = CV{to_view(&s.cam, fc.p[k]), shade(col, fog, fogc, fc.alpha)}
        }
        poly(g, s, &v, 3)
    }
    s.nfaces = 0
}

// The vertices and faces of an icosahedron (the puffs of clouds, round tree crowns, rocks).
const ICO_A: f32 = 0.5257311
const ICO_B: f32 = 0.8506508
const ICO_V = [12]vec3{
    vec3(-ICO_A, 0.0, ICO_B), vec3(ICO_A, 0.0, ICO_B), vec3(-ICO_A, 0.0, -ICO_B), vec3(ICO_A, 0.0, -ICO_B),
    vec3(0.0, ICO_B, ICO_A), vec3(0.0, ICO_B, -ICO_A), vec3(0.0, -ICO_B, ICO_A), vec3(0.0, -ICO_B, -ICO_A),
    vec3(ICO_B, ICO_A, 0.0), vec3(-ICO_B, ICO_A, 0.0), vec3(ICO_B, -ICO_A, 0.0), vec3(-ICO_B, -ICO_A, 0.0),
}
const ICO_F = [60]i64{
    0, 4, 1, 0, 9, 4, 9, 5, 4, 4, 5, 8, 4, 8, 1, 8, 10, 1, 8, 3, 10, 5, 3, 8, 5, 2, 3, 2, 7, 3,
    7, 10, 3, 7, 6, 10, 7, 11, 6, 11, 0, 6, 0, 1, 6, 6, 1, 10, 9, 0, 11, 9, 11, 2, 9, 2, 5, 7, 2, 11,
}

// An icosahedron at c scaled by sz, each vertex pushed in or out by its hash (rocks, crowns).
priv fn ico(s: *Scene, c: vec3, sz: vec3, alb: vec3, jitter: f32, hash: u32, soft: bool) {
    vs: [12]vec3
    for i in 0..12 {
        j := 1.0 + (unit(noise_hash(i, 0, 3, hash)) - 0.5) * jitter
        vs[i] = c + ICO_V[i] * sz * j
    }
    for f in 0..20 {
        a := vs[ICO_F[f * 3]]
        b := vs[ICO_F[f * 3 + 1]]
        d := vs[ICO_F[f * 3 + 2]]
        h := noise_hash(f, 1, 3, hash)
        tint := alb * (0.94 + 0.12 * unit(h))
        if s.nfaces < MAX_FACES {
            s.faces[s.nfaces] = Face{p: [3]vec3{a, b, d}, alb: tint, alpha: 1.0, soft: soft}
            s.nfaces += 1
        }
    }
}

// A cone of `sides` faces from a ring of radius r at base up to apex (a pine's layers).
priv fn cone(s: *Scene, base: vec3, r: f32, height: f32, sides: i64, alb: vec3, turn: f32) {
    apex := base + vec3(0.0, height, 0.0)
    for i in 0..sides {
        a0 := turn + TAU * f32(i) / f32(sides)
        a1 := turn + TAU * f32(i + 1) / f32(sides)
        p0 := base + vec3(cos(a0) * r, 0.0, sin(a0) * r)
        p1 := base + vec3(cos(a1) * r, 0.0, sin(a1) * r)
        face(s, p0, apex, p1, alb * (0.95 + 0.1 * f32(i % 2)), 1.0, false)
        face(s, p0, p1, base, alb * 0.6, 1.0, false)      // the underside, seen from below the crown
    }
}

// A trunk: a three-sided prism from y0 up by height.
priv fn trunk(s: *Scene, base: vec3, r: f32, height: f32, turn: f32) {
    col := vec3(0.36, 0.25, 0.17)
    for i in 0..3 {
        a0 := turn + TAU * f32(i) / 3.0
        a1 := turn + TAU * f32(i + 1) / 3.0
        p0 := base + vec3(cos(a0) * r, -0.1, sin(a0) * r)
        p1 := base + vec3(cos(a1) * r, -0.1, sin(a1) * r)
        up := vec3(0.0, height, 0.0)
        face(s, p0, p0 + up, p1 + up, col, 1.0, false)
        face(s, p0, p1 + up, p1, col, 1.0, false)
    }
}

const PINE_GREEN = vec3(0.13, 0.30, 0.17)
const LEAF_GREEN = vec3(0.36, 0.58, 0.18)
const LEAF_AUTUMN = vec3(0.70, 0.50, 0.16)

// A tree or rock standing on a cell.
priv fn draw_object(g: *Gfx, s: *Scene, w: *World, c: *Cell) {
    p := c.opos
    dist := length(vec2(p.x - s.cam.eye.x, p.z - s.cam.eye.z))
    if dist > f32(VIEW) - 3.0 {
        return
    }
    vp := to_view(&s.cam, p + vec3(0.0, 1.0, 0.0))
    if -vp.z < -2.0 {
        return
    }
    // standing on the land as drawn (morphed near the ring's edge, see prepare_ring); far away
    // they grow out of the ground instead of appearing at once
    morph_at := f32(VIEW) * 0.7
    if dist > morph_at {
        p.y = lerp(p.y, ground(w, 1, p.x, p.z), smoothstep(morph_at, f32(VIEW - 3), dist))
    }
    sz := c.osize * smoothstep(f32(VIEW) - 3.0, f32(VIEW) - 16.0, dist)
    turn := unit(c.ohash) * TAU
    sun := (c.shadow[0] + c.shadow[1] + c.shadow[2] + c.shadow[3]) * 0.25
    face_begin(s)
    if c.obj == OBJ_PINE {
        if dist < 45.0 {
            trunk(s, p, 0.07 * sz, 0.5 * sz, turn)          // (too thin to see farther away)
        }
        tint := PINE_GREEN * (0.9 + 0.25 * unit(c.ohash ^ 0x77))
        cone(s, p + vec3(0.0, 0.35 * sz, 0.0), 0.55 * sz, 1.2 * sz, 5, tint, turn)
        cone(s, p + vec3(0.0, 0.95 * sz, 0.0), 0.4 * sz, 1.0 * sz, 5, tint * 1.08, turn + 0.5)
    } else if c.obj == OBJ_ROUND {
        trunk(s, p, 0.08 * sz, 0.6 * sz, turn)
        k := unit(c.ohash ^ 0x99)
        tint := lerp(LEAF_GREEN, LEAF_AUTUMN, k * k * k * k * 0.8) * (0.9 + 0.2 * unit(c.ohash ^ 0x55))
        ico(s, p + vec3(0.0, 0.95 * sz, 0.0), vec3(0.5, 0.48, 0.5) * sz, tint, 0.35, c.ohash, false)
    } else {
        col := ROCK * (0.85 + 0.3 * unit(c.ohash ^ 0x31))
        ico(s, p + vec3(0.0, 0.1 * sz, 0.0), vec3(1.0, 0.65, 0.85) * sz, col, 0.5, c.ohash, false)
    }
    face_flush(g, s, 0.25 + 0.75 * sun, p, false)
}

// ---------- loose objects: clouds and the aircraft ----------

const CLOUD_CELL: f32 = 46.0

// The clouds around the camera (from a hashed grid that drifts with the wind) and the
// aircraft, sorted by falling distance.
priv fn collect_loose(s: *Scene) {
    s.nloose = 0
    s.nclouds = 0
    wind := vec3(1.0, 0.0, 0.35) * (s.time * 0.6)
    ex := s.cam.eye.x - wind.x
    ez := s.cam.eye.z - wind.z
    gx := i64(floor(ex / CLOUD_CELL))
    gz := i64(floor(ez / CLOUD_CELL))
    reach := i64(FAR / CLOUD_CELL) + 1
    for j in gz - reach..=gz + reach {
        for i in gx - reach..=gx + reach {
            h := noise_hash(i, j, 21, 4242)
            if unit(h) > 0.33 || s.nclouds >= MAX_LOOSE - 1 {
                continue
            }
            pos := vec3((f32(i) + 0.2 + 0.6 * unit(h ^ 0x11)) * CLOUD_CELL, 30.0 + 9.0 * unit(h ^ 0x22),
                (f32(j) + 0.2 + 0.6 * unit(h ^ 0x33)) * CLOUD_CELL) + wind
            d := length(vec2(pos.x - s.cam.eye.x, pos.z - s.cam.eye.z))
            vp := to_view(&s.cam, pos)
            if d > FAR - 10.0 || -vp.z < -20.0 || fabs(vp.x) > -vp.z * 2.2 + 20.0 {
                continue
            }
            sz := 4.0 + 5.0 * unit(h ^ 0x44)
            s.clouds[s.nclouds] = Cloud{pos, vec3(sz, sz * 0.38, sz * 0.75), h}
            s.loose[s.nloose] = Loose{LOOSE_CLOUD, s.nclouds, pos, d}
            s.nclouds += 1
            s.nloose += 1
        }
    }
    pp := s.plane.pos
    s.loose[s.nloose] = Loose{LOOSE_PLANE, 0, pp, length(vec2(pp.x - s.cam.eye.x, pp.z - s.cam.eye.z))}
    s.nloose += 1
    for i in 1..s.nloose {
        j := i
        while j > 0 && s.loose[j - 1].dist < s.loose[j].dist {
            swap(&s.loose[j - 1], &s.loose[j])
            j -= 1
        }
    }
}

priv fn draw_loose(g: *Gfx, s: *Scene, w: *World, o: Loose) {
    if o.kind == LOOSE_PLANE {
        draw_plane(g, s)
        return
    }
    cl := s.clouds[o.idx]
    face_begin(s)
    // puffs along the cloud's long axis, the middle ones the biggest, sitting on a flat base;
    // each is convex, so drawing the puffs farthest first is enough
    puffs := 4 + i64(cl.hash % 3)
    centre: [6]vec3
    radius: [6]f32
    hash: [6]u32
    for k in 0..puffs {
        h := noise_hash(k, 0, 5, cl.hash)
        along := (f32(k) + 0.5) / f32(puffs) * 2.0 - 1.0
        r := (0.55 + 0.25 * unit(h ^ 0x3)) * (1.0 - 0.45 * along * along)
        centre[k] = cl.pos + vec3(along * 1.1, r * 0.55, (unit(h ^ 0x2) - 0.5) * 0.7) * cl.size
        radius[k] = r
        hash[k] = h
        j := k
        while j > 0 && length_sq(centre[j - 1] - s.cam.eye) < length_sq(centre[j] - s.cam.eye) {
            swap(&centre[j - 1], &centre[j])
            swap(&radius[j - 1], &radius[j])
            swap(&hash[j - 1], &hash[j])
            j -= 1
        }
    }
    for k in 0..puffs {
        ico(s, centre[k], cl.size * radius[k], vec3(1.0), 0.2, hash[k], true)
    }
    face_flush(g, s, 1.0, cl.pos, false)
}

const RED = vec3(0.72, 0.13, 0.10)
const CREAM = vec3(0.93, 0.89, 0.80)
const GLASS = vec3(0.12, 0.16, 0.24)

// The aircraft, in its own frame (x right, y up, z forward) placed by s.plane.
priv fn draw_plane(g: *Gfx, s: *Scene) {
    face_begin(s)
    pl := s.plane
    fn at(pl: PlaneState, x: f32, y: f32, z: f32) -> vec3 {
        pl.pos + (pl.right * x + pl.up * y + pl.fwd * z) * 1.4
    }
    nose := at(pl, 0.0, 0.0, 1.0)
    tail := at(pl, 0.0, 0.07, -1.05)
    r1: [4]vec3                                 // rings around the fuselage: top, right, bottom, left
    r2: [4]vec3
    r1[0] = at(pl, 0.0, 0.17, 0.45)
    r1[1] = at(pl, 0.16, 0.0, 0.45)
    r1[2] = at(pl, 0.0, -0.14, 0.45)
    r1[3] = at(pl, -0.16, 0.0, 0.45)
    r2[0] = at(pl, 0.0, 0.14, -0.3)
    r2[1] = at(pl, 0.11, 0.0, -0.3)
    r2[2] = at(pl, 0.0, -0.1, -0.3)
    r2[3] = at(pl, -0.11, 0.0, -0.3)
    canopy := at(pl, 0.0, 0.3, 0.1)
    for i in 0..4 {
        k := (i + 1) % 4
        face(s, nose, r1[k], r1[i], RED, 1.0, false)
        if i == 0 || i == 3 {
            // the cockpit glass over the top two panels
            face(s, r1[i], r1[k], canopy, if i == 0 { GLASS } else { GLASS * 1.3 }, 1.0, false)
            face(s, r1[i], canopy, r2[i], RED, 1.0, false)
            face(s, canopy, r1[k], r2[k], RED, 1.0, false)
            face(s, canopy, r2[k], r2[i], RED * 0.9, 1.0, false)
        } else {
            face(s, r1[i], r1[k], r2[k], RED, 1.0, false)
            face(s, r1[i], r2[k], r2[i], RED, 1.0, false)
        }
        face(s, r2[i], r2[k], tail, CREAM, 1.0, false)
    }
    // wings with a slight dihedral and red tips, tailplane, fin
    for side in 0..2 {
        sx: f32 = if side == 0 { 1.0 } else { -1.0 }
        a := at(pl, 0.1 * sx, -0.03, 0.36)
        b := at(pl, 0.95 * sx, 0.07, 0.22)
        c := at(pl, 0.95 * sx, 0.07, -0.08)
        d := at(pl, 0.1 * sx, -0.03, -0.2)
        e := at(pl, 1.2 * sx, 0.1, 0.18)
        f := at(pl, 1.2 * sx, 0.1, -0.03)
        face(s, a, b, c, CREAM, 1.0, true)
        face(s, a, c, d, CREAM, 1.0, true)
        face(s, b, e, f, RED, 1.0, true)
        face(s, b, f, c, RED, 1.0, true)
        ta := at(pl, 0.05 * sx, 0.06, -0.75)
        tb := at(pl, 0.45 * sx, 0.08, -0.85)
        tc := at(pl, 0.45 * sx, 0.08, -0.98)
        td := at(pl, 0.05 * sx, 0.06, -1.02)
        face(s, ta, tb, tc, CREAM, 1.0, true)
        face(s, ta, tc, td, CREAM, 1.0, true)
    }
    face(s, at(pl, 0.0, 0.08, -0.62), at(pl, 0.0, 0.48, -0.98), at(pl, 0.0, 0.08, -1.04), RED, 1.0, true)
    // the propeller: a translucent spinning disc
    hub := at(pl, 0.0, 0.0, 1.02)
    for i in 0..8 {
        a0 := s.plane.prop + TAU * f32(i) / 8.0
        a1 := s.plane.prop + TAU * f32(i + 1) / 8.0
        p0 := hub + (pl.right * cos(a0) + pl.up * sin(a0)) * 0.42
        p1 := hub + (pl.right * cos(a1) + pl.up * sin(a1)) * 0.42
        face(s, hub, p0, p1, vec3(0.9) * (0.85 + 0.3 * f32(i % 2)), 0.09, true)
    }
    face_flush(g, s, 1.0, pl.pos, true)
    // navigation lights: red on the left wingtip, green on the right, a white strobe on the
    // tail; faint by day, glowing at night
    glow := 0.35 + 0.65 * s.lt.stars
    nav_light(g, s, at(pl, -1.22, 0.1, 0.1), vec3(1.0, 0.15, 0.1), glow)
    nav_light(g, s, at(pl, 1.22, 0.1, 0.1), vec3(0.15, 1.0, 0.3), glow)
    if fmod(s.time, 1.3) < 0.08 {
        nav_light(g, s, at(pl, 0.0, 0.5, -1.0), vec3(1.0), glow * 1.5)
    }
}

priv fn nav_light(g: *Gfx, s: *Scene, p: vec3, col: vec3, k: f32) {
    v := to_view(&s.cam, p)
    if -v.z < NEAR {
        return
    }
    c := project(&s.cam, v)
    r := clamp(s.cam.fy * 0.18 / -v.z, 2.0 * s.px, 14.0 * s.px)
    g.set_blend(BlendAdd)
    fan(g, c, r * 3.0, vec4(col, 0.35 * k), vec4(col, 0.0), 16)
    fan(g, c, r * 0.6, vec4(vec3(1.0), 0.9 * k), vec4(col, 0.6 * k), 12)
    g.set_blend(BlendAlpha)
}

// ---------- sky ----------

const SEG = 32                   // segments of the sky dome around the horizon

// The sky dome (a gradient on a sphere of directions around the eye, so it rolls and pitches
// with the camera), the stars at night, the sun's glow and disc.
priv fn draw_sky(g: *Gfx, s: *Scene) {
    lt := &s.lt
    ring := [10]f32{-0.25, -0.02, 0.0, 0.03, 0.08, 0.16, 0.3, 0.5, 0.75, 0.97}
    for r in 0..9 {
        for i in 0..SEG {
            v: [8]CV
            corners := [4]i64{0, 1, 1, 0}
            levels := [4]i64{r, r, r + 1, r + 1}
            for k in 0..4 {
                a := TAU * f32(i + corners[k]) / f32(SEG)
                e := ring[levels[k]]
                ce := sqrt(1.0 - e * e)
                d := vec3(cos(a) * ce, e, sin(a) * ce)
                v[k] = CV{transform_dir(s.cam.view, d) * 500.0, vec4(sky_color(lt, d), 1.0)}
            }
            poly(g, s, &v, 4)
        }
    }
    if lt.stars > 0.0 {
        for i in 0..s.stars.len {
            d := s.stars[i]
            vd := transform_dir(s.cam.view, d)
            if -vd.z < 0.1 {
                continue
            }
            p := project(&s.cam, vd)
            if p.x < 0.0 || p.y < 0.0 || p.x > s.cam.w || p.y > s.cam.h {
                continue
            }
            h := noise_hash(i, 0, 7, 99)
            tw := 0.6 + 0.4 * sin(s.time * (1.5 + 2.0 * unit(h)) + f32(i))
            b := lt.stars * saturate(d.y * 4.0) * (0.35 + 0.65 * unit(h ^ 0x9)) * tw
            sz := (if unit(h ^ 0x5) > 0.9 { 2.0 } else { 1.3 }) * s.px
            g.rect(vec4(p.x - sz * 0.5, p.y - sz * 0.5, sz, sz), color_u32(vec4(0.85, 0.9, 1.0, b)))
        }
    }
    // the sun (or moon): the disc with a soft edge and a tight additive corona (land in front
    // covers both)
    vd := transform_dir(s.cam.view, lt.sun)
    if -vd.z > 0.05 {
        c := project(&s.cam, vd)
        rpx := lt.disc_size * s.cam.fy
        fan(g, c, rpx, vec4(lt.disc, 1.0), vec4(lt.disc, 1.0), 32)
        ring_band(g, c, rpx, rpx * 1.3, vec4(lt.disc, 1.0), vec4(lt.disc, 0.0), 32)
        g.set_blend(BlendAdd)                   // light adds up: the disc burns out to white
        fan(g, c, rpx * 3.0, vec4(lt.disc, lt.halo * 0.6), vec4(lt.disc, 0.0), 32)
        g.set_blend(BlendAlpha)
    }
}

// The wide glow around the sun, added over everything (glare in the eye, not light in the
// sky): fogged mountains in front of the sun brighten with the sky behind them.
fn draw_glare(g: *Gfx, s: *Scene) {
    lt := &s.lt
    vd := transform_dir(s.cam.view, lt.sun)
    if -vd.z > 0.05 {
        g.set_blend(BlendAdd)
        fan(g, project(&s.cam, vd), s.cam.h * 0.5, vec4(lt.glow, lt.halo * 0.28), vec4(lt.glow, 0.0), 40)
        g.set_blend(BlendAlpha)
    }
}

// A disc of triangles around c: colour ci at the centre, co at the rim.
fn fan(g: *Gfx, c: vec2, r: f32, ci: vec4, co: vec4, n: i64) {
    if ci.w <= 0.0 && co.w <= 0.0 {
        return
    }
    a := color_u32(ci)
    b := color_u32(co)
    for i in 0..n {
        a0 := TAU * f32(i) / f32(n)
        a1 := TAU * f32(i + 1) / f32(n)
        g.triangle(c, c + vec2(cos(a0), sin(a0)) * r, c + vec2(cos(a1), sin(a1)) * r, a, b, b)
    }
}

// A ring between radii r0 and r1: colour c0 inside, c1 outside (a soft edge).
fn ring_band(g: *Gfx, c: vec2, r0: f32, r1: f32, c0: vec4, c1: vec4, n: i64) {
    a := color_u32(c0)
    b := color_u32(c1)
    for i in 0..n {
        a0 := TAU * f32(i) / f32(n)
        a1 := TAU * f32(i + 1) / f32(n)
        d0 := vec2(cos(a0), sin(a0))
        d1 := vec2(cos(a1), sin(a1))
        g.triangle(c + d0 * r0, c + d0 * r1, c + d1 * r1, a, b, b)
        g.triangle(c + d0 * r0, c + d1 * r1, c + d1 * r0, a, b, a)
    }
}
