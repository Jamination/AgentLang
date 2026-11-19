// The visual effects of the software starter (game.al): explosions, debris, sparks, shock
// waves, score pop-ups, screen shake and flashes. They live here, outside `Game`: the front end
// shows them, the simulation never sees them, and a headless run of the game is the same with
// or without them.
//   - what happened is read from the game after its steps: its event list (the one the DX12
//     version plays sounds from) says when the player was hurt or a shot fired; the rest comes
//     from comparing the entities with those of the previous frame (a rock that vanished above
//     the bottom edge was destroyed, a shot that vanished below the top hit something)
//   - effects advance by the game time of the frame's steps, so they pause with the game, and
//     use their own random generator, never the game's
use "art.al"

enum PKind { Flash, Fire, Smoke, Ember, Debris, Shard, Ring, Pop }

// One particle, in framebuffer pixels and seconds.
struct Particle {
    kind: PKind
    pos: vec2
    vel: vec2
    age: f32
    life: f32
    size: f32        // pixels across at birth
    grow: f32        // size at death / size at birth
    angle: f32
    spin: f32
    look: i64        // which rock, shard or smoke mask; the points of a pop-up
    color: vec3
}

// What the previous frame saw in one slot of the entity pool.
struct Seen { live: bool, gen: u32, kind: Kind, pos: vec2, vel: vec2, radius: f32, hp: i32 }

const MAX_PARTICLES = 1500

struct Fx {
    rng: Rng
    parts: []Particle                // MAX_PARTICLES, the first `count` alive
    count: i64
    seen: []Seen                     // one per pool slot
    hit: []f32                       // per pool slot: time left of a rock's hit flash
    shake: f32                       // trauma, 0..1: the shake is its square
    hurt: f32                        // red flash at the edges, 0..1
    white: f32                       // white flash over everything, 0..1
    muzzle: f32                      // the ship's muzzle flash, 0..1
    roll: f32                        // the ship's roll, -1..1, following its sideways speed
    hp_lost: f32                     // seconds since a life was lost (HUD blink)
    score_pulse: f32                 // 1 when the score changed, fading
    over_time: f32                   // seconds since the game ended (0 while it runs)
    time: f32
    last_score: i64
    last_player: vec2                // where the player was (for the explosion when it is gone)
}

fn fx_new(slots: i64) -> Fx {
    fx: Fx
    fx.rng = rng(99)
    fx.parts = alloc[Particle](MAX_PARTICLES)
    fx.seen = alloc[Seen](slots)
    fx.hit = alloc[f32](slots)
    fx.hp_lost = 10.0
    fx
}

fn spawn(fx: *Fx, p: Particle) {
    if fx.count == MAX_PARTICLES {
        fx.parts[fx.rng.range(0, MAX_PARTICLES)] = p       // full: replace one at random
        return
    }
    fx.parts[fx.count] = p
    fx.count += 1
}

// Where an entity is drawn, in framebuffer pixels, `alpha` of a step after its last update.
fn screen_pos(e: *Entity, alpha: f32) -> vec2 { (e.pos + e.vel * (alpha / f32(HZ))) * f32(PX) }

// The look of a rock, from its handle: which of the kinds, how it is turned at birth and how
// fast it tumbles.
fn rock_look(h: Handle) -> (i64, f32, f32) {
    x := hash((h.idx, h.gen))
    kind := i64(x % u64(ROCK_KINDS))
    turn := f32((x >> 8) & 0xFFFF) / 65536.0 * TAU
    spin := (f32((x >> 24) & 0xFF) / 255.0 * 1.6 + 0.4) * (if (x >> 40) & 1 == 0 { 1.0 } else { -1.0 })
    (kind, turn, spin)
}

