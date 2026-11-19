// What Crypt's renderer draws, worked out on the CPU without any GPU code: the meshes (the
// maze with its wall torches and the exit's stone ring baked in, a cut gem, a wraith's robe,
// its eyes, the player's lantern), where the torches hang, the lights of a frame, and the
// effect quads of a frame (flames, embers, glows, sparkles, dust, the exit's runes and beam).
// The effects are pure functions of the game's time and state: nothing here is simulated or
// remembered between frames, so drawing never changes the game.
use "logic.al"

// One corner of a triangle: position, normal and colour (RGBA8, red in the lowest byte); the
// colour's alpha byte is the material (MAT_* here and in materials.al; see SCENE_BODY).
struct MeshVertex { pos: vec3, normal: vec3, color: u32 }

// A range of vertices of the mesh buffer.
struct Mesh { first: i64, count: i64 }

const MAT_WOOD = 3
const MAT_GEM = 4
const MAT_SPECTRAL = 5
const MAT_GLOW = 6
const MAT_STONE = 7
const MAT_IRON = 8

const MAX_TORCHES = 16
const TORCH_Y: f32 = 1.55                 // the height of a torch's bracket on the wall

// A torch on a wall: where its flame burns and the direction it faces (into the corridor).
struct Torch { flame: vec3, normal: vec3, seed: f32 }

// A colour and a material as a vertex colour.
fn mcol(c: vec3, id: i64) -> u32 { color_u32(vec4(c, f32(id) / 255.0)) }

// ---- building meshes ---------------------------------------------------------------------------

priv fn quad(v: *Vec[MeshVertex], a: vec3, b: vec3, c: vec3, d: vec3, n: vec3, col: u32) {
    // a b on one edge, c d on the other: two triangles
    v.push(MeshVertex{a, n, col})
    v.push(MeshVertex{b, n, col})
    v.push(MeshVertex{c, n, col})
    v.push(MeshVertex{c, n, col})
    v.push(MeshVertex{b, n, col})
    v.push(MeshVertex{d, n, col})
}

// A flat-shaded triangle whose normal points away from `inside`.
priv fn tri_out(v: *Vec[MeshVertex], a: vec3, b: vec3, c: vec3, inside: vec3, col: u32) {
    n := normalize(cross(b - a, c - a))
    if dot(n, (a + b + c) / 3.0 - inside) < 0.0 {
        n = -n
    }
    v.push(MeshVertex{a, n, col})
    v.push(MeshVertex{b, n, col})
    v.push(MeshVertex{c, n, col})
}

// A box of half-size `half` around `centre`, then moved by `m` (rotation and translation).
priv fn box(v: *Vec[MeshVertex], m: mat4, centre: vec3, half: vec3, col: u32) {
    for axis in 0..3 {
        for side in [_]f32{-1.0, 1.0} {
            n := vec3(0.0)
            n[axis] = side
            u := vec3(0.0)
            u[(axis + 1) % 3] = half[(axis + 1) % 3]
            w := vec3(0.0)
            w[(axis + 2) % 3] = half[(axis + 2) % 3]
            o := centre + n * half[axis]
            p := [4]vec3{o - u + w, o + u + w, o - u - w, o + u - w}
            for k in 0..4 {
                p[k] = transform_point(m, p[k])
            }
            quad(v, p[0], p[1], p[2], p[3], normalize(transform_dir(m, n)), col)
        }
    }
}

