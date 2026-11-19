// The world and everything that moves in it: the terrain (a function of the seed, endless in
// both directions), the wanderer and the camera, the clock of the day, and the particles:
// fireflies, birds, falling leaves, rain, ripples and the odd shooting star. `update` is the
// only place the world changes; it runs in fixed steps, so a seed and the controls of each
// step decide everything (the renderer only reads).

const HZ = 60
const GROUND_Y = 236             // world y of the ground at height 0; up is -y
const SEG = 64                   // the terrain is made of segments of 64 columns
const LAKE_AT = 22               // a lake starts this many columns into its segment
const DAY_SECONDS: f64 = 150.0   // one day at normal speed
const FAST = 14.0                // T: time runs this many times faster
const ATTRACT_AFTER: f32 = 4.0   // seconds without input before the wanderer walks by itself

// ---- terrain

// The height of a column in tiles before lakes are cut in.
priv fn raw_height(tx: i64, seed: u32) -> i64 {
    x := f32(tx)
    v := 2.6 + noise2(x * 0.045, 0.5, seed) * 3.4 + noise2(x * 0.17, 4.5, seed + 1) * 1.2
    clamp(i64(round(v)), 0, 6)
}

struct Lake { start: i64, end: i64, shore: i64 }   // columns start..end are water; shore: height

// The lake of the segment that column tx is in, if it has one (end == start otherwise).
fn lake_of(tx: i64, seed: u32) -> Lake {
    s := if tx >= 0 { tx / SEG } else { (tx + 1) / SEG - 1 }
    if s != 0 && noise_hash(s, 1, 2, seed) % 3 != 0 {
        return Lake{}
    }
    a := s * SEG + LAKE_AT
    wide := 20 + i64(noise_hash(s, 3, 4, seed) % 10)
    Lake{start: a, end: a + wide, shore: raw_height(a - 5, seed)}
}

fn is_lake(tx: i64, seed: u32) -> bool {
    l := lake_of(tx, seed)
    tx >= l.start && tx < l.end
}

// The height of column tx in tiles (over a lake: the height of the bridge's deck).
fn height(tx: i64, seed: u32) -> i64 {
    l := lake_of(tx, seed)
    if l.end > l.start {
        if tx >= l.start - 5 && tx < l.end + 4 {
            return l.shore
        }
        if tx >= l.end + 4 && tx < l.end + 10 {        // back to the hills gently
            r := raw_height(tx, seed)
            return l.shore + (r - l.shore) * (tx - l.end - 3) / 7
        }
    }
    raw_height(tx, seed)
}

fn surface_y(tx: i64, seed: u32) -> f32 {
    f32(GROUND_Y - height(tx, seed) * TILE)
}

fn water_y(l: Lake) -> f32 {
    f32(GROUND_Y - l.shore * TILE + 7)
}

fn tile_x(x: f32) -> i64 {
    i64(floor(x / f32(TILE)))
}

// The highest ground under a body `half` pixels to either side of x.
fn ground_under(x: f32, half: f32, seed: u32) -> f32 {
    fmin(surface_y(tile_x(x - half), seed), surface_y(tile_x(x + half - 0.01), seed))
}

// ---- decoration of the playfield (a function of the column, like the terrain)

enum Deco { NoDeco, Tree(i64), Bush(i64), Rock(i64) }

fn deco_at(tx: i64, seed: u32) -> Deco {
    l := lake_of(tx, seed)
    if l.end > l.start && tx >= l.start - 2 && tx < l.end + 2 {
        return NoDeco
    }
    h := noise_hash(tx, 5, 6, seed)
    r := h % 100
    v := i64(h / 100)
    flat := height(tx - 1, seed) == height(tx, seed) && height(tx + 1, seed) == height(tx, seed)
    if r < 11 && flat && noise_hash(tx - 1, 5, 6, seed) % 100 >= 11 && noise_hash(tx - 2, 5, 6, seed) % 100 >= 11 {
        return Tree(v % 8)
    }
    if r >= 20 && r < 27 {
        return Bush(v % 3)
    }
    if r >= 30 && r < 34 && flat {
        return Rock(v % 3)
    }
    NoDeco
}

