// What the std.gfx starter shows beyond the game's own state: explosions, debris, smoke,
// shockwaves, hit sparks, muzzle flashes, shot trails, engine exhaust, screen shake, the damage
// flash, score pop-ups, the banking of the ship, and the scrolling starfield. None of it feeds
// back into the game: `fx_frame` reads the game once per displayed frame (the events of the
// steps since the last frame, before play_events forgets them, and the entities compared with
// the last frame) and advances the effects by the frame's time. Its random numbers come from its
// own generator, so the simulation never depends on what was drawn.
use std.gfx
use "../starter/logic.al"
use "art.al"

const MAX_PARTS = 2048
const MAX_POPS = 24
const STAR_COUNT = 190

struct Particle {
    src: vec4            // the atlas rectangle
    pos: vec2
    vel: vec2
    age: f32
    life: f32
    size0: f32           // size at birth and at the end (virtual pixels)
    size1: f32
    rot: f32
    spin: f32
    drag: f32            // share of the speed lost per second
    c0: vec4             // colour at birth and at the end, straight alpha
    c1: vec4
    add: bool            // light (additive) or matter (alpha blended)
    streak: f32          // > 0: drawn along its velocity, longer the faster it goes
}

struct Popup { pos: vec2, age: f32, value: i64 }
struct Star { pos: vec2, layer: i64, bright: f32, phase: f32, color: vec4 }

// An entity as the last frame saw it, by slot of the game's pool.
struct Seen { live: bool, gen: u32, kind: Kind, pos: vec2, vel: vec2, radius: f32 }

struct Fx {
    rng: Rng
    time: f32            // seconds of play shown (stands still while paused)
    parts: []Particle
    nparts: i64
    pops: []Popup
    npops: i64
    stars: []Star
    seen: []Seen
    nseen: i64
    step_no: i64         // the game's step at the last look (a new game starts lower)
    player: vec2         // the player as last seen
    player_vel: vec2
    bank: f32            // -1 hard left .. 1 hard right, eased
    exhaust: f32         // particles owed to the engines (fractional)
    trauma: f32          // screen shake 0..1, decays; the shake is its square
    flash: f32           // damage flash 0..1
    over_t: f32          // seconds since the game ended
    hit: []f32           // per slot: seconds left of a rock's white hit flash
    score: f32           // the score as shown: counts up to the game's
    bump: f32            // 1 when the score just rose, decays
}

fn fx_new(seed: u64) -> Fx {
    fx := Fx{rng: rng(seed)}
    fx.parts = alloc[Particle](MAX_PARTS)
    fx.pops = alloc[Popup](MAX_POPS)
    fx.seen = alloc[Seen](512)
    fx.hit = alloc[f32](512)
    fx.stars = alloc[Star](STAR_COUNT)
    tints := [4]vec4{vec4(0.75, 0.85, 1.0, 1.0), vec4(1.0, 1.0, 1.0, 1.0), vec4(1.0, 0.9, 0.75, 1.0), vec4(0.85, 0.8, 1.0, 1.0)}
    for i in 0..STAR_COUNT {
        layer := if i < 110 { 0 } else if i < 165 { 1 } else { 2 }
        fx.stars[i] = Star{
            pos: vec2(fx.rng.range(-20.0, f32(WORLD_W) + 20.0), fx.rng.range(0.0, f32(WORLD_H) + 10.0)),
            layer: layer, bright: fx.rng.range(0.35, 1.0), phase: fx.rng.range(0.0, 6.28),
            color: tints[fx.rng.range(0, 4)],
        }
    }
    fx
}

// ---- spawning -------------------------------------------------------------------------------

priv fn spawn(fx: *Fx, p: Particle) {
    if fx.nparts < MAX_PARTS {
        fx.parts[fx.nparts] = p
        fx.nparts += 1
    }
}

priv fn rgba(r: f32, g: f32, b: f32, a: f32) -> vec4 { vec4(r, g, b, a) }

priv fn light(fx: *Fx, src: vec4, at: vec2, vel: vec2, life: f32, s0: f32, s1: f32, c0: vec4, c1: vec4) {
    spawn(fx, Particle{src: src, pos: at, vel: vel, life: life, size0: s0, size1: s1, c0: c0, c1: c1, add: true})
}