// Floor, ceiling and the wall faces that look into a floor cell, each tinted a little
// differently so that the repeated textures do not read as wallpaper.
priv fn build_maze(v: *Vec[MeshVertex]) {
    for r in 0..MAP_H {
        for c in 0..MAP_W {
            if is_wall(c, r) {
                continue
            }
            x0 := f32(c) * CELL
            z0 := f32(r) * CELL
            x1 := x0 + CELL
            z1 := z0 + CELL
            k := f32((c * 7 + r * 13) % 5) * 0.03
            quad(v, vec3(x0, 0.0, z0), vec3(x1, 0.0, z0), vec3(x0, 0.0, z1), vec3(x1, 0.0, z1), vec3(0.0, 1.0, 0.0),
                mcol(vec3(0.94 + k, 0.94 + k, 0.96), 0))
            quad(v, vec3(x0, WALL_H, z0), vec3(x1, WALL_H, z0), vec3(x0, WALL_H, z1), vec3(x1, WALL_H, z1), vec3(0.0, -1.0, 0.0),
                mcol(vec3(1.0), 2))
            h := WALL_H
            wc := fn(c: i64, r: i64, side: i64) -> u32 {
                j := f32((c * 5 + r * 11 + side * 3) % 7) * 0.025
                mcol(vec3(0.9 + j, 0.9 + j * 0.8, 0.9 + j * 0.6), 1)
            }
            if is_wall(c, r - 1) {
                quad(v, vec3(x0, h, z0), vec3(x1, h, z0), vec3(x0, 0.0, z0), vec3(x1, 0.0, z0), vec3(0.0, 0.0, 1.0), wc(c, r, 0))
            }
            if is_wall(c, r + 1) {
                quad(v, vec3(x1, h, z1), vec3(x0, h, z1), vec3(x1, 0.0, z1), vec3(x0, 0.0, z1), vec3(0.0, 0.0, -1.0), wc(c, r, 1))
            }
            if is_wall(c - 1, r) {
                quad(v, vec3(x0, h, z1), vec3(x0, h, z0), vec3(x0, 0.0, z1), vec3(x0, 0.0, z0), vec3(1.0, 0.0, 0.0), wc(c, r, 2))
            }
            if is_wall(c + 1, r) {
                quad(v, vec3(x1, h, z0), vec3(x1, h, z1), vec3(x1, 0.0, z0), vec3(x1, 0.0, z1), vec3(-1.0, 0.0, 0.0), wc(c, r, 3))
            }
        }
    }
}

// Where a torch's bracket is: on the wall, TORCH_Y up, its local +z pointing into the corridor.
priv fn torch_frame(t: Torch) -> mat4 {
    base := t.flame - t.normal * 0.2
    translate(vec3(base.x, TORCH_Y, base.z)) * rotate_y(atan2(t.normal.x, t.normal.z))
}

// The flame's place in the bracket's frame.
const TORCH_FLAME = vec3(0.0, 0.39, 0.2)

// A torch: an iron plate, an arm and a ring holding a wooden stick that leans out of the wall,
// its head glowing with embers.
priv fn build_torch(v: *Vec[MeshVertex], t: Torch) {
    m := torch_frame(t)
    iron := mcol(vec3(0.16, 0.15, 0.14), MAT_IRON)
    box(v, m, vec3(0.0, 0.0, 0.012), vec3(0.045, 0.1, 0.012), iron)
    box(v, m, vec3(0.0, -0.03, 0.07), vec3(0.015, 0.015, 0.06), iron)
    box(v, m, vec3(0.0, 0.0, 0.14), vec3(0.042, 0.014, 0.042), iron)
    lean := m * translate(vec3(0.0, 0.06, 0.14)) * rotate_x(0.35)
    box(v, lean, vec3(0.0, 0.0, 0.0), vec3(0.02, 0.17, 0.02), mcol(vec3(0.28, 0.17, 0.09), MAT_WOOD))
    box(v, lean, vec3(0.0, 0.2, 0.0), vec3(0.032, 0.045, 0.032), mcol(vec3(0.6, 0.16, 0.03), MAT_GLOW))
}