// ---- the wanderer

struct Hero {
    pos: vec2            // the middle of the feet, world pixels
    vel: vec2
    on_ground: bool
    facing: f32          // 1 right, -1 left
    anim: f32            // frame counter of the current animation
    coyote: f32          // time left to jump after walking off an edge
    buffer: f32          // a jump pressed shortly before landing
    jumping: bool        // rising from a jump (released early: cut short)
}

// What the player (or the attract mode) asks for in one step.
struct Controls {
    move: f32            // -1..1
    jump: bool           // pressed since the last step
    hold: bool           // held
    active: bool         // anything touched
}

const RUN_SPEED: f32 = 82.0
const GRAVITY: f32 = 760.0
const JUMP_SPEED: f32 = 245.0
const HERO_HALF: f32 = 3.0

fn step_hero(h: *Hero, c: Controls, dt: f32, seed: u32) {
    target := c.move * RUN_SPEED
    acc := if h.on_ground { 900.0 } else { 520.0 }
    if target > h.vel.x {
        h.vel.x = fmin(target, h.vel.x + acc * dt)
    } else {
        h.vel.x = fmax(target, h.vel.x - acc * dt)
    }
    if c.move > 0.1 { h.facing = 1.0 }
    if c.move < -0.1 { h.facing = -1.0 }
    // horizontal: walls higher than one tile stop the wanderer, one tile is stepped up
    nx := h.pos.x + h.vel.x * dt
    surf := ground_under(nx, HERO_HALF, seed)
    limit := if h.on_ground { f32(TILE) + 0.5 } else { 0.5 }
    if surf < h.pos.y - limit {
        h.vel.x = 0.0
    } else {
        h.pos.x = nx
        if h.on_ground && surf < h.pos.y {
            h.pos.y = surf
        }
    }
    // jumping: a press is remembered for a moment, and an edge forgives for a moment
    h.buffer = if c.jump { 0.12 } else { fmax(0.0, h.buffer - dt) }
    h.coyote = if h.on_ground { 0.09 } else { fmax(0.0, h.coyote - dt) }
    if h.buffer > 0.0 && h.coyote > 0.0 {
        h.vel.y = -JUMP_SPEED
        h.on_ground = false
        h.jumping = true
        h.buffer = 0.0
        h.coyote = 0.0
    }
    if h.jumping && !c.hold && h.vel.y < -90.0 {
        h.vel.y = -90.0                               // a short hop
    }
    // vertical
    under := ground_under(h.pos.x, HERO_HALF, seed)
    if h.on_ground && under > h.pos.y + 0.5 {
        h.on_ground = false                           // walked off an edge
    }
    if !h.on_ground {
        h.vel.y = fmin(h.vel.y + GRAVITY * dt, 420.0)
        h.pos.y += h.vel.y * dt
        if h.vel.y >= 0.0 {
            h.jumping = false
            if h.pos.y >= under {
                h.pos.y = under
                h.vel.y = 0.0
                h.on_ground = true
            }
        }
    }
    h.anim += if h.on_ground && fabs(h.vel.x) > 8.0 { fabs(h.vel.x) * dt / 9.0 } else { dt * 3.0 }
}

// ---- particles

struct Fly { pos: vec2, phase: f32, speed: f32 }
struct Leaf { pos: vec2, vel: vec2, spin: f32, kind: i64, rest: f32 }   // rest > 0: lying on the ground
struct Drop { pos: vec2, speed: f32 }
struct Ripple { pos: vec2, age: f32 }
struct Bird { pos: vec2, phase: f32 }
struct Star { pos: vec2, bright: f32, phase: f32 }

const FLIES = 28
const LEAVES = 26
const DROPS = 220
const RIPPLES = 32
const BIRDS = 7
const STARS = 240

