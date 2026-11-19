// What the starter shows beyond its rules: explosions, debris, smoke, hit sparks, engine
// exhaust, screen shake, the damage flash, score pop-ups, the starfield. All of it lives in
// `Fx`, outside `Game`, and is stepped with the frame time; it only reads the game and never
// feeds back into it (the checksums of the headless run do not know it exists).
//
// The game reports no positions with its events, so fx_update finds out what happened by
// comparing each slot of the entity pool with what it held one frame earlier: a rock that
// vanished above the bottom edge exploded, a rock whose hit points dropped was hit, a shot
// that vanished on screen hit something, a shot that appeared was fired, the player lost a
// hit point or was destroyed. Pure AL: no window or GPU.
use "../starter/logic.al"

const MAX_PARTS = 2500
const MAX_POPUPS = 16
const STAR_LAYERS = 3

enum Look { LookGlow, LookFire, LookStreak, LookSmoke, LookDebris, LookRing }

// A particle; colours are premultiplied and may exceed 1, alpha is how much it covers (0: it
// only adds light). Colour and size go from their first to their second value over its life.
struct Particle {
    look: Look
    variant: i64
    pos: vec2
    vel: vec2
    drag: f32                     // velocity lost per second (exponential)
    angle: f32
    spin: f32
    age: f32
    life: f32
    size0: f32
    size1: f32
    c0: vec4
    c1: vec4
}

struct Popup { pos: vec2, age: f32, value: i64 }

// What a slot of the entity pool held in the last frame.
struct Seen { h: Handle, kind: Kind, pos: vec2, vel: vec2, radius: f32, hp: i32, life: f32 }

struct Star { pos: vec2, layer: i64, size: f32, bright: f32, phase: f32, tint: vec3 }

struct Fx {
    parts: []Particle
    n: i64
    popups: [MAX_POPUPS]Popup
    seen: []Seen
    hit: []f32                    // per slot: the white flash of a rock just hit, 1 .. 0
    rng: Rng
    time: f64                     // seconds of shown (not paused) play
    shake: f32                    // trauma 0..1: the shake is its square
    flash: f32                    // the damage flash 1 .. 0
    hurt: f32                     // the ship's white flash 1 .. 0
    muzzle: f32                   // the flash at the nose 1 .. 0
    bank: f32                     // -1 .. 1, eased towards the player's sideways speed
    thrust: f32                   // 0 .. 1, more when flying up
    score: f32                    // the score as shown: counts up
    pulse: f32                    // 1 .. 0 after the score rose
    over_time: f32                // seconds since the game ended
    emit: f32                     // exhaust particles owed (fractions carry over)
    stars: []Star
}

// The effects of a fresh game (fx_reset after each game_new).
fn fx_new(g: *Game) -> Fx {
    fx: Fx
    fx.parts = alloc[Particle](MAX_PARTS)
    fx.seen = alloc[Seen](len(g.ents.items))
    fx.hit = alloc[f32](len(g.ents.items))
    fx.rng = rng(2024)
    fx.stars = alloc[Star](160)
    tints := [3]vec3{vec3(0.70, 0.82, 1.0), vec3(1.0, 1.0, 1.0), vec3(1.0, 0.86, 0.70)}
    sizes := [STAR_LAYERS]f32{1.6, 2.4, 3.6}
    brights := [STAR_LAYERS]f32{0.30, 0.55, 1.0}
    for i in 0..len(fx.stars) {
        layer := if i < 90 { 0 } else if i < 140 { 1 } else { 2 }
        fx.stars[i] = Star{
            pos: vec2(fx.rng.range(0.0, f32(WORLD_W)), fx.rng.range(0.0, f32(WORLD_H))), layer: layer,
            size: sizes[layer] * fx.rng.range(0.7, 1.3), bright: brights[layer] * fx.rng.range(0.5, 1.2),
            phase: fx.rng.range(0.0, 6.3), tint: tints[fx.rng.range(0, 3)],
        }
    }
    fx_reset(&fx, g)
    fx
}