// A low ring of stone around the exit: its top, outer and inner sides.
priv fn build_exit_ring(v: *Vec[MeshVertex], centre: vec2) {
    segs := 24
    inner: f32 = 0.74
    outer: f32 = 0.94
    top: f32 = 0.06
    col := mcol(vec3(0.85, 0.82, 0.78), MAT_STONE)
    for k in 0..segs {
        a0 := f32(k) / f32(segs) * TAU
        a1 := f32(k + 1) / f32(segs) * TAU
        d0 := vec3(cos(a0), 0.0, sin(a0))
        d1 := vec3(cos(a1), 0.0, sin(a1))
        c := vec3(centre.x, 0.0, centre.y)
        up := vec3(0.0, top, 0.0)
        quad(v, c + d0 * inner + up, c + d1 * inner + up, c + d0 * outer + up, c + d1 * outer + up, vec3(0.0, 1.0, 0.0), col)
        mid := normalize(d0 + d1)
        quad(v, c + d0 * outer + up, c + d1 * outer + up, c + d0 * outer, c + d1 * outer, mid, col)
        quad(v, c + d0 * inner + up, c + d1 * inner + up, c + d0 * inner, c + d1 * inner, -mid, col)
    }
}

// A gem in a brilliant cut: an octagonal table on top, a crown of facets down to the girdle,
// a pavilion down to a point. White: the draw call tints it.
priv fn build_gem(v: *Vec[MeshVertex]) {
    col := mcol(vec3(1.0), MAT_GEM)
    sides := 8
    table: f32 = 0.11
    girdle: f32 = 0.2
    ty: f32 = 0.1
    gy: f32 = 0.02
    culet := vec3(0.0, -0.3, 0.0)
    inside := vec3(0.0, -0.02, 0.0)
    for k in 0..sides {
        a0 := f32(k) / f32(sides) * TAU
        a1 := f32(k + 1) / f32(sides) * TAU
        ah := (f32(k) + 0.5) / f32(sides) * TAU
        t0 := vec3(cos(a0) * table, ty, sin(a0) * table)
        t1 := vec3(cos(a1) * table, ty, sin(a1) * table)
        g0 := vec3(cos(a0) * girdle, gy, sin(a0) * girdle)
        g1 := vec3(cos(a1) * girdle, gy, sin(a1) * girdle)
        gh := vec3(cos(ah) * girdle * 1.04, gy, sin(ah) * girdle * 1.04)
        tri_out(v, vec3(0.0, ty, 0.0), t0, t1, vec3(0.0, -1.0, 0.0), col)       // the table
        tri_out(v, t0, t1, gh, inside, col)                                        // crown facets
        tri_out(v, t0, g0, gh, inside, col)
        tri_out(v, t1, gh, g1, inside, col)
        tri_out(v, g0, gh, culet, inside, col)                                    // pavilion
        tri_out(v, gh, g1, culet, inside, col)
    }
}

// A wraith's robe: a hooded shape turned around its axis (y up, the face towards -z), open at
// the hem, which the shader frays and ripples. White: tinted per draw.
priv fn build_wraith(v: *Vec[MeshVertex]) {
    col := mcol(vec3(1.0), MAT_SPECTRAL)
    profile := [_]vec2{vec2(0.97, 0.0), vec2(0.93, 0.1), vec2(0.84, 0.17), vec2(0.7, 0.2), vec2(0.6, 0.21),
        vec2(0.5, 0.3), vec2(0.25, 0.33), vec2(-0.15, 0.35), vec2(-0.5, 0.41), vec2(-0.9, 0.5)}
    segs := 24
    // smooth normals: at each point of the profile, the average of its two segments' normals
    // (x: outwards, y: up), turned around the axis with the point
    np := len(profile)
    pn: [10]vec2
    for i in 0..np {
        n := vec2(0.0)
        if i > 0 {
            d := profile[i] - profile[i - 1]
            n = n + normalize(vec2(-d.x, d.y))
        }
        if i + 1 < np {
            d := profile[i + 1] - profile[i]
            n = n + normalize(vec2(-d.x, d.y))
        }
        pn[i] = normalize(n)
    }
    for i in 0..np - 1 {
        for k in 0..segs {
            ring := [2]f32{f32(k) / f32(segs) * TAU, f32(k + 1) / f32(segs) * TAU}
            corner: [4]MeshVertex
            for j in 0..4 {
                pi := i + j / 2
                a := ring[j % 2]
                p := profile[pi]
                // the hood juts forward over the face
                jut := if p.x > 0.55 && p.x < 0.95 { 1.0 + 0.25 * fmax(-sin(a), 0.0) } else { 1.0 }
                n := pn[pi]
                corner[j] = MeshVertex{vec3(cos(a) * p.y * jut, p.x, sin(a) * p.y * jut), normalize(vec3(cos(a) * n.x, n.y, sin(a) * n.x)), col}
            }
            if profile[i].y > 0.0 {
                v.push(corner[0])
                v.push(corner[1])
                v.push(corner[2])
            }
            v.push(corner[2])
            v.push(corner[1])
            v.push(corner[3])
        }
    }
}

