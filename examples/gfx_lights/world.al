// The chamber and everything in it that moves: the blocks that cast shadows, the lights, the
// embers and sparks they throw off and the dust in the air. Advanced at a fixed step from a
// seed; nothing here draws (lighting.al and game.al read it).

const VW = 1280                          // the virtual resolution everything is laid out in
const VH = 720
const HZ = 60.0                          // simulation steps per second
const ROOM_CENTER = vec2(640.0, 380.0)   // the middle of the rune circle, the orb's orbit
const ORB_ORBIT: f32 = 196.0
const MAX_LIGHTS = 16
const MAX_PARTICLES = 1024
const MOTES = 220
const PICK_RADIUS: f32 = 26.0            // a click this close to a light removes it

// The floor area between the outer walls.
const ROOM_MIN = vec2(48.0, 72.0)
const ROOM_MAX = vec2(1232.0, 680.0)

enum BlockKind { Wall, Pillar, Crate }

// A solid rectangle (x, y, w, h): drawn into the albedo, casts shadows. Walls that meet overlap,
// so that no light leaks through the seam once lighting.al shrinks them by its INSET.
struct Block { r: vec4, kind: BlockKind }

const BLOCKS = [_]Block{
    Block{vec4(0.0, 0.0, 1280.0, 72.0), Wall},        // outer walls: top, bottom, left, right
    Block{vec4(0.0, 680.0, 1280.0, 40.0), Wall},
    Block{vec4(0.0, 0.0, 48.0, 720.0), Wall},
    Block{vec4(1232.0, 0.0, 48.0, 720.0), Wall},
    Block{vec4(24.0, 318.0, 196.0, 40.0), Wall},      // a wall that juts in from the left
    Block{vec4(1040.0, 48.0, 40.0, 190.0), Wall},     // an alcove at the top right
    Block{vec4(1040.0, 202.0, 96.0, 36.0), Wall},
    Block{vec4(552.0, 640.0, 40.0, 60.0), Wall},      // two stubs at the bottom
    Block{vec4(688.0, 640.0, 40.0, 60.0), Wall},
    Block{vec4(352.0, 214.0, 64.0, 64.0), Pillar},    // four pillars around the rune circle
    Block{vec4(864.0, 214.0, 64.0, 64.0), Pillar},
    Block{vec4(352.0, 482.0, 64.0, 64.0), Pillar},
    Block{vec4(864.0, 482.0, 64.0, 64.0), Pillar},
    Block{vec4(86.0, 572.0, 50.0, 50.0), Crate},      // crates
    Block{vec4(142.0, 600.0, 40.0, 40.0), Crate},
    Block{vec4(96.0, 530.0, 34.0, 34.0), Crate},
    Block{vec4(1150.0, 586.0, 48.0, 48.0), Crate},
    Block{vec4(1112.0, 622.0, 32.0, 32.0), Crate},
    Block{vec4(258.0, 96.0, 44.0, 44.0), Crate},
}

enum LightKind { Torch, Orb, Lantern, Wisp }

struct Light {
    kind: LightKind
    home: vec2          // torches: the flame at rest; wisps: where they were placed
    pos: vec2
    prev: vec2          // pos one step earlier: drawing interpolates between the two
    color: vec3
    radius: f32         // the light reaches 0 here
    power: f32          // brightness at the centre (1: a white surface at full brightness)
    size: f32           // radius of the flame or bulb: the spread of the sub-lights, the penumbra
    seed: f32           // the light's own noise offset
    level: f32          // flicker of this step (multiplies power)
}

enum PartKind { Ember, Spark }

// An ember of a torch or a spark of a magic light: drawn additively, never casts light.
struct Particle {
    kind: PartKind
    pos: vec2
    vel: vec2
    life: f32           // seconds left
    span: f32           // seconds it lived at birth
    size: f32
    color: vec3
}

struct Mote { pos: vec2, size: f32, phase: f32 }

// What the window tells the simulation each step (the scripted runs make it up).
struct Control {
    mouse: vec2         // in virtual pixels
    mouse_moved: bool
    click: bool
}

struct World {
    rng: Rng
    t: f64              // simulated seconds
    steps: i64
    lights: Vec[Light]
    parts: Vec[Particle]
    motes: Vec[Mote]
    mouse_idle: f32     // seconds since the mouse last moved: the lantern wanders after a while
    mouse: vec2
    next_color: i64
    added: i64          // lights added and removed by clicks (printed by the test)
    removed: i64
}

// Colours of the lights a click adds, in turn.
const WISP_COLORS = [_]vec3{
    vec3(0.30, 1.00, 0.55),
    vec3(1.00, 0.28, 0.32),
    vec3(0.30, 0.80, 1.00),
    vec3(1.00, 0.78, 0.30),
    vec3(0.90, 0.40, 1.00),
}

const TORCH_COLOR = vec3(1.0, 0.56, 0.22)
const ORB_COLOR = vec3(0.50, 0.42, 1.0)
const LANTERN_COLOR = vec3(1.0, 0.86, 0.62)