// Forgets the last game: particles go, the pool is taken as it is without effects.
fn fx_reset(fx: *Fx, g: *Game) {
    fx.n = 0
    for i in 0..MAX_POPUPS {
        fx.popups[i].age = 99.0
    }
    for i in 0..len(fx.seen) {
        fx.seen[i] = Seen{}
        fx.hit[i] = 0.0
    }
    look(fx, g)
    fx.shake = 0.0
    fx.flash = 0.0
    fx.hurt = 0.0
    fx.score = f32(g.score)
    fx.over_time = 0.0
}

// The parallax speeds of the star layers, virtual pixels per second.
const STAR_SPEED = [STAR_LAYERS]f32{5.0, 12.0, 26.0}

// ---- spawning --------------------------------------------------------------------------------

fn spawn(fx: *Fx, p: Particle) {
    if fx.n < MAX_PARTS {
        fx.parts[fx.n] = p
        fx.n += 1
    }
}

priv fn rnd(fx: *Fx, lo: f32, hi: f32) -> f32 { fx.rng.range(lo, hi) }

priv fn add_rgb(rgb: vec3, k: f32) -> vec4 { vec4(rgb * k, 0.0) }

priv fn popup(fx: *Fx, at: vec2, value: i64) {
    oldest := 0
    for i in 0..MAX_POPUPS {
        if fx.popups[i].age > fx.popups[oldest].age {
            oldest = i
        }
    }
    fx.popups[oldest] = Popup{at, 0.0, value}
}

// A fireball with everything that flies out of it; `r` is the radius of what blew up.
fn explode(fx: *Fx, at: vec2, drift: vec2, r: f32, hot: vec3) {
    fx.shake = fmin(fx.shake + 0.10 + r * 0.025, 1.0)
    spawn(fx, Particle{look: LookGlow, pos: at, vel: drift * 0.3, life: 0.16, size0: r * 2.5, size1: r * 6.0,
        c0: add_rgb(vec3(1.0, 0.85, 0.65), 1.5), c1: add_rgb(hot, 0.0)})
    spawn(fx, Particle{look: LookRing, pos: at, vel: drift * 0.3, life: 0.45, size0: r * 1.5, size1: r * 7.5,
        c0: add_rgb(vec3(1.0, 0.7, 0.45), 1.4), c1: add_rgb(hot, 0.0)})
    for k in 0..7 {
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookFire, variant: k % 2, pos: at + d * r * rnd(fx, 0.0, 0.6), vel: drift * 0.4 + d * rnd(fx, 8.0, 40.0),
            drag: 3.0, angle: rnd(fx, 0.0, 6.3), spin: rnd(fx, -3.0, 3.0), life: rnd(fx, 0.35, 0.75),
            size0: r * rnd(fx, 1.2, 2.0), size1: r * rnd(fx, 2.8, 4.0),
            c0: add_rgb(vec3(1.0, 0.55, 0.2), 1.25), c1: add_rgb(vec3(0.6, 0.1, 0.04), 0.0)})
    }
    for k in 0..16 {
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookStreak, pos: at + d * r * 0.5, vel: drift * 0.5 + d * rnd(fx, 60.0, 170.0), drag: 2.5,
            life: rnd(fx, 0.25, 0.6), size0: rnd(fx, 5.0, 9.0), size1: 1.5,
            c0: add_rgb(vec3(1.0, 0.82, 0.45), 3.0), c1: add_rgb(hot, 0.0)})
    }
    for k in 0..6 {
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookDebris, variant: fx.rng.range(0, 4), pos: at + d * r * 0.4, vel: drift * 0.6 + d * rnd(fx, 14.0, 55.0),
            drag: 0.6, angle: rnd(fx, 0.0, 6.3), spin: rnd(fx, -9.0, 9.0), life: rnd(fx, 0.9, 1.6),
            size0: r * rnd(fx, 0.45, 0.85), size1: r * 0.3, c0: vec4(1.0), c1: vec4(0.0)})
    }
    for k in 0..6 {
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookSmoke, variant: fx.rng.range(0, 2), pos: at + d * r * 0.5, vel: drift * 0.3 + d * rnd(fx, 4.0, 18.0),
            drag: 1.0, angle: rnd(fx, 0.0, 6.3), spin: rnd(fx, -1.0, 1.0), life: rnd(fx, 0.9, 1.6),
            size0: r * 1.6, size1: r * 4.2, c0: vec4(0.10, 0.08, 0.12, 0.6), c1: vec4(0.0)})
    }
}