// The places of a wraith's two eyes in its frame.
const WRAITH_EYES = [2]vec3{vec3(-0.065, 0.72, -0.255), vec3(0.065, 0.72, -0.255)}

priv fn build_eye(v: *Vec[MeshVertex]) {
    box(v, mat4(1.0), vec3(0.0), vec3(0.02, 0.008, 0.01), mcol(vec3(1.0), MAT_GLOW))
}

// The player's lantern, about 0.3 m tall: an iron base, corner posts, a roof and a handle
// around a glowing glass box.
priv fn build_lantern(v: *Vec[MeshVertex]) {
    iron := mcol(vec3(0.2, 0.17, 0.14), MAT_IRON)
    id := mat4(1.0)
    box(v, id, vec3(0.0, -0.077, 0.0), vec3(0.056, 0.012, 0.056), iron)
    box(v, id, vec3(0.0, 0.074, 0.0), vec3(0.052, 0.01, 0.052), iron)
    for sx in [_]f32{-1.0, 1.0} {
        for sz in [_]f32{-1.0, 1.0} {
            box(v, id, vec3(0.046 * sx, 0.0, 0.046 * sz), vec3(0.007, 0.07, 0.007), iron)
        }
    }
    apex := vec3(0.0, 0.13, 0.0)
    for k in 0..4 {
        a0 := f32(k) * HALF_PI + PI / 4.0
        a1 := a0 + HALF_PI
        p0 := vec3(cos(a0) * 0.074, 0.084, sin(a0) * 0.074)
        p1 := vec3(cos(a1) * 0.074, 0.084, sin(a1) * 0.074)
        tri_out(v, p0, p1, apex, vec3(0.0, 0.05, 0.0), iron)
    }
    box(v, id, vec3(0.0, 0.165, 0.0), vec3(0.034, 0.006, 0.006), iron)
    box(v, id, vec3(-0.034, 0.148, 0.0), vec3(0.006, 0.02, 0.006), iron)
    box(v, id, vec3(0.034, 0.148, 0.0), vec3(0.006, 0.02, 0.006), iron)
    box(v, id, vec3(0.0, 0.036, 0.0), vec3(0.0425, 0.0025, 0.0425), iron)
    box(v, id, vec3(0.0, -0.038, 0.0), vec3(0.0425, 0.0025, 0.0425), iron)
    box(v, id, vec3(0.0), vec3(0.04, 0.064, 0.04), mcol(vec3(1.0, 0.48, 0.16), MAT_GLOW))
}

// All the meshes, in one vertex list.
struct Meshes { maze: Mesh, gem: Mesh, wraith: Mesh, eye: Mesh, lantern: Mesh }

fn build_meshes(v: *Vec[MeshVertex], torches: []Torch, exit: vec2) -> Meshes {
    m: Meshes
    build_maze(v)
    for t in torches {
        build_torch(v, t)
    }
    build_exit_ring(v, exit)
    m.maze = Mesh{0, v.len}
    first := v.len
    build_gem(v)
    m.gem = Mesh{first, v.len - first}
    first = v.len
    build_wraith(v)
    m.wraith = Mesh{first, v.len - first}
    first = v.len
    build_eye(v)
    m.eye = Mesh{first, v.len - first}
    first = v.len
    build_lantern(v)
    m.lantern = Mesh{first, v.len - first}
    m
}

// ---- torches -------------------------------------------------------------------------------------