// Looks at the game after the steps of a frame and starts what they call for; dt is the game
// time the steps took. Call it before the game's events are cleared.
fn fx_update(fx: *Fx, g: *Game, dt: f32) {
    for ev in g.events {
        match ev.sfx {
            SfxShot => fx.muzzle = 1.0
            SfxHurt => {
                fx.shake = fmin(fx.shake + 0.55, 1.0)
                fx.hurt = 1.0
                fx.hp_lost = 0.0
            }
            SfxOver => {
                fx.shake = 1.0
                fx.white = 0.6
                ship_explosion(fx, fx.last_player)
            }
            _ => {}
        }
    }
    p := g.ents.get(g.player)
    if p != nil {
        fx.last_player = p.pos * f32(PX)
        fx.roll += (clamp(p.vel.x / 110.0, -1.0, 1.0) - fx.roll) * fmin(dt * 9.0, 1.0)
    }
    // compare every slot of the pool with what it held the previous frame
    for i in 0..g.ents.len {
        was := &fx.seen[i]
        live := g.ents.is_live(i)
        h := g.ents.handle_at(i)
        same := live && was.live && was.gen == h.gen
        if was.live && !same {
            gone(fx, i, was, dt)
        }
        if live {
            e := &g.ents.items[i]
            if same && e.kind == Rock && e.hp < was.hp {
                fx.hit[i] = 0.12
            }
            *was = Seen{live: true, gen: h.gen, kind: e.kind, pos: e.pos, vel: e.vel, radius: e.radius, hp: e.hp}
        } else {
            was.live = false
        }
    }
    if g.score != fx.last_score {
        fx.score_pulse = 1.0
        fx.last_score = g.score
    }
    if g.over {
        fx.over_time += dt
    }
    fx_step(fx, dt)
}

// An entity that was there the previous frame is gone.
priv fn gone(fx: *Fx, slot: i64, was: *Seen, dt: f32) {
    at := (was.pos + was.vel * dt) * f32(PX)     // where it would be now
    match was.kind {
        Rock => {
            if at.y < (f32(WORLD_H) + 10.0) * f32(PX) {    // (not gone off the bottom)
                kind, _, _ := rock_look(Handle{u32(slot), was.gen})
                rock_explosion(fx, at, was.radius * f32(PX), kind)
            }
        }
        Shot => {
            if at.y > 0.0 {                              // (not gone off the top): it hit a rock
                hit_sparks(fx, at)
            }
        }
        _ => {}
    }
}

// A ball of fire of radius r: a flash, a shock ring, billows of fire, smoke and embers. It
// starts `delay` seconds from now (a particle with a negative age waits).
fn blast(fx: *Fx, at: vec2, r: f32, delay: f32) {
    rnd := &fx.rng
    w := -delay
    spawn(fx, Particle{kind: Flash, pos: at, age: w, life: 0.18, size: r * 4.0, grow: 1.3, color: vec3(1.0, 0.85, 0.6)})
    spawn(fx, Particle{kind: Ring, pos: at, age: w, life: 0.4, size: r * 1.2, grow: 4.0, color: vec3(1.0, 0.6, 0.3)})
    for i in 0..10 {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Fire, pos: at + dir * rnd.range(0.0, r * 0.7), vel: dir * rnd.range(15.0, 70.0), age: w,
            life: rnd.range(0.3, 0.65), size: r * rnd.range(0.9, 1.9), grow: 1.9, angle: rnd.range(0.0, TAU),
            spin: rnd.range(-3.0, 3.0), look: rnd.range(0, 3)})
    }
    for i in 0..6 {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Smoke, pos: at + dir * rnd.range(0.0, r * 0.5), vel: dir * rnd.range(8.0, 30.0) + vec2(0.0, 25.0),
            age: w, life: rnd.range(0.8, 1.5), size: r * rnd.range(1.4, 2.2), grow: 1.6, angle: rnd.range(0.0, TAU),
            spin: rnd.range(-1.0, 1.0), look: rnd.range(0, 3)})
    }
    for i in 0..14 {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Ember, pos: at, vel: dir * rnd.range(60.0, 260.0), age: w, life: rnd.range(0.3, 0.8),
            size: rnd.range(2.5, 4.5), grow: 0.3, color: vec3(1.0, rnd.range(0.45, 0.8), 0.2)})
    }
}

