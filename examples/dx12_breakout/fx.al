// What the breakout shows on top of the game: shards and sparks when bricks break, a trail
// behind the ball, flashes, screen shake, score pop-ups, a ripple in the background, the
// level-clear fireworks, and the animation of the menus. Pure AL.
//
// This is the renderer's own state, not the game's: it is made from the game's events (the
// list sound.al plays, read before it is cleared) and from the game's state, stepped with the
// time of a displayed frame, and nothing in it ever goes back into the game. Its random
// numbers come from its own generator, so the game's checksums do not see it.
use "logic.al"
use "sheet.al"

const MAX_PARTS = 900
const MAX_POPUPS = 24
const TRAIL_LEN = 24

enum PartKind { Shard, Spark, Puff, Ring, Flare }

struct Part {
    kind: PartKind
    pos: vec2
    vel: vec2
    age: f32
    life: f32
    size: f32
    angle: f32
    spin: f32
    drag: f32            // velocity lost per second (a fraction)
    gravity: f32
    color: vec3
    shard: i64           // which shard tile
}

// "+60" rising from a broken brick.
struct Popup { pos: vec2, age: f32, value: i64, color: vec3 }

struct Fx {
    time: f64                    // seconds of animation (it runs on in the menus)
    rng: Rng
    parts: [MAX_PARTS]Part
    n_parts: i64
    popups: [MAX_POPUPS]Popup
    n_popups: i64
    trail: [TRAIL_LEN]vec2       // where the ball was drawn, the newest last
    n_trail: i64
    shake: f32                   // how hard the picture shakes (decays)
    shake_off: vec2              // this frame's offset of the playfield, view pixels
    paddle_flash: f32            // 1 when the ball hits the paddle, fading
    paddle_hit: f32              // where, x
    brick_flash: [ROWS * COLS]f32
    wall_flash: f32
    wall_hit: vec2
    lost_flash: f32              // a red flash when a ball is lost
    clear_flash: f32             // a white flash when a wall is cleared
    clear_age: f32               // seconds since the last wall was cleared
    ripple: vec3                 // where the background ripples from, and its age
    score_shown: f32             // the score in the display, counting up to the real one
    menu_pos: f32                // the highlight of the pause menu, gliding to the selection
    menu_pulse: f32              // 1 when the selection changes, fading
    mode: Mode
    mode_age: f32                // seconds in the current mode
    best_before: i64             // the best score when this game started
    demo: vec2                   // the title screen's ball, bouncing by itself
    demo_vel: vec2               // and where it went in the last frame
}

// The title screen's ball: straight lines between the walls and the paddle's line (two
// triangle waves), the paddle following it.
priv fn demo_ball(t: f32) -> vec2 {
    fn tri(x: f32) -> f32 { 1.0 - fabs(fract(x) * 2.0 - 1.0) }
    vec2(lerp(FIELD_L + BALL_R, FIELD_R - BALL_R, tri(t * 0.19)), lerp(FIELD_T + BALL_R, PADDLE_Y - BALL_R, tri(t * 0.29 + 0.5)))
}

fn fx_new(seed: u64) -> *Fx {
    fx := new[Fx]()
    fx.rng = rng(seed)
    fx.ripple = vec3(0.0, 0.0, 9.0)
    fx.clear_age = 99.0
    fx
}

priv fn add(fx: *Fx, p: Part) {
    if fx.n_parts < MAX_PARTS {
        fx.parts[fx.n_parts] = p
        fx.n_parts += 1
    }
}

priv fn sparks(fx: *Fx, at: vec2, n: i64, dir: vec2, spread: f32, speed_lo: f32, speed_hi: f32, color: vec3) {
    for k in 0..n {
        a := atan2(dir.y, dir.x) + fx.rng.range(-spread, spread)
        v := vec2(cos(a), sin(a)) * fx.rng.range(speed_lo, speed_hi)
        fx.add(Part{kind: Spark, pos: at, vel: v, life: fx.rng.range(0.25, 0.55), size: 1.0, drag: 2.5, gravity: 140.0, color: color})
    }
}