// Hangs up to MAX_TORCHES torches: wall faces taken in a scrambled but fixed order, each at
// least 6.5 m from the others. Returns how many.
fn place_torches(out: *[MAX_TORCHES]Torch) -> i64 {
    n := 0
    total := MAP_W * MAP_H * 4
    dirs := [4](i64, i64){(1, 0), (-1, 0), (0, 1), (0, -1)}
    for k in 0..total {
        idx := (k * 97 + 31) % total
        cell := idx / 4
        side := idx % 4
        c := cell % MAP_W
        r := cell / MAP_W
        d := dirs[side]
        if is_wall(c, r) || !is_wall(c + d.0, r + d.1) {
            continue
        }
        normal := vec3(f32(-d.0), 0.0, f32(-d.1))
        centre := cell_center(c, r)
        face := vec3(centre.x, 0.0, centre.y) - normal * (CELL / 2.0)
        frame := translate(vec3(face.x, TORCH_Y, face.z)) * rotate_y(atan2(normal.x, normal.z))
        flame := transform_point(frame, TORCH_FLAME)
        far := true
        for i in 0..n {
            if distance(out[i].flame, flame) < 6.5 {
                far = false
            }
        }
        if far {
            out[n] = Torch{flame, normal, f32(n) * 1.37}
            n += 1
            if n == MAX_TORCHES {
                break
            }
        }
    }
    n
}

// How bright a flame is now (about 0.75 .. 1.05): three sines of unrelated rates.
fn flicker(t: f32, seed: f32) -> f32 {
    0.9 + 0.07 * sin(t * 9.1 + seed * 3.0) + 0.05 * sin(t * 23.7 + seed * 7.3) * sin(t * 3.3 + seed)
}

// The colour of each gem (by index): amber, aquamarine, emerald, ruby, amethyst, topaz, ...
const GEM_COLORS = [MAX_GEMS]vec3{vec3(1.0, 0.55, 0.08), vec3(0.18, 0.8, 1.0), vec3(0.25, 1.0, 0.35), vec3(1.0, 0.16, 0.25),
    vec3(0.65, 0.3, 1.0), vec3(1.0, 0.86, 0.3), vec3(0.18, 0.8, 1.0), vec3(1.0, 0.62, 0.12)}

// A gem's height above the floor now.
fn gem_height(t: f32, i: i64) -> f32 { 0.95 + 0.1 * sin(t * 2.0 + f32(i)) }

// ---- lights -------------------------------------------------------------------------------------

const MAX_LIGHTS = 16                 // as many as the shader's light_pos and light_color have
const MAX_CANDIDATES = 40

// A point light: where, how far it reaches, its colour times intensity, how fast it falls off
// (k in 1 / (1 + k d^2)) and whether the maze's walls cast its shadows.
struct Light { pos: vec3, radius: f32, color: vec3, falloff: f32, shadow: bool }

struct Lights { list: [MAX_CANDIDATES]Light, n: i64 }

priv fn add(l: *Lights, pos: vec3, radius: f32, color: vec3, falloff: f32, shadow: bool) {
    if l.n < MAX_CANDIDATES {
        l.list[l.n] = Light{pos, radius, color, falloff, shadow}
        l.n += 1
    }
}