struct World {
    seed: u32
    rng: Rng
    steps: i64
    time: f64            // seconds since the start
    tod: f64             // time of day, 0..1 (0: midnight, 0.5: noon)
    fast: bool
    day_secs: f64        // seconds of one day at normal speed
    hero: Hero
    prev_pos: vec2       // the hero and the camera one step earlier, for interpolation
    cam: vec2            // world position of the top left corner of the view
    prev_cam: vec2
    idle: f32            // seconds without input
    attract: bool
    ai_wait: f32         // the attract mode stops to look at the view
    ai_hold: f32
    wind: f32            // -1..1, positive: to the right
    rain: bool
    rain_k: f32          // 0..1: how much it rains (fades in and out)
    flies: [FLIES]Fly
    leaves: [LEAVES]Leaf
    drops: [DROPS]Drop
    ripples: [RIPPLES]Ripple
    next_ripple: i64
    birds: [BIRDS]Bird
    flock_dir: f32       // 0: no flock in the sky
    flock_wait: f32
    stars: [STARS]Star
    meteor_pos: vec2
    meteor_vel: vec2
    meteor_age: f32      // < 0: none
    meteor_wait: f32
}

fn world_new(seed: u32, tod: f64) -> World {
    w := World{seed: seed, rng: rng(u64(seed)), tod: tod, day_secs: DAY_SECONDS, meteor_age: -1.0}
    w.hero = Hero{pos: vec2(f32(6 * TILE), 0.0), facing: 1.0, on_ground: true}
    w.hero.pos.y = ground_under(w.hero.pos.x, HERO_HALF, seed)
    w.cam = cam_target(&w)
    w.prev_cam = w.cam
    w.prev_pos = w.hero.pos
    for i in 0..STARS {
        r := &w.rng
        w.stars[i] = Star{pos: vec2(r.range(0.0, f32(VIEW_W)), pow(r.next_f32(), 1.5) * 175.0),
            bright: pow(r.next_f32(), 1.6), phase: r.range(0.0, TAU)}
    }
    for i in 0..FLIES {
        w.flies[i] = Fly{pos: vec2(w.cam.x + w.rng.range(0.0, f32(VIEW_W)), 0.0), phase: w.rng.range(0.0, TAU),
            speed: w.rng.range(0.6, 1.4)}
        w.flies[i].pos.y = surface_y(tile_x(w.flies[i].pos.x), seed) - w.rng.range(4.0, 40.0)
    }
    for i in 0..LEAVES {
        respawn_leaf(&w, i, true)
    }
    for i in 0..DROPS {
        w.drops[i] = Drop{pos: vec2(w.cam.x + w.rng.range(-40.0, f32(VIEW_W)), w.cam.y + w.rng.range(-20.0, f32(VIEW_H))),
            speed: w.rng.range(260.0, 340.0)}
    }
    for i in 0..RIPPLES {
        w.ripples[i].age = 99.0
    }
    w.flock_wait = 2.0
    w.meteor_wait = 4.0
    w
}

fn cam_target(w: *World) -> vec2 {
    h := &w.hero
    vec2(h.pos.x - f32(VIEW_W) * 0.42 + h.facing * 26.0, (h.pos.y - 224.0) * 0.75)
}

fn respawn_leaf(w: *World, i: i64, anywhere: bool) {
    r := &w.rng
    y := if anywhere { r.range(110.0, 220.0) } else { r.range(110.0, 160.0) }
    w.leaves[i] = Leaf{pos: vec2(w.cam.x + r.range(-60.0, f32(VIEW_W) + 20.0), w.cam.y + y),
        vel: vec2(0.0, r.range(10.0, 20.0)), spin: r.range(0.0, TAU), kind: r.range(0, 4)}
}

// The controls of the attract mode: walk on, jump at walls and now and then for fun, and stop
// sometimes to look at the view.
fn autopilot(w: *World) -> Controls {
    h := &w.hero
    c := Controls{}
    if w.ai_wait > 0.0 {
        return c
    }
    c.move = 1.0
    ahead := surface_y(tile_x(h.pos.x + 12.0), w.seed)
    if h.on_ground && ahead < h.pos.y - f32(TILE) - 0.5 {
        c.jump = true
        w.ai_hold = 0.4
    }
    if h.on_ground && w.rng.chance(0.004) {
        c.jump = true
        w.ai_hold = w.rng.range(0.05, 0.4)
    }
    c.hold = w.ai_hold > 0.0
    c
}