// Sparks flying out of `at`: thin streaks, fast at first.
priv fn sparks(fx: *Fx, art: *Art, at: vec2, n: i64, speed: f32, c0: vec4, c1: vec4, dir: vec2, spread: f32) {
    for i in 0..n {
        d := if spread >= 3.0 { fx.rng.unit_vec2() } else { rotate(dir, fx.rng.range(-spread, spread)) }
        spawn(fx, Particle{src: art.streak, pos: at, vel: d * speed * fx.rng.range(0.4, 1.0),
            life: fx.rng.range(0.18, 0.5), size0: 1.3, size1: 0.6, drag: 3.0, c0: c0, c1: c1,
            add: true, streak: 0.035})
    }
}

// An explosion of size r (a rock's radius), `delay` seconds from now: a white-hot core, billows
// of fire, a halo, a shockwave ring, embers, tumbling debris and the smoke that stays.
priv fn explode(fx: *Fx, art: *Art, at: vec2, vel: vec2, r: f32, debris: vec4, delay: f32) {
    first := fx.nparts
    drift := vel * 0.3
    light(fx, art.core, at, drift, 0.16, r * 3.2, r * 1.5, rgba(1.0, 0.98, 0.9, 1.0), rgba(1.0, 0.7, 0.3, 0.0))
    light(fx, art.glow, at, drift, 0.45, r * 5.0, r * 7.0, rgba(1.0, 0.55, 0.2, 0.35), rgba(0.8, 0.2, 0.05, 0.0))
    light(fx, art.ring, at, drift, 0.38, r * 1.5, r * 8.0, rgba(1.0, 0.8, 0.55, 0.55), rgba(1.0, 0.35, 0.15, 0.0))
    for i in 0..9 {
        v := drift + fx.rng.in_circle() * r * 4.5
        s := r * fx.rng.range(1.2, 2.0)
        spawn(fx, Particle{src: art.smoke[fx.rng.range(0, SMOKES)], pos: at + fx.rng.in_circle() * r * 0.5, vel: v,
            life: fx.rng.range(0.3, 0.6), size0: s, size1: s * 2.0, rot: fx.rng.range(0.0, 6.28),
            spin: fx.rng.range(-2.5, 2.5), drag: 2.0, c0: rgba(1.0, 0.62, 0.28, 0.42), c1: rgba(0.6, 0.10, 0.03, 0.0), add: true})
    }
    for i in 0..6 {
        v := drift + fx.rng.in_circle() * r * 2.5
        spawn(fx, Particle{src: art.smoke[fx.rng.range(0, SMOKES)], pos: at + fx.rng.in_circle() * r * 0.5, vel: v,
            life: fx.rng.range(1.0, 1.8), size0: r * 1.6, size1: r * 4.2, rot: fx.rng.range(0.0, 6.28),
            spin: fx.rng.range(-0.8, 0.8), drag: 1.2, c0: rgba(0.30, 0.22, 0.22, 0.6), c1: rgba(0.08, 0.08, 0.14, 0.0)})
    }
    for i in 0..i64(r * 0.9) + 3 {
        v := drift + fx.rng.unit_vec2() * fx.rng.range(25.0, 70.0)
        s := r * fx.rng.range(0.35, 0.7)
        spawn(fx, Particle{src: art.chunk[fx.rng.range(0, CHUNKS)], pos: at, vel: v, life: fx.rng.range(0.7, 1.3),
            size0: s, size1: s * 0.8, rot: fx.rng.range(0.0, 6.28), spin: fx.rng.range(-9.0, 9.0), drag: 0.6,
            c0: debris, c1: vec4(debris.xyz * 0.5, 0.0)})
    }
    sparks(fx, art, at, 14, 150.0, rgba(1.0, 0.85, 0.5, 1.0), rgba(1.0, 0.3, 0.1, 0.0), vec2(0.0), 4.0)
    for i in first..fx.nparts {
        fx.parts[i].age = -delay
    }
}

// Finds the rock an event at x is about: the closest by x among those seen last frame (`gone`:
// only those that are gone now) and those alive now. -1 if there is none.
priv fn rock_near(fx: *Fx, game: *Game, x: f32, gone: bool) -> (vec2, vec2, f32, i64) {
    best := -1
    bd: f32 = 6.0
    at := vec2(0.0)
    vel := vec2(0.0)
    radius: f32 = 0.0
    for i in 0..fx.nseen {
        s := &fx.seen[i]
        if !s.live || s.kind != Rock {
            continue
        }
        now := i < game.ents.used && game.ents.is_live(i) && game.ents.gens[i] == s.gen
        if gone && now {
            continue
        }
        p := if now { game.ents.items[i].pos } else { s.pos + s.vel * (1.0 / 60.0) }
        d := fabs(p.x - x)
        if d < bd {
            bd = d
            best = i
            at = p
            vel = s.vel
            radius = s.radius
        }
    }
    (at, vel, radius, best)
}