// Every light of the frame: the player's lantern (at `lantern`; `flash` 0..1 is the lantern's
// flash), the torches, the gems still in place, the exit and the wraiths. The first one is the
// lantern.
fn gather_lights(l: *Lights, g: *Game, torches: []Torch, lantern: vec3, flash: f32, alpha: f32) {
    l.n = 0
    t := f32(g.time)
    title := g.mode == Title
    lamp := vec3(1.0, 0.6, 0.3) * 3.0 * flicker(t * 0.7, 9.0)
    add(l, lantern, 10.0 + flash * 6.0, lamp + vec3(0.7, 0.85, 1.0) * (22.0 * flash), 0.45, false)
    for tr in torches {
        add(l, tr.flame + vec3(0.0, -0.05, 0.0) + tr.normal * 0.08, 8.0, vec3(1.0, 0.46, 0.15) * 4.5 * flicker(t, tr.seed), 1.1, true)
    }
    for i in 0..g.n_gems {
        gem := g.gems[i]
        if gem.taken && !title {
            continue
        }
        add(l, vec3(gem.pos.x, gem_height(t, i), gem.pos.y), 4.5, GEM_COLORS[i] * 1.3, 1.2, true)
    }
    if exit_open(g) && !title {
        add(l, vec3(g.exit.x, 0.6, g.exit.y), 7.5, vec3(0.25, 1.0, 0.5) * (3.0 + 0.5 * sin(t * 3.0)), 0.6, true)
    } else {
        add(l, vec3(g.exit.x, 0.35, g.exit.y), 3.5, vec3(1.0, 0.14, 0.05) * (0.7 + 0.2 * sin(t * 1.7)), 0.8, true)
    }
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        p := lerp(e.prev, e.pos, alpha)
        c := if e.stun > 0.0 { vec3(0.35, 0.35, 0.5) * 0.4 } else { vec3(0.3, 0.42, 1.0) * 1.1 }
        add(l, vec3(p.x, 1.2, p.y), 4.5, c, 0.8, true)
    }
}

// The lights to draw: the lantern, then the MAX_LIGHTS - 1 others that matter most near the
// eye (by distance less half their reach).
fn pick_lights(l: *Lights, eye: vec3, out_pos: *[MAX_LIGHTS]vec4, out_color: *[MAX_LIGHTS]vec4) -> i64 {
    used: [MAX_CANDIDATES]bool
    n := 0
    for k in 0..MAX_LIGHTS {
        best := -1
        best_score: f32 = 1.0e9
        for i in 0..l.n {
            if used[i] {
                continue
            }
            s := if i == 0 { -1.0e8 } else { distance(l.list[i].pos, eye) - l.list[i].radius * 0.5 }
            if s < best_score {
                best_score = s
                best = i
            }
        }
        if best < 0 {
            break
        }
        used[best] = true
        li := l.list[best]
        out_pos[n] = vec4(li.pos, li.radius)
        out_color[n] = vec4(li.color, if li.shadow { li.falloff } else { -li.falloff })
        n += 1
    }
    n
}

// ---- effect quads ---------------------------------------------------------------------------------

// One corner of an effect quad: position, quad coordinates (-1..1), kind (FX_*), colour
// (rgb: colour times intensity, a: a random phase).
struct FxVertex { pos: vec3, uv: vec2, kind: f32, color: vec4 }

const FX_GLOW: f32 = 0.0
const FX_FLAME: f32 = 1.0
const FX_SPARK: f32 = 2.0
const FX_RUNES: f32 = 3.0
const FX_BEAM: f32 = 4.0

// The quads of a frame, written straight into a mapped upload buffer.
struct FxBatch {
    v: []FxVertex
    base: i64          // the first vertex of this frame's region
    count: i64         // quads written
    capacity: i64
    eye: vec3
    right: vec3        // the camera's axes
    up: vec3
}

// A quad around c with half-axes ax and ay (uv.y = 1 at c + ay).
fn fx_quad(b: *FxBatch, c: vec3, ax: vec3, ay: vec3, kind: f32, color: vec4) {
    if b.count >= b.capacity {
        return
    }
    i := b.base + b.count * 6
    va := FxVertex{c - ax + ay, vec2(-1.0, 1.0), kind, color}
    vb := FxVertex{c + ax + ay, vec2(1.0, 1.0), kind, color}
    vc := FxVertex{c - ax - ay, vec2(-1.0, -1.0), kind, color}
    vd := FxVertex{c + ax - ay, vec2(1.0, -1.0), kind, color}
    b.v[i] = va
    b.v[i + 1] = vb
    b.v[i + 2] = vc
    b.v[i + 3] = vc
    b.v[i + 4] = vb
    b.v[i + 5] = vd
    b.count += 1
}