fn update(w: *World, c: Controls, dt: f32) {
    w.steps += 1
    w.time += f64(dt)
    w.tod = fract(w.tod + f64(dt) / w.day_secs * (if w.fast { f64(FAST) } else { 1.0 }))
    w.prev_pos = w.hero.pos
    w.prev_cam = w.cam
    // attract mode
    if c.active {
        w.idle = 0.0
        w.attract = false
    } else {
        w.idle += dt
        if w.idle > ATTRACT_AFTER && !w.attract {
            w.attract = true
            w.ai_wait = 0.0
        }
    }
    if w.attract {
        w.ai_hold = fmax(0.0, w.ai_hold - dt)
        if w.ai_wait > 0.0 {
            w.ai_wait -= dt
        } else if w.hero.on_ground && !is_lake(tile_x(w.hero.pos.x), w.seed) && w.rng.chance(0.0016) {
            w.ai_wait = w.rng.range(1.5, 3.5)
        }
        c = autopilot(w)
    }
    step_hero(&w.hero, c, dt, w.seed)
    // the camera eases towards a point a little ahead of the wanderer
    t := cam_target(w)
    w.cam.x += (t.x - w.cam.x) * (1.0 - exp(-dt * 3.2))
    w.cam.y += (t.y - w.cam.y) * (1.0 - exp(-dt * 2.0))
    // wind: slow gusts
    w.wind = 0.3 + noise2(f32(w.time) * 0.11, 0.5, w.seed + 40) * 1.1
    w.rain_k = clamp(w.rain_k + (if w.rain { dt * 0.5 } else { -dt * 0.5 }), 0.0, 1.0)
    update_particles(w, dt)
}