// A shot struck at `at`: sparks spray back down the way it came, a small flash.
fn impact(fx: *Fx, at: vec2) {
    spawn(fx, Particle{look: LookGlow, pos: at, life: 0.12, size0: 7.0, size1: 14.0,
        c0: add_rgb(vec3(0.6, 0.9, 1.0), 2.5), c1: add_rgb(vec3(0.2, 0.5, 1.0), 0.0)})
    for k in 0..8 {
        a := rnd(fx, 0.35, 2.8)
        d := vec2(cos(a), sin(a))                  // downwards: back where the shot came from
        spawn(fx, Particle{look: LookStreak, pos: at, vel: d * rnd(fx, 40.0, 130.0), drag: 4.0, life: rnd(fx, 0.12, 0.3),
            size0: rnd(fx, 3.0, 6.0), size1: 1.0, c0: add_rgb(vec3(0.7, 0.95, 1.0), 3.0), c1: add_rgb(vec3(0.2, 0.4, 1.0), 0.0)})
    }
}

priv fn hurt(fx: *Fx, at: vec2) {
    fx.flash = 1.0
    fx.hurt = 1.0
    fx.shake = fmin(fx.shake + 0.55, 1.0)
    for k in 0..12 {
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookStreak, pos: at, vel: d * rnd(fx, 50.0, 150.0), drag: 3.0, life: rnd(fx, 0.2, 0.5),
            size0: rnd(fx, 4.0, 8.0), size1: 1.0, c0: add_rgb(vec3(1.0, 0.8, 0.4), 2.0), c1: add_rgb(vec3(1.0, 0.3, 0.1), 0.0)})
    }
}

// ---- noticing what happened ------------------------------------------------------------------

priv fn removed(fx: *Fx, s: *Seen) {
    match s.kind {
        Rock => {
            if s.pos.y < f32(WORLD_H) + 6.0 {
                explode(fx, s.pos, s.vel, s.radius, vec3(0.8, 0.2, 0.05))
                popup(fx, s.pos, 10)
            }
        }
        Shot => {
            if s.pos.y > 0.0 && s.life > 0.02 {
                impact(fx, s.pos + vec2(0.0, -2.0))
            }
        }
        Player => {
            explode(fx, s.pos, vec2(0.0), 9.0, vec3(1.0, 0.5, 0.1))
            explode(fx, s.pos + vec2(4.0, -3.0), vec2(0.0), 6.0, vec3(1.0, 0.4, 0.1))
            fx.shake = 1.0
            fx.flash = 1.0
        }
        Spark => {}
    }
}

// Compares the pool with the last frame and starts the effects of the differences.
priv fn look(fx: *Fx, g: *Game) {
    for i in 0..len(fx.seen) {
        live := i < g.ents.used && g.ents.is_live(i)
        s := &fx.seen[i]
        h := if live { g.ents.handle_at(i) } else { Handle{} }
        if s.h != (Handle{}) && s.h != h {
            removed(fx, s)
            fx.hit[i] = 0.0
        }
        if !live {
            s.h = Handle{}
            continue
        }
        e := &g.ents.items[i]
        if s.h == h && e.hp < s.hp {
            if e.kind == Rock {
                fx.hit[i] = 1.0
            } else if e.kind == Player {
                hurt(fx, e.pos)
            }
        }
        if s.h != h && e.kind == Shot {
            fx.muzzle = 1.0
        }
        *s = Seen{h, e.kind, e.pos, e.vel, e.radius, e.hp, e.life}
    }
}

// ---- stepping --------------------------------------------------------------------------------