priv fn burst(fx: *Fx, at: vec2, kind: PartKind, size: f32, life: f32, color: vec3) {
    fx.add(Part{kind: kind, pos: at, life: life, size: size, color: color})
}

// The brick an event happened at (its x is the brick's centre, n its row).
priv fn brick_of(e: GameEvent) -> i64 {
    col := clamp(i64((e.x - FIELD_L) / BRICK_W), 0, COLS - 1)
    clamp(e.n, 0, ROWS - 1) * COLS + col
}

priv fn centre(i: i64) -> vec2 {
    r := brick_rect(i)
    vec2(r.x + r.z / 2.0, r.y + r.w / 2.0)
}

priv fn shatter(fx: *Fx, g: *Game, i: i64) {
    row := i / COLS
    r := brick_rect(i)
    c := centre(i)
    away := if length(g.vel) > 1.0 { normalize(g.vel) } else { vec2(0.0, -1.0) }
    for k in 0..18 {
        p := vec2(r.x + fx.rng.range(1.0, r.z - 1.0), r.y + fx.rng.range(1.0, r.w - 1.0))
        out := p - c
        v := normalize(out + vec2(0.0, -2.0)) * fx.rng.range(25.0, 75.0) + away * fx.rng.range(10.0, 50.0)
        tone := fx.rng.range(0.0, 1.0)
        col := if tone < 0.3 { brick_light(row) } else { brick_base(row) }
        fx.add(Part{kind: Shard, pos: p, vel: v, life: fx.rng.range(0.7, 1.3), size: fx.rng.range(2.8, 5.6),
            angle: fx.rng.range(0.0, 6.283), spin: fx.rng.range(-14.0, 14.0), drag: 0.6, gravity: 300.0, color: col,
            shard: i64(fx.rng.below(u64(SHARD_COUNT)))})
    }
    fx.sparks(c, 14, away, 1.6, 60.0, 190.0, brick_light(row))
    fx.burst(c, Puff, 30.0, 0.35, brick_base(row) * 0.7)
    fx.burst(c, Flare, 18.0, 0.18, brick_light(row) * 0.6)
    if fx.n_popups < MAX_POPUPS {
        fx.popups[fx.n_popups] = Popup{c - vec2(0.0, 5.0), 0.0, 10 * i64(ROWS - row), brick_light(row)}
        fx.n_popups += 1
    }
    fx.shake = fmin(fx.shake + 0.35, 1.6)
    fx.ripple = vec3(c.x, c.y, 0.0)
}

// The point of the wall the ball touched, from the event's x and where the ball is now.
priv fn wall_point(g: *Game, x: f32) -> (vec2, vec2) {
    if x <= FIELD_L + BALL_R + 0.5 {
        return (vec2(FIELD_L, g.ball.y), vec2(1.0, 0.0))
    }
    if x >= FIELD_R - BALL_R - 0.5 {
        return (vec2(FIELD_R, g.ball.y), vec2(-1.0, 0.0))
    }
    (vec2(x, FIELD_T), vec2(0.0, 1.0))
}