// ---- the frame ------------------------------------------------------------------------------

// Reads what happened in the game since the last frame and advances every effect by dt
// seconds (0 while paused). Call before play_events, which empties game.events.
fn fx_frame(fx: *Fx, art: *Art, game: *Game, dt: f32) {
    if game.step_no < fx.step_no {                 // a new game
        fx.nseen = 0
        fx.over_t = 0.0
        fx.score = 0.0
        fx.npops = 0
    }
    fx.step_no = game.step_no
    p := game.ents.get(game.player)
    for e in game.events {
        match e.sfx {
            SfxShot => {
                if p != nil {
                    light(fx, art.glow, p.pos + vec2(0.0, -7.0), p.vel, 0.07, 9.0, 5.0, rgba(0.5, 0.9, 1.0, 0.8), rgba(0.2, 0.6, 1.0, 0.0))
                }
            }
            SfxHit => {
                at, vel, r, slot := rock_near(fx, game, e.x, false)
                if slot >= 0 {
                    hit := at + vec2(0.0, r * 0.8)
                    fx.hit[slot] = 0.1
                    light(fx, art.glow, hit, vel, 0.12, 10.0, 4.0, rgba(0.7, 0.95, 1.0, 0.9), rgba(0.3, 0.7, 1.0, 0.0))
                    sparks(fx, art, hit, 7, 110.0, rgba(0.8, 1.0, 1.0, 1.0), rgba(0.2, 0.6, 1.0, 0.0), vec2(0.0, 1.0), 1.0)
                    fx.trauma = fmin(fx.trauma + 0.06, 1.0)
                }
            }
            SfxBreak => {
                at, vel, r, slot := rock_near(fx, game, e.x, true)
                if slot >= 0 {
                    explode(fx, art, at, vel, r, rgba(0.85, 0.78, 0.72, 1.0), 0.0)
                    fx.trauma = fmin(fx.trauma + 0.12 + r * 0.02, 1.0)
                    if fx.npops < MAX_POPS {
                        fx.pops[fx.npops] = Popup{pos: at, value: 10}
                        fx.npops += 1
                    }
                }
            }
            SfxHurt => {
                at := if p != nil { p.pos } else { fx.player }
                fx.flash = 1.0
                fx.trauma = fmin(fx.trauma + 0.55, 1.0)
                light(fx, art.ring, at, vec2(0.0), 0.35, 6.0, 40.0, rgba(1.0, 0.4, 0.3, 0.8), rgba(1.0, 0.2, 0.1, 0.0))
                sparks(fx, art, at, 20, 140.0, rgba(1.0, 0.9, 0.6, 1.0), rgba(1.0, 0.3, 0.1, 0.0), vec2(0.0), 4.0)
            }
            SfxOver => {
                at := fx.player
                // the ship goes up in a chain of blasts, with a wide blue shockwave
                explode(fx, art, at, fx.player_vel, 6.0, rgba(0.8, 0.85, 0.95, 1.0), 0.0)
                for k in 0..4 {
                    explode(fx, art, at + fx.rng.in_circle() * 16.0, vec2(0.0), fx.rng.range(3.5, 6.0), rgba(0.8, 0.85, 0.95, 1.0), 0.15 + f32(k) * 0.16)
                }
                light(fx, art.ring, at, vec2(0.0), 0.9, 8.0, 170.0, rgba(0.6, 0.9, 1.0, 0.6), rgba(0.2, 0.5, 1.0, 0.0))
                light(fx, art.glow, at, vec2(0.0), 0.7, 50.0, 90.0, rgba(0.4, 0.7, 1.0, 0.18), rgba(0.2, 0.3, 1.0, 0.0))
                sparks(fx, art, at, 40, 220.0, rgba(0.8, 1.0, 1.0, 1.0), rgba(0.2, 0.6, 1.0, 0.0), vec2(0.0), 4.0)
                fx.trauma = 1.0
                fx.flash = 1.0
            }
        }
    }
    if p != nil {
        fx.player = p.pos
        fx.player_vel = p.vel
    }
    if game.over {
        fx.over_t += dt
    }
    // the ship banks into its turns
    target := if p != nil { clamp(p.vel.x / 110.0, -1.0, 1.0) } else { 0.0 }
    fx.bank += (target - fx.bank) * saturate(dt * 10.0)
    if p != nil && dt > 0.0 {
        engines(fx, art, p, dt)
    }
    // trails behind the shots (the slots the game itself moves: 0..len)
    for i in 0..game.ents.len {
        if dt > 0.0 && game.ents.is_live(i) && game.ents.items[i].kind == Shot && fx.rng.chance(0.7) {
            e := &game.ents.items[i]
            light(fx, art.core, e.pos + vec2(fx.rng.range(-0.4, 0.4), 3.0), vec2(0.0, 12.0), 0.16, 2.2, 0.6,
                rgba(0.4, 0.85, 1.0, 0.7), rgba(0.1, 0.3, 1.0, 0.0))
        }
    }
    // the shown score counts up to the game's
    if f32(game.score) > fx.score {
        fx.score = fmin(f32(game.score), fx.score + fmax(dt * 40.0, (f32(game.score) - fx.score) * saturate(dt * 6.0)))
        fx.bump = 1.0
    } else {
        fx.score = f32(game.score)
    }
    step(fx, dt)
    // what the game looks like now, for the next frame
    fx.nseen = game.ents.used
    for i in 0..game.ents.used {
        e := &game.ents.items[i]
        fx.seen[i] = Seen{live: game.ents.is_live(i) && i < game.ents.len, gen: game.ents.gens[i], kind: e.kind,
            pos: e.pos, vel: e.vel, radius: e.radius}
    }
}