// A quad facing the camera, of radius `size`, pulled towards the eye by part of its size so
// that a glow next to a wall is not cut in half by it. Quads very near the eye fade out (a
// spark drifting past the face would cover the view).
fn fx_billboard(b: *FxBatch, c: vec3, size: f32, kind: f32, color: vec4) {
    to := b.eye - c
    d := length(to)
    if d < 0.2 {
        return
    }
    p := c + to * (fmin(size * 0.6, d * 0.5) / d)
    near := smoothstep(0.2, 0.6, d)
    fx_quad(b, p, b.right * size, b.up * size, kind, vec4(vec3(color.x, color.y, color.z) * near, color.w))
}

// A glow of radius `size` set behind c as seen from the eye: a halo around an object that
// does not wash over it.
fn fx_halo(b: *FxBatch, c: vec3, size: f32, color: vec3) {
    away := normalize(c - b.eye) * (size * 0.6)
    fx_quad(b, c + away, b.right * size, b.up * size, FX_GLOW, vec4(color, 0.0))
}

// An upright quad (its y axis stays vertical) turned towards the camera: flames and beams.
fn fx_upright(b: *FxBatch, c: vec3, w: f32, h: f32, kind: f32, color: vec4) {
    to := b.eye - c
    side := normalize(vec3(to.z, 0.0, -to.x))
    fx_quad(b, c, side * w, vec3(0.0, h, 0.0), kind, color)
}

// A random number 0..1 for an integer (for the effects' fixed randomness).
fn fx_rand(i: i64) -> f32 {
    h := u64(i) * 0x9E3779B97F4A7C15
    h ^= h >> 29
    h *= 0xBF58476D1CE4E5B9
    h ^= h >> 32
    f32(h >> 40) / 16777216.0
}