// Where the torches burn: the flame, in front of its iron bracket on the wall.
const TORCHES = [_]vec2{vec2(300.0, 92.0), vec2(840.0, 92.0), vec2(68.0, 520.0), vec2(1212.0, 420.0), vec2(470.0, 660.0)}

fn torch(p: vec2, seed: f32) -> Light {
    Light{kind: Torch, home: p, pos: p, prev: p, color: TORCH_COLOR, radius: 380.0, power: 1.65, size: 7.0, seed: seed, level: 1.0}
}

fn world_new(seed: u64) -> World {
    w := World{rng: rng(seed)}
    w.lights.reserve(MAX_LIGHTS)
    w.parts.reserve(MAX_PARTICLES)
    w.motes.reserve(MOTES)
    for i, p in TORCHES {
        w.lights.push(torch(p, f32(i) * 17.3 + 3.0))
    }
    orb := ROOM_CENTER + vec2(ORB_ORBIT, 0.0)
    w.lights.push(Light{kind: Orb, home: ROOM_CENTER, pos: orb, prev: orb, color: ORB_COLOR, radius: 400.0, power: 1.55, size: 9.0,
        seed: 0.0, level: 1.0})
    lp := lantern_path(0.0)
    w.lights.push(Light{kind: Lantern, home: lp, pos: lp, prev: lp, color: LANTERN_COLOR, radius: 300.0, power: 1.35, size: 4.0, seed: 91.0,
        level: 1.0})
    for i in 0..MOTES {
        p := vec2(w.rng.range(ROOM_MIN.x, ROOM_MAX.x), w.rng.range(ROOM_MIN.y, ROOM_MAX.y))
        w.motes.push(Mote{pos: p, size: w.rng.range(0.8, 2.2), phase: w.rng.range(0.0, 100.0)})
    }
    w.mouse_idle = 1000.0
    w
}

// Where the lantern wanders while nobody moves the mouse: a slow Lissajous loop through the room.
fn lantern_path(t: f32) -> vec2 {
    vec2(640.0 + 455.0 * sin(t * 0.21 + 2.2), 380.0 + 215.0 * sin(t * 0.33 + 0.4))
}

// Whether p lies inside a block grown by `margin`.
fn in_block(p: vec2, margin: f32) -> bool {
    for b in BLOCKS {
        if p.x > b.r.x - margin && p.x < b.r.x + b.r.z + margin && p.y > b.r.y - margin && p.y < b.r.y + b.r.w + margin {
            return true
        }
    }
    false
}

// p moved out of every block (grown by margin) by the shortest way.
fn push_out(p: vec2, margin: f32) -> vec2 {
    q := p
    for pass in 0..2 {
        for b in BLOCKS {
            x0 := b.r.x - margin
            y0 := b.r.y - margin
            x1 := b.r.x + b.r.z + margin
            y1 := b.r.y + b.r.w + margin
            if q.x > x0 && q.x < x1 && q.y > y0 && q.y < y1 {
                dl := q.x - x0
                dr := x1 - q.x
                dt := q.y - y0
                db := y1 - q.y
                m := min(min(dl, dr), min(dt, db))
                if m == dl {
                    q.x = x0
                } else if m == dr {
                    q.x = x1
                } else if m == dt {
                    q.y = y0
                } else {
                    q.y = y1
                }
            }
        }
    }
    clamp(q, ROOM_MIN + vec2(margin), ROOM_MAX - vec2(margin))
}

fn spawn(w: *World, p: Particle) {
    if w.parts.len < MAX_PARTICLES {
        w.parts.push(p)
    }
}

// One step of dt seconds.
fn world_update(w: *World, c: Control, dt: f32) {
    w.t += f64(dt)
    w.steps += 1
    t := f32(w.t)
    w.mouse_idle = if c.mouse_moved { 0.0 } else { w.mouse_idle + dt }
    w.mouse = c.mouse
    if c.click {
        click(w, c.mouse)
    }
    for i in 0..w.lights.len {
        l := &w.lights[i]
        l.prev = l.pos
        match l.kind {
            Torch => {
                n := noise2(t * 4.3, l.seed) * 0.6 + noise2(t * 11.0, l.seed + 7.7) * 0.4
                gust := noise2(t * 0.7, l.seed + 31.0)            // now and then a draught
                l.level = 0.9 + 0.3 * n - 0.12 * max(gust, 0.0)
                l.pos = l.home + vec2(noise2(t * 2.6, l.seed + 3.1), noise2(t * 2.2, l.seed + 5.9)) * 2.5
                emit(w, i, 26.0 * l.level, dt)
            }
            Orb => {
                a := t * 0.37 + 0.6
                r := ORB_ORBIT + 16.0 * sin(t * 0.83)
                l.pos = ROOM_CENTER + vec2(cos(a), sin(a)) * r
                l.level = 0.9 + 0.1 * sin(t * 2.3) + 0.05 * noise2(t * 3.0, 4.0)
                emit(w, i, 40.0, dt)
            }
            Lantern => {
                target := if w.mouse_idle < 3.0 { c.mouse } else { lantern_path(t) }
                l.pos = push_out(l.pos + (target - l.pos) * (1.0 - exp(-7.0 * dt)), 12.0)
                l.level = 0.97 + 0.04 * noise2(t * 7.0, l.seed)
            }
            Wisp => {
                l.pos = l.home + vec2(sin(t * 1.1 + l.seed) * 7.0, cos(t * 1.37 + l.seed) * 5.0)
                l.level = 0.88 + 0.12 * sin(t * 2.1 + l.seed)
                emit(w, i, 14.0, dt)
            }
        }
    }
    move_particles(w, t, dt)
    move_motes(w, t, dt)
}