// Exhaust from the two engines, more of it when the ship climbs.
priv fn engines(fx: *Fx, art: *Art, p: *Entity, dt: f32) {
    thrust := 1.0 - p.vel.y / 110.0 * 0.5
    fx.exhaust += dt * 90.0 * thrust
    while fx.exhaust >= 1.0 {
        fx.exhaust -= 1.0
        side := if fx.rng.chance(0.5) { -1.0 } else { 1.0 }
        at := p.pos + vec2(side * 2.6 * (1.0 - 0.3 * fabs(fx.bank)) - fx.bank * 0.5, 6.6)
        v := vec2(fx.rng.range(-6.0, 6.0), fx.rng.range(45.0, 75.0) * thrust) + p.vel * 0.15
        light(fx, art.core, at, v, fx.rng.range(0.14, 0.26), 2.8, 0.8, rgba(0.55, 0.9, 1.0, 0.8), rgba(0.15, 0.25, 1.0, 0.0))
    }
}

priv fn step(fx: *Fx, dt: f32) {
    if dt <= 0.0 {
        return
    }
    fx.time += dt
    i := 0
    while i < fx.nparts {
        q := &fx.parts[i]
        q.age += dt
        if q.age < 0.0 {
            i += 1
            continue
        }
        if q.age >= q.life {
            fx.nparts -= 1
            fx.parts[i] = fx.parts[fx.nparts]
            continue
        }
        q.vel = q.vel * fmax(1.0 - q.drag * dt, 0.0)
        q.pos = q.pos + q.vel * dt
        q.rot += q.spin * dt
        i += 1
    }
    i = 0
    while i < fx.npops {
        fx.pops[i].age += dt
        if fx.pops[i].age >= 0.9 {
            fx.npops -= 1
            fx.pops[i] = fx.pops[fx.npops]
            continue
        }
        i += 1
    }
    for k in 0..len(fx.hit) {
        fx.hit[k] = fmax(fx.hit[k] - dt, 0.0)
    }
    fx.trauma = fmax(fx.trauma - dt * 1.4, 0.0)
    fx.flash = fmax(fx.flash - dt * 2.5, 0.0)
    fx.bump = fmax(fx.bump - dt * 4.0, 0.0)
}

// The screen shake as a transform of virtual pixels: a jolt that follows smooth noise.
fn fx_shake(fx: *Fx) -> Xform {
    s := fx.trauma * fx.trauma
    t := fx.time * 23.0
    off := vec2(noise2(t, 0.5, 3), noise2(0.5, t, 4)) * s * 5.0
    ang := noise2(t, t, 5) * s * 0.025
    c := vec2(f32(WORLD_W), f32(WORLD_H)) * 0.5
    xform_mul(xform_translate(c + off), xform_mul(xform_rotate(ang), xform_translate(-c)))
}