// The effects of the world: torch flames with halos and rising embers, gems' halos and
// sparkles, the exit's runes (and beam and rising motes once open), wraiths' cold auras and
// red eyes, and dust drifting in the lantern's light around the eye.
fn world_fx(b: *FxBatch, g: *Game, torches: []Torch, lantern: vec3, alpha: f32) {
    t := f32(g.time)
    title := g.mode == Title
    for i, tr in torches {
        if distance(tr.flame, b.eye) > 22.0 {
            continue
        }
        f := flicker(t, tr.seed)
        fx_billboard(b, tr.flame, 0.9, FX_GLOW, vec4(vec3(1.0, 0.4, 0.1) * 0.5 * f, 0.0))
        fx_upright(b, tr.flame + vec3(0.0, 0.06, 0.0), 0.11, 0.2, FX_FLAME, vec4(vec3(1.3) * f, tr.seed))
        for k in 0..6 {
            ph := fract(t * 0.5 + fx_rand(i * 16 + k))
            sw := fx_rand(i * 16 + k + 8) * TAU
            p := tr.flame + vec3(sin(ph * 7.0 + sw) * 0.07 * ph, 0.05 + ph * 0.8, cos(ph * 5.0 + sw) * 0.07 * ph)
            fade := (1.0 - ph) * (1.0 - ph)
            fx_billboard(b, p, 0.012, FX_SPARK, vec4(vec3(1.0, 0.45, 0.1) * 6.0 * fade, 0.0))
        }
    }
    for i in 0..g.n_gems {
        gem := g.gems[i]
        if gem.taken && !title {
            continue
        }
        c := vec3(gem.pos.x, gem_height(t, i), gem.pos.y)
        col := GEM_COLORS[i]
        fx_halo(b, c, 0.5, col * 0.4)
        for k in 0..5 {
            a := t * 1.1 + f32(k) * 1.2566 + f32(i)
            p := c + vec3(cos(a) * 0.3, sin(t * 2.3 + f32(k) * 1.7) * 0.18, sin(a) * 0.3)
            tw := pow(fmax(sin(t * 4.0 + f32(k) * 2.1 + f32(i) * 0.7), 0.0), 6.0)
            fx_billboard(b, p, 0.03, FX_SPARK, vec4((col * 0.5 + vec3(0.5)) * (0.5 + 6.0 * tw), 0.0))
        }
    }
    ex := vec3(g.exit.x, 0.07, g.exit.y)
    open := exit_open(g) && !title
    if open {
        fx_quad(b, ex, vec3(0.92, 0.0, 0.0), vec3(0.0, 0.0, 0.92), FX_RUNES, vec4(vec3(0.25, 1.0, 0.55) * 2.4, 0.0))
        // the beam fades as the eye comes close, rather than filling the view
        near := smoothstep(0.5, 2.0, length(vec2(b.eye.x - ex.x, b.eye.z - ex.z)))
        fx_upright(b, ex + vec3(0.0, 1.2, 0.0), 0.62, 1.2, FX_BEAM, vec4(vec3(0.25, 1.0, 0.6) * (0.9 * near), 0.0))
        for k in 0..12 {
            ph := fract(t * 0.35 + fx_rand(500 + k))
            a := fx_rand(520 + k) * TAU + t * 0.6
            rad := 0.15 + 0.55 * fx_rand(540 + k)
            p := ex + vec3(cos(a) * rad, ph * 2.3, sin(a) * rad)
            fx_billboard(b, p, 0.02, FX_SPARK, vec4(vec3(0.4, 1.0, 0.7) * 4.0 * sin(ph * PI), 0.0))
        }
    } else {
        fx_quad(b, ex, vec3(0.92, 0.0, 0.0), vec3(0.0, 0.0, 0.92), FX_RUNES, vec4(vec3(1.0, 0.16, 0.05) * 0.7, 0.0))
    }
    for i in 0..g.n_enemies {
        e := g.enemies[i]
        p := lerp(e.prev, e.pos, alpha)
        stunned := e.stun > 0.0
        hover := 0.15 * sin(t * 3.0 + f32(i) * 2.0)
        body := wraith_frame(g, i, alpha)
        aura := if stunned { vec3(0.2, 0.2, 0.3) * 0.12 } else { vec3(0.1, 0.18, 0.7) * 0.3 }
        // the aura glows around the robe from behind it, not over it
        c := vec3(p.x, 1.0 + hover, p.y)
        away := normalize(c - b.eye) * 0.45
        fx_quad(b, c + away, b.right * 1.2, b.up * 1.4, FX_GLOW, vec4(aura, 0.0))
        if !stunned {
            for eye in WRAITH_EYES {
                fx_billboard(b, transform_point(body, eye), 0.08, FX_GLOW, vec4(vec3(1.0, 0.08, 0.02) * 2.5, 0.0))
            }
        }
    }
    // dust: motes on a grid that repeats every 7 m, so each stays put in the world as the eye
    // moves; only those near the lantern catch its light
    span: f32 = 7.0
    for k in 0..160 {
        base := vec3(fx_rand(k * 3), fx_rand(k * 3 + 1), fx_rand(k * 3 + 2))
        drift := vec3(t * 0.011, 0.0, t * 0.007)
        rel := vec3(fract(base.x + drift.x - b.eye.x / span), 0.0, fract(base.z + drift.z - b.eye.z / span)) - vec3(0.5, 0.0, 0.5)
        p := vec3(b.eye.x + rel.x * span, fract(base.y + t * 0.006 + 0.02 * sin(t * 0.4 + f32(k))) * WALL_H, b.eye.z + rel.z * span)
        if wall_at(vec2(p.x, p.z)) {
            continue
        }
        d := distance(p, lantern)
        lit := 1.0 / (1.0 + d * d * 2.5)
        if lit < 0.04 || distance(p, b.eye) < 0.45 {
            continue
        }
        fx_billboard(b, p, 0.007 + 0.007 * fx_rand(k + 999), FX_SPARK, vec4(vec3(1.0, 0.72, 0.45) * (2.2 * lit), 0.0))
    }
}

// Where wraith i is drawn: hovering, turned towards the player.
fn wraith_frame(g: *Game, i: i64, alpha: f32) -> mat4 {
    t := f32(g.time)
    e := g.enemies[i]
    p := lerp(e.prev, e.pos, alpha)
    to := g.pos - p
    face := atan2(-to.x, -to.y)
    hover := 0.15 * sin(t * 3.0 + f32(i) * 2.0)
    translate(vec3(p.x, 1.0 + hover, p.y)) * rotate_y(face) * scale(vec3(1.1))
}