// The game's events of this frame (call before play_events clears them).
priv fn events(fx: *Fx, g: *Game) {
    cyan := vec3(0.4, 0.9, 1.0)
    for e in g.events {
        match e.sfx {
            SfxBreak => shatter(fx, g, brick_of(e))
            SfxBrick => {
                if g.mode == Playing {
                    i := brick_of(e)
                    fx.brick_flash[i] = 1.0
                    fx.sparks(vec2(e.x, g.ball.y), 6, vec2(-g.vel.x, -g.vel.y), 1.2, 50.0, 140.0, lerp(brick_light(e.n), vec3(1.0), 0.5))
                    fx.burst(g.ball, Ring, 16.0, 0.25, brick_light(e.n))
                    fx.shake = fmin(fx.shake + 0.15, 1.6)
                }
            }
            SfxPaddle => {
                fx.paddle_flash = 1.0
                fx.paddle_hit = e.x
                at := vec2(e.x, PADDLE_Y)
                fx.sparks(at, 8, vec2(0.0, -1.0), 0.9, 50.0, 130.0, cyan)
                fx.burst(at, Ring, 22.0, 0.3, cyan)
                fx.burst(at, Flare, 14.0, 0.15, vec3(0.8, 1.0, 1.0))
            }
            SfxWall => {
                at, n := wall_point(g, e.x)
                fx.wall_flash = 1.0
                fx.wall_hit = at
                fx.sparks(at, 5, n, 1.0, 40.0, 110.0, vec3(1.0, 0.5, 0.9))
                fx.burst(at, Flare, 12.0, 0.15, vec3(1.0, 0.7, 1.0))
            }
            SfxLaunch => {
                fx.burst(g.ball, Ring, 26.0, 0.35, cyan)
                fx.sparks(g.ball, 10, normalize(g.vel), 0.5, 40.0, 120.0, cyan)
            }
            SfxLost => {
                at := vec2(clamp(e.x, FIELD_L + 4.0, FIELD_R - 4.0), f32(VIEW_H) - 2.0)
                fx.lost_flash = 1.0
                fx.shake = fmin(fx.shake + 1.2, 1.8)
                fx.sparks(at, 30, vec2(0.0, -1.0), 1.1, 60.0, 220.0, vec3(1.0, 0.35, 0.25))
                fx.burst(at, Puff, 70.0, 0.6, vec3(1.0, 0.2, 0.15))
                fx.burst(at, Ring, 60.0, 0.5, vec3(1.0, 0.4, 0.3))
                fx.n_trail = 0
            }
            SfxLevel => {
                fx.clear_flash = 1.0
                fx.clear_age = 0.0
                fx.shake = fmin(fx.shake + 0.5, 1.6)
                // fireworks over the empty field, one after another
                for k in 0..8 {
                    at := vec2(fx.rng.range(FIELD_L + 30.0, FIELD_R - 30.0), fx.rng.range(BRICKS_T, BRICKS_T + 70.0))
                    col := brick_base(k % ROWS)
                    first := fx.n_parts
                    fx.sparks(at, 24, vec2(0.0, -1.0), 3.2, 40.0, 160.0, brick_light(k % ROWS))
                    fx.burst(at, Ring, 44.0, 0.6, col)
                    fx.burst(at, Flare, 26.0, 0.3, brick_light(k % ROWS))
                    for j in first..fx.n_parts {
                        fx.parts[j].age = -0.12 * f32(k)          // waits that long before it starts
                    }
                }
            }
            SfxOver => {
                fx.shake = fmin(fx.shake + 0.8, 1.8)
            }
            SfxMove, SfxSelect => fx.menu_pulse = 1.0
        }
    }
}

// Moves the particles, timers and the shake on by dt seconds.
priv fn step(fx: *Fx, dt: f32) {
    i := 0
    while i < fx.n_parts {
        p := &fx.parts[i]
        p.age += dt
        if p.age < 0.0 {
            i += 1                                      // not started yet
            continue
        }
        if p.age >= p.life {
            fx.n_parts -= 1
            fx.parts[i] = fx.parts[fx.n_parts]
            continue
        }
        p.vel = p.vel * fmax(1.0 - p.drag * dt, 0.0)
        p.vel.y += p.gravity * dt
        p.pos = p.pos + p.vel * dt
        p.angle += p.spin * dt
        i += 1
    }
    i = 0
    while i < fx.n_popups {
        q := &fx.popups[i]
        q.age += dt
        if q.age >= 1.0 {
            fx.n_popups -= 1
            fx.popups[i] = fx.popups[fx.n_popups]
            continue
        }
        q.pos.y -= 22.0 * dt * (1.0 - q.age)
        i += 1
    }
    for k in 0..ROWS * COLS {
        fx.brick_flash[k] = fmax(fx.brick_flash[k] - dt * 5.0, 0.0)
    }
    fx.paddle_flash = fmax(fx.paddle_flash - dt * 4.0, 0.0)
    fx.wall_flash = fmax(fx.wall_flash - dt * 4.0, 0.0)
    fx.lost_flash = fmax(fx.lost_flash - dt * 1.8, 0.0)
    fx.clear_flash = fmax(fx.clear_flash - dt * 1.5, 0.0)
    fx.clear_age += dt
    fx.ripple.z += dt
    fx.shake *= exp(-dt * 5.0)
}