// ---- drawing ----------------------------------------------------------------------------------

priv fn col(v: vec4) -> u32 { color_u32(v) }

// The particles of one kind: matter (alpha blended) or light (additive).
fn draw_particles(g: *Gfx, art: *Art, fx: *Fx, add: bool) {
    for i in 0..fx.nparts {
        q := &fx.parts[i]
        if q.add != add || q.age < 0.0 {
            continue
        }
        t := q.age / q.life
        s := lerp(q.size0, q.size1, ease_out_quad(t))
        c := lerp(q.c0, q.c1, t)
        if q.streak > 0.0 {
            sp := length(q.vel)
            size := vec2(s * 2.0 + sp * q.streak, s)
            g.sprite(art.tex, q.src, q.pos, size, atan2(q.vel.y, q.vel.x), vec2(size.x * 0.8, size.y * 0.5), col(c))
        } else {
            g.sprite(art.tex, q.src, q.pos, vec2(s), q.rot, vec2(s * 0.5), col(c))
        }
    }
}

// Nebula, distant planet and three layers of stars, all scrolling down at their own speed and
// swaying against the player's sideways position.
fn draw_backdrop(g: *Gfx, art: *Art, fx: *Fx) {
    sway := (fx.player.x - f32(WORLD_W) * 0.5) / f32(WORLD_W)
    // the nebula: one tile scrolled down and repeated, then a larger mirrored copy over it as light
    size: f32 = 340.0
    y := fmod(fx.time * 2.5, size)
    x := -10.0 - sway * 8.0
    tile := vec4(art.nebula.x + 1.0, art.nebula.y + 1.0, art.nebula.z - 2.0, art.nebula.w - 2.0)   // not the edge texels
    g.sprite(art.tex, tile, vec4(x, y - size, size, size), 0xFFFFFFFF)
    g.sprite(art.tex, tile, vec4(x, y, size, size), 0xFFFFFFFF)
    g.set_blend(BlendAdd)
    big: f32 = 460.0
    y2 := fmod(fx.time * 6.0 + 120.0, big)
    mirrored := vec4(tile.x + tile.z, tile.y, -tile.z, tile.w)
    x2 := -70.0 - sway * 16.0
    g.sprite(art.tex, mirrored, vec4(x2, y2 - big, big, big), 0x48FFD070)   // teal, faint
    g.sprite(art.tex, mirrored, vec4(x2, y2, big, big), 0x48FFD070)
    // far stars before the planet, nearer ones after it
    stars(g, art, fx, 0, sway)
    g.set_blend(BlendAlpha)
    py := fmod(fx.time * 1.2 + 80.0, 330.0) - 60.0
    g.sprite(art.tex, art.planet, vec4(238.0 - sway * 12.0, py - 34.0, 68.0, 68.0), 0xFFC3B4B9)
    g.set_blend(BlendAdd)
    stars(g, art, fx, 1, sway)
    stars(g, art, fx, 2, sway)
    g.set_blend(BlendAlpha)
}

priv fn stars(g: *Gfx, art: *Art, fx: *Fx, layer: i64, sway: f32) {
    speed := [3]f32{5.0, 12.0, 30.0}[layer]
    size := [3]f32{1.6, 2.4, 3.2}[layer]
    shift := [3]f32{6.0, 14.0, 26.0}[layer]
    h := f32(WORLD_H) + 10.0
    for i in 0..STAR_COUNT {
        s := &fx.stars[i]
        if s.layer != layer {
            continue
        }
        p := vec2(s.pos.x - sway * shift, fmod(s.pos.y + fx.time * speed, h) - 5.0)
        tw := 0.7 + 0.3 * sin(fx.time * (1.5 + s.phase) + s.phase * 3.0)
        c := s.color
        c.w = s.bright * tw * (0.45 + 0.25 * f32(layer))
        if layer == 2 && s.bright > 0.8 {
            g.sprite(art.tex, art.flare, p, vec2(9.0), 0.0, vec2(4.5), col(c))
        } else if layer == 2 {
            // the nearest dust passes fast enough to smear
            c.w = c.w * 0.6
            g.sprite(art.tex, art.streak, p, vec2(7.0, 1.6), 1.5708, vec2(5.6, 0.8), col(c))
        } else {
            g.sprite(art.tex, art.star, p, vec2(size), 0.0, vec2(size * 0.5), col(c))
        }
    }
}