// A click removes the nearest light (not the lantern) under the pointer, or adds a wisp.
fn click(w: *World, p: vec2) {
    best := -1
    best_d := PICK_RADIUS
    for i, l in w.lights {
        d := distance(l.pos, p)
        if l.kind != Lantern && d < best_d {
            best = i
            best_d = d
        }
    }
    if best >= 0 {
        w.lights.remove(best)
        w.removed += 1
        return
    }
    if w.lights.len >= MAX_LIGHTS || in_block(p, 10.0) {
        return
    }
    color := WISP_COLORS[w.next_color % len(WISP_COLORS)]
    w.next_color += 1
    w.lights.push(Light{kind: Wisp, home: p, pos: p, prev: p, color: color, radius: 300.0, power: 1.4, size: 5.0,
        seed: f32(w.next_color) * 2.7, level: 1.0})
    w.added += 1
}

// Particles from light i at `rate` per second.
fn emit(w: *World, i: i64, rate: f32, dt: f32) {
    l := w.lights[i]
    if !w.rng.chance(rate * dt) {
        return
    }
    match l.kind {
        Torch => {
            p := l.pos + vec2(w.rng.range(-4.0, 4.0), w.rng.range(-10.0, -2.0))
            v := vec2(w.rng.range(-18.0, 18.0), w.rng.range(-70.0, -30.0))
            life := w.rng.range(0.6, 1.9)
            col := lerp(vec3(1.0, 0.85, 0.4), vec3(1.0, 0.45, 0.12), w.rng.next_f32())
            spawn(w, Particle{Ember, p, v, life, life, w.rng.range(1.2, 2.4), col})
        }
        Orb, Wisp => {
            d := w.rng.in_circle()
            p := l.pos + d * l.size * 1.4
            v := d * w.rng.range(10.0, 34.0) + (l.pos - l.prev) * 20.0
            life := w.rng.range(0.5, 1.3)
            col := lerp(l.color, vec3(1.0), w.rng.range(0.1, 0.6))
            spawn(w, Particle{Spark, p, v, life, life, w.rng.range(1.0, 2.0), col})
        }
        Lantern => {}
    }
}

fn move_particles(w: *World, t: f32, dt: f32) {
    for i in 0..w.parts.len {
        p := &w.parts[i]
        swirl := noise3(p.pos.x * 0.025, p.pos.y * 0.025, t * 0.6 + f32(i % 7))
        match p.kind {
            Ember => {
                p.vel.x += swirl * 140.0 * dt
                p.vel.y -= 14.0 * dt                              // heat carries it up the screen
                p.vel = p.vel * (1.0 - 0.9 * dt)
            }
            Spark => {
                p.vel = p.vel * (1.0 - 1.8 * dt) + vec2(-p.vel.y, p.vel.x) * swirl * 1.5 * dt
            }
        }
        p.pos = p.pos + p.vel * dt
        p.life -= dt
    }
    w.parts.retain(fn(p: Particle) -> bool { p.life > 0.0 && !in_block(p.pos, -6.0) })
}

// Dust drifts on a slowly turning flow field and wraps around the room.
fn move_motes(w: *World, t: f32, dt: f32) {
    size := ROOM_MAX - ROOM_MIN
    for i in 0..w.motes.len {
        m := &w.motes[i]
        a := noise3(m.pos.x * 0.004, m.pos.y * 0.004, t * 0.05 + 3.0) * 6.0
        v := vec2(cos(a), sin(a)) * 9.0 + vec2(sin(t * 0.7 + m.phase), cos(t * 0.5 + m.phase)) * 3.0
        m.pos = m.pos + v * dt
        if m.pos.x < ROOM_MIN.x { m.pos.x += size.x }
        if m.pos.x > ROOM_MAX.x { m.pos.x -= size.x }
        if m.pos.y < ROOM_MIN.y { m.pos.y += size.y }
        if m.pos.y > ROOM_MAX.y { m.pos.y -= size.y }
    }
}

// A checksum of the state: the same seed and inputs give the same value on every machine.
fn world_checksum(w: *World) -> u64 {
    h: u64 = 1469598103934665603
    fn mix(h: u64, x: f32) -> u64 { (h ^ u64(cast[u32](x))) * 1099511628211 }
    for l in w.lights {
        h = mix(mix(mix(h, l.pos.x), l.pos.y), l.level)
    }
    for p in w.parts {
        h = mix(mix(h, p.pos.x), p.pos.y)
    }
    for m in w.motes {
        h = mix(mix(h, m.pos.x), m.pos.y)
    }
    h
}