fn update_particles(w: *World, dt: f32) {
    seed := w.seed
    t := f32(w.time)
    left := w.cam.x - 40.0
    span := f32(VIEW_W) + 80.0
    // fireflies drift on a noise field near the ground
    for i in 0..FLIES {
        f := &w.flies[i]
        fi := f32(i) * 7.3
        f.pos = f.pos + vec2(noise2(t * 0.35 * f.speed, fi, seed + 50), noise2(fi, t * 0.4 * f.speed, seed + 51)) * (26.0 * dt)
        ground := surface_y(tile_x(f.pos.x), seed)
        f.pos.y = clamp(f.pos.y, ground - 56.0, ground - 3.0)
        if f.pos.x < left || f.pos.x > left + span {
            f.pos.x = left + fmod(f.pos.x - left + span * 4.0, span)
            f.pos.y = surface_y(tile_x(f.pos.x), seed) - w.rng.range(4.0, 40.0)
        }
    }
    // leaves tumble down on the wind and rest a while on the ground
    for i in 0..LEAVES {
        l := &w.leaves[i]
        if l.rest > 0.0 {
            l.rest -= dt
            if l.rest <= 0.0 {
                respawn_leaf(w, i, false)
            }
            continue
        }
        l.spin += dt * (2.0 + f32(i % 3))
        l.vel.x = w.wind * 34.0 + sin(l.spin) * 14.0
        l.vel.y = 13.0 + cos(l.spin * 0.7) * 6.0
        l.pos = l.pos + l.vel * dt
        if l.pos.y >= surface_y(tile_x(l.pos.x), seed) - 1.0 && !is_lake(tile_x(l.pos.x), seed) {
            l.rest = w.rng.range(1.5, 4.0)
        }
        if l.pos.y > w.cam.y + f32(VIEW_H) + 10.0 || l.pos.x > left + span + 40.0 || l.pos.x < left - 40.0 {
            respawn_leaf(w, i, false)
        }
    }
    // rain falls where the camera is; drops that reach water make ripples
    if w.rain_k > 0.0 {
        for i in 0..DROPS {
            d := &w.drops[i]
            d.pos = d.pos + vec2(w.wind * 60.0 + 30.0, d.speed) * dt
            tx := tile_x(d.pos.x)
            l := lake_of(tx, seed)
            lake := tx >= l.start && tx < l.end
            floor_y := if lake { water_y(l) } else { surface_y(tx, seed) }
            if d.pos.y >= floor_y || d.pos.x > left + span + 40.0 {
                if lake && w.rng.chance(w.rain_k * 0.5) {
                    add_ripple(w, vec2(d.pos.x, floor_y))
                }
                d.pos = vec2(left + w.rng.range(-60.0, span), w.cam.y - w.rng.range(0.0, 60.0))
            }
        }
    }
    // now and then a fish rises in the lake
    if w.rng.chance(0.012) {
        tx := tile_x(w.cam.x + w.rng.range(0.0, f32(VIEW_W)))
        l := lake_of(tx, seed)
        if tx >= l.start + 1 && tx < l.end - 1 {
            add_ripple(w, vec2(f32(tx * TILE) + w.rng.range(0.0, 8.0), water_y(l) + w.rng.range(4.0, 30.0)))
        }
    }
    for i in 0..RIPPLES {
        w.ripples[i].age += dt
    }
    // a flock of birds crosses the sky by day
    if w.flock_dir == 0.0 {
        w.flock_wait -= dt
        if w.flock_wait <= 0.0 {
            w.flock_dir = if w.rng.chance(0.5) { 1.0 } else { -1.0 }
            y := w.rng.range(36.0, 96.0)
            for i in 0..BIRDS {
                rank := f32((i + 1) / 2)
                side := if i % 2 == 0 { 1.0 } else { -1.0 }
                x := if w.flock_dir > 0.0 { -20.0 - rank * 9.0 } else { f32(VIEW_W) + 20.0 + rank * 9.0 }
                w.birds[i] = Bird{pos: vec2(x, y + rank * side * 6.0 + w.rng.range(-1.0, 1.0)), phase: w.rng.range(0.0, TAU)}
            }
        }
    } else {
        out := 0
        for i in 0..BIRDS {
            b := &w.birds[i]
            b.phase += dt * 9.0
            b.pos.x += w.flock_dir * (30.0 + f32(i % 3)) * dt
            b.pos.y += sin(t * 1.3 + f32(i)) * 3.0 * dt
            if b.pos.x < -60.0 || b.pos.x > f32(VIEW_W) + 60.0 {
                out += 1
            }
        }
        if out == BIRDS {
            w.flock_dir = 0.0
            w.flock_wait = w.rng.range(5.0, 12.0)
        }
    }
    // shooting stars at night
    if w.meteor_age >= 0.0 {
        w.meteor_age += dt
        w.meteor_pos = w.meteor_pos + w.meteor_vel * dt
        if w.meteor_age > 0.9 {
            w.meteor_age = -1.0
        }
    } else {
        w.meteor_wait -= dt
        if w.meteor_wait <= 0.0 {
            w.meteor_wait = w.rng.range(3.0, 9.0)
            w.meteor_age = 0.0
            dir := if w.rng.chance(0.5) { 1.0 } else { -1.0 }
            w.meteor_pos = vec2(w.rng.range(60.0, f32(VIEW_W) - 60.0), w.rng.range(10.0, 60.0))
            w.meteor_vel = vec2(dir * w.rng.range(150.0, 230.0), w.rng.range(50.0, 90.0))
        }
    }
}

fn add_ripple(w: *World, p: vec2) {
    w.ripples[w.next_ripple] = Ripple{pos: p, age: 0.0}
    w.next_ripple = (w.next_ripple + 1) % RIPPLES
}

// A number that sums up the state of the world, for the test (independent of the GPU).
fn world_check(w: *World) -> u64 {
    hash((w.hero.pos, w.hero.vel, w.cam, w.tod, w.steps, w.attract))
}