fn rock_explosion(fx: *Fx, at: vec2, r: f32, kind: i64) {
    rnd := &fx.rng
    fx.shake = fmin(fx.shake + 0.08 + r * 0.006, 1.0)
    blast(fx, at, r, 0.0)
    // chips of the rock itself, lit like it
    for i in 0..i64(3.0 + r * 0.15) {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Debris, pos: at + dir * r * 0.4, vel: dir * rnd.range(40.0, 140.0), life: rnd.range(0.7, 1.3),
            size: r * rnd.range(0.22, 0.4), grow: 1.0, angle: rnd.range(0.0, TAU), spin: rnd.range(-8.0, 8.0), look: kind})
    }
    spawn(fx, Particle{kind: Pop, pos: at - vec2(0.0, r + 8.0), vel: vec2(0.0, -45.0), life: 1.0, look: 10})   // a rock is worth 10 (logic.al)
}

// The player's ship goes up: a large blast, smaller ones following it around the wreck for half
// a second, two shock rings, burning pieces of the hull and a shower of sparks.
fn ship_explosion(fx: *Fx, at: vec2) {
    rnd := &fx.rng
    spawn(fx, Particle{kind: Flash, pos: at, life: 0.35, size: 200.0, grow: 1.4, color: vec3(1.0, 0.85, 0.6)})
    spawn(fx, Particle{kind: Ring, pos: at, life: 0.7, size: 30.0, grow: 9.0, color: vec3(1.0, 0.8, 0.4)})
    spawn(fx, Particle{kind: Ring, pos: at, life: 1.0, size: 20.0, grow: 7.0, color: vec3(0.3, 0.7, 1.0)})
    blast(fx, at, 30.0, 0.0)
    for i in 0..5 {
        blast(fx, at + rnd.in_circle() * 40.0, rnd.range(12.0, 22.0), 0.12 + f32(i) * 0.11)
    }
    for i in 0..16 {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Shard, pos: at, vel: dir * rnd.range(50.0, 200.0), life: rnd.range(1.0, 2.0),
            size: rnd.range(0.8, 1.4), angle: rnd.range(0.0, TAU), spin: rnd.range(-10.0, 10.0), look: rnd.range(0, 4)})
    }
    for i in 0..40 {
        dir := rnd.unit_vec2()
        spawn(fx, Particle{kind: Ember, pos: at, vel: dir * rnd.range(80.0, 380.0), life: rnd.range(0.5, 1.4),
            size: rnd.range(3.0, 5.5), grow: 0.3, color: vec3(1.0, rnd.range(0.6, 0.95), 0.35)})
    }
}
fn hit_sparks(fx: *Fx, at: vec2) {
    rnd := &fx.rng
    spawn(fx, Particle{kind: Flash, pos: at, life: 0.1, size: 40.0, grow: 0.6, color: vec3(0.6, 0.9, 1.0)})
    for i in 0..6 {
        dir := normalize(rnd.unit_vec2() + vec2(0.0, 0.8))
        spawn(fx, Particle{kind: Ember, pos: at, vel: dir * rnd.range(80.0, 220.0), life: rnd.range(0.12, 0.3),
            size: rnd.range(2.0, 3.5), grow: 0.3, color: vec3(0.7, 0.95, 1.0)})
    }
}

// Moves everything on by dt seconds and drops what has burnt out.
fn fx_step(fx: *Fx, dt: f32) {
    fx.time += dt
    i := 0
    while i < fx.count {
        p := &fx.parts[i]
        p.age += dt
        if p.age >= p.life {
            fx.count -= 1
            fx.parts[i] = fx.parts[fx.count]
            continue
        }
        drag := match p.kind { Ember => 2.5; Smoke => 1.2; Fire => 2.0; Debris, Shard => 0.6; _ => 0.0 }
        if p.age > 0.0 {                         // (not still waiting to start)
            p.vel = p.vel * fmax(1.0 - drag * dt, 0.0)
            p.pos = p.pos + p.vel * dt
            p.angle += p.spin * dt
        }
        i += 1
    }
    for i in 0..fx.hit.len {
        fx.hit[i] = fmax(fx.hit[i] - dt, 0.0)
    }
    fx.shake = fmax(fx.shake - dt * 1.6, 0.0)
    fx.hurt = fmax(fx.hurt - dt * 3.0, 0.0)
    fx.white = fmax(fx.white - dt * 3.5, 0.0)
    fx.muzzle = fmax(fx.muzzle - dt * 14.0, 0.0)
    fx.score_pulse = fmax(fx.score_pulse - dt * 3.0, 0.0)
    fx.hp_lost += dt
}