// One displayed frame: dt seconds since the last one, `ball` where the ball is drawn. Reads
// the game's events, so call it before play_events.
fn fx_frame(fx: *Fx, g: *Game, dt: f32, ball: vec2) {
    fx.time += f64(dt)
    if g.mode != fx.mode {
        if g.mode == Playing && fx.mode == Title {
            fx.best_before = g.best
            fx.n_parts = 0
            fx.n_popups = 0
            fx.score_shown = 0.0
        }
        if g.mode == Paused {
            fx.menu_pos = f32(g.menu)
        }
        fx.mode = g.mode
        fx.mode_age = 0.0
    } else {
        fx.mode_age += dt
    }
    events(fx, g)
    // the menus animate; a paused game stands still
    fx.menu_pos += (f32(g.menu) - fx.menu_pos) * fmin(dt * 16.0, 1.0)
    fx.menu_pulse = fmax(fx.menu_pulse - dt * 3.0, 0.0)
    if g.mode == Paused {
        return
    }
    step(fx, dt)
    a := fmin(f32(fx.shake), 1.6)
    t := f32(fx.time)
    amp := a * a * 2.2
    fx.shake_off = vec2(sin(t * 83.0) + 0.5 * sin(t * 47.3 + 1.0), cos(t * 71.0) + 0.5 * sin(t * 39.7)) * (amp / 1.5)
    if g.mode == Title {
        // where the title screen's ball turned this frame, it hit a wall or the paddle
        p := demo_ball(t)
        v := p - fx.demo
        if fx.demo_vel.x * v.x < 0.0 {
            n := vec2(if v.x > 0.0 { 1.0 } else { -1.0 }, 0.0)
            fx.sparks(p - n * BALL_R, 5, n, 1.0, 40.0, 110.0, vec3(1.0, 0.5, 0.9))
            fx.wall_flash = 1.0
            fx.wall_hit = vec2(if v.x > 0.0 { FIELD_L } else { FIELD_R }, p.y)
        }
        if fx.demo_vel.y * v.y < 0.0 {
            if v.y < 0.0 {
                fx.paddle_flash = 1.0
                fx.paddle_hit = p.x
                fx.sparks(vec2(p.x, PADDLE_Y), 8, vec2(0.0, -1.0), 0.9, 50.0, 130.0, vec3(0.4, 0.9, 1.0))
                fx.burst(vec2(p.x, PADDLE_Y), Ring, 22.0, 0.3, vec3(0.4, 0.9, 1.0))
            } else {
                fx.sparks(vec2(p.x, FIELD_T), 5, vec2(0.0, 1.0), 1.0, 40.0, 110.0, vec3(1.0, 0.5, 0.9))
                fx.wall_flash = 1.0
                fx.wall_hit = vec2(p.x, FIELD_T)
            }
        }
        fx.demo_vel = v
        fx.demo = p
        ball = p
    }
    // the trail: where the ball is drawn, while it flies
    if (g.mode == Playing && !g.stuck) || g.mode == Title {
        if fx.n_trail > 0 && length(fx.trail[fx.n_trail - 1] - ball) > 30.0 {
            fx.n_trail = 0
        }
        if fx.n_trail == TRAIL_LEN {
            for k in 1..TRAIL_LEN {
                fx.trail[k - 1] = fx.trail[k]
            }
            fx.n_trail -= 1
        }
        fx.trail[fx.n_trail] = ball
        fx.n_trail += 1
    } else {
        fx.n_trail = 0
    }
    // the score in the display counts up
    target := f32(g.score)
    if fx.score_shown > target {
        fx.score_shown = target
    }
    fx.score_shown = fmin(fx.score_shown + fmax((target - fx.score_shown) * fmin(dt * 10.0, 1.0), dt * 30.0), target)
}