// One frame of effects, `dt` seconds after the last (0 while paused).
fn fx_update(fx: *Fx, g: *Game, dt: f32) {
    if dt <= 0.0 {
        return
    }
    fx.time += f64(dt)
    look(fx, g)
    fx.shake = fmax(fx.shake - dt * 1.3, 0.0)
    fx.flash = fmax(fx.flash - dt * 2.8, 0.0)
    fx.hurt = fmax(fx.hurt - dt * 3.0, 0.0)
    fx.muzzle = fmax(fx.muzzle - dt * 14.0, 0.0)
    for i in 0..len(fx.hit) {
        fx.hit[i] = fmax(fx.hit[i] - dt * 7.0, 0.0)
    }
    if g.over {
        fx.over_time += dt
    }
    // the score counts up to the real one
    target := f32(g.score)
    if target > fx.score + 0.5 && fx.pulse < 0.5 {
        fx.pulse = 1.0
    }
    fx.score += (target - fx.score) * fmin(dt * 7.0, 1.0)
    if fabs(target - fx.score) < 0.5 {
        fx.score = target
    }
    fx.pulse = fmax(fx.pulse - dt * 3.0, 0.0)

    p := g.ents.get(g.player)
    if p != nil {
        fx.bank += (clamp(p.vel.x / 110.0, -1.0, 1.0) - fx.bank) * fmin(dt * 9.0, 1.0)
        fx.thrust += (clamp(0.45 - p.vel.y / 110.0 * 0.55, 0.0, 1.0) - fx.thrust) * fmin(dt * 6.0, 1.0)
        // exhaust from both nozzles
        fx.emit += dt * (90.0 + 80.0 * fx.thrust)
        while fx.emit >= 1.0 {
            fx.emit -= 1.0
            side := if fx.rng.chance(0.5) { -1.0 } else { 1.0 }
            at := p.pos + vec2(side * 3.2 * (1.0 - 0.17 * fabs(fx.bank)), 8.2) + vec2(rnd(fx, -0.4, 0.4), 0.0)
            spawn(fx, Particle{look: LookStreak, pos: at, vel: vec2(rnd(fx, -2.5, 2.5), rnd(fx, 55.0, 85.0)), drag: 1.5,
                life: rnd(fx, 0.1, 0.22), size0: rnd(fx, 4.0, 6.0), size1: 2.0,
                c0: add_rgb(vec3(0.45, 0.75, 1.0), 1.0), c1: add_rgb(vec3(0.55, 0.2, 1.0), 0.0)})
        }
    }
    // damaged rocks smoulder
    for i in 0..g.ents.used {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock || g.ents.items[i].hp >= 2 || !fx.rng.chance(dt * 14.0) {
            continue
        }
        e := &g.ents.items[i]
        d := fx.rng.unit_vec2()
        spawn(fx, Particle{look: LookGlow, pos: e.pos + d * e.radius * 0.7, vel: e.vel + d * rnd(fx, 4.0, 12.0) + vec2(0.0, -10.0),
            drag: 1.0, life: rnd(fx, 0.3, 0.6), size0: rnd(fx, 2.0, 3.0), size1: 0.5,
            c0: add_rgb(vec3(1.0, 0.5, 0.15), 2.2), c1: add_rgb(vec3(0.8, 0.1, 0.0), 0.0)})
        if fx.rng.chance(0.4) {
            spawn(fx, Particle{look: LookSmoke, variant: fx.rng.range(0, 2), pos: e.pos + d * e.radius * 0.5, vel: e.vel * 0.8 + vec2(0.0, -8.0),
                drag: 0.5, angle: rnd(fx, 0.0, 6.3), spin: rnd(fx, -1.0, 1.0), life: rnd(fx, 0.6, 1.0),
                size0: e.radius * 0.8, size1: e.radius * 2.2, c0: vec4(0.09, 0.07, 0.08, 0.45), c1: vec4(0.0)})
        }
    }
    // move and age the particles; the dead ones are replaced by the last
    k := 0
    while k < fx.n {
        q := &fx.parts[k]
        q.age += dt
        if q.age >= q.life {
            fx.n -= 1
            fx.parts[k] = fx.parts[fx.n]
            continue
        }
        q.pos = q.pos + q.vel * dt
        q.vel = q.vel * exp(-q.drag * dt)
        q.angle += q.spin * dt
        k += 1
    }
    for i in 0..MAX_POPUPS {
        fx.popups[i].age += dt
    }
}

// The offset of the shaking screen in virtual pixels.
fn shake_offset(fx: *Fx) -> vec2 {
    t := f32(fmod(fx.time, 1000.0)) * 31.0
    s := fx.shake * fx.shake * 5.0
    vec2(noise2(t, 0.5, 3), noise2(0.5, t, 4)) * s
}