// The camera offset of the shake, in pixels: smooth noise, scaled by the square of the trauma.
fn shake_offset(fx: *Fx) -> vec2 {
    k := fx.shake * fx.shake * 9.0
    vec2(noise2(fx.time * 28.0, 0.5, 61), noise2(fx.time * 28.0, 7.5, 62)) * (k * 1.6)
}

// Fire changes colour as it cools: white, yellow, orange, deep red.
fn fire_color(t: f32) -> vec3 {
    if t < 0.15 {
        lerp(vec3(1.0, 1.0, 0.9), vec3(1.0, 0.85, 0.4), t / 0.15)
    } else if t < 0.5 {
        lerp(vec3(1.0, 0.85, 0.4), vec3(1.0, 0.42, 0.12), (t - 0.15) / 0.35)
    } else {
        lerp(vec3(1.0, 0.42, 0.12), vec3(0.45, 0.06, 0.08), (t - 0.5) / 0.5)
    }
}

// The layers of particles, drawn at different depths: smoke under the rocks, debris over them,
// and everything that glows over all of it.
enum Layer { Back, Solid, Light }

fn layer_of(k: PKind) -> Layer {
    match k {
        Smoke => Back
        Debris, Shard => Solid
        _ => Light
    }
}

// Draws the particles of one layer, moved by `off` (the shake).
fn fx_draw(c: *Canvas, fx: *Fx, art: *Art, layer: Layer, off: vec2) {
    for i in 0..fx.count {
        p := &fx.parts[i]
        t := p.age / p.life
        size := p.size * lerp(1.0, p.grow, t)
        at := p.pos + off
        if layer_of(p.kind) != layer || p.age < 0.0 {
            continue
        }
        match p.kind {
            Smoke => {
                k := (1.0 - t) * (1.0 - t) * smoothstep(0.0, 0.08, t) * 0.55
                col := lerp(vec3(0.30, 0.16, 0.12), vec3(0.10, 0.08, 0.16), saturate(t * 2.0))
                m := art.smoke[p.look].level(size)
                mask_xf(c, &m, at.x, at.y, p.angle, size / f32(m.w), size / f32(m.w), Over, premul(vec4(col, k)))
            }
            Fire => {
                // billows of light: a smoke mask added in the colour of the cooling fire
                k := (1.0 - t) * smoothstep(0.0, 0.05, t) * 0.65
                m := art.smoke[p.look].level(size)
                mask_xf(c, &m, at.x, at.y, p.angle, size / f32(m.w), size / f32(m.w), Add, light(fire_color(t), k))
            }
            Flash => {
                k := (1.0 - t) * (1.0 - t) * 0.7
                mask_at(c, &art.glow, at.x, at.y, size, Add, light(p.color, k))
            }
            Ring => {
                k := (1.0 - t) * (1.0 - t) * 0.8
                mask_at(c, &art.ring, at.x, at.y, size, Add, light(p.color, k))
            }
            Ember => {
                // a short streak along its motion, hot at the head
                k := 1.0 - t
                speed := length(p.vel)
                m := art.glow.level(8.0)
                along := fmax(speed * 0.035, size) / f32(m.w)
                turn := atan2(-p.vel.x, p.vel.y)
                mask_xf(c, &m, at.x, at.y, turn, size / f32(m.w), along, Add, light(p.color, k))
            }
            Debris => {
                s := &art.rocks[(p.look * ROCK_SIZES.len) * ROCK_ANGLES]
                k := u32(saturate((1.0 - t) * 3.0) * 256.0)
                scale := size / ROCK_SIZES[0]
                blit_xf(c, s, at.x, at.y, p.angle, scale * 0.5, scale * 0.5, Over, k)
            }
            Shard => {
                k := u32(saturate((1.0 - t) * 3.0) * 256.0)
                blit_xf(c, &art.shards[p.look], at.x, at.y, p.angle, p.size, p.size, Over, k)
                mask_at(c, &art.glow, at.x, at.y, 10.0, Add, light(vec3(1.0, 0.6, 0.2), (1.0 - t) * 0.6))
            }
            Pop => {}
        }
    }
}
