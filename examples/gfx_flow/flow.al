// The simulation of examples/gfx_flow, without a GPU: a flow field and the particles it
// carries. Deterministic: the same seed, presets and mouse give the same particles.
//
// The field is the curl of a noise potential (divergence free: particles neither bunch up
// nor thin out, they stream along its level lines) plus a preset's wind, swirl and radial
// streaming. Evaluating fractal noise per particle would cost far too much, so it is sampled
// on a grid of nodes CELL units apart at keyframes KF_STEPS steps apart; the particles read
// the mix of two keyframes, while the next one is computed a few rows per step. Nothing is
// allocated after `sim_new`.

const HZ = 60
const DT: f32 = 1.0 / 60.0
const CELL: f32 = 12.0            // units between field nodes
const KF_STEPS = 30               // steps between field keyframes (half a second)
const UNITS: f32 = 720.0          // the picture's height in units

struct Field {
    gw: i64                       // nodes per row and per column; node (i, j) is at
    gh: i64                       // ((i - 1) * CELL, (j - 1) * CELL)
    k0: []vec2                    // velocity at the keyframe behind,
    k1: []vec2                    // the one ahead,
    next: []vec2                  // the one being built,
    cur: []vec2                   // and their mix for this step
    psi: []f32                    // potential of `next`, (gw + 2) x (gh + 2) with a border
    row: i64                      // the next row of psi to compute
    phase: i64                    // steps since k1 became the keyframe ahead
    z: f32                        // noise time of `next`
}

struct Mouse {
    pos: vec2                     // in units
    pull: f32                     // 1 attracts, -1 repels, 0 nothing; eased by the caller
}

struct Sim {
    w: f32                        // the picture in units: UNITS high
    h: f32
    seed: u64
    rng: Rng
    p: Params                     // what the field and the particles follow now
    f: Field
    cap: i64                      // particles allocated
    active: i64                   // particles alive (the first `active`)
    pos: []vec2
    last: []vec2                  // where the trail drawn so far ends
    vel: []vec2
    age: []f32
    life: []f32
    tag: []f32                    // a random number per particle, for its colour
    spawn: Spawn
    spread: f32
    steps: i64
}

// A simulation of `cap` particles on a picture `aspect` times as wide as high.
fn sim_new(aspect: f32, cap: i64, seed: u64, p: Params, spawn: Spawn, spread: f32) -> Sim {
    s := Sim{w: UNITS * aspect, h: UNITS, cap: cap, p: p, spawn: spawn, spread: spread}
    s.f.gw = i64(ceil(s.w / CELL)) + 3
    s.f.gh = i64(ceil(s.h / CELL)) + 3
    n := s.f.gw * s.f.gh
    s.f.k0 = alloc[vec2](n)
    s.f.k1 = alloc[vec2](n)
    s.f.next = alloc[vec2](n)
    s.f.cur = alloc[vec2](n)
    s.f.psi = alloc[f32]((s.f.gw + 2) * (s.f.gh + 2))
    s.pos = alloc[vec2](cap)
    s.last = alloc[vec2](cap)
    s.vel = alloc[vec2](cap)
    s.age = alloc[f32](cap)
    s.life = alloc[f32](cap)
    s.tag = alloc[f32](cap)
    sim_reseed(&s, seed)
    s
}

// Starts over from `seed`: a new field, every particle somewhere new.
fn sim_reseed(s: *Sim, seed: u64) {
    s.seed = seed
    s.rng = rng(seed)
    s.f.z = 0.0
    field_full(s, &s.f.k0)
    field_full(s, &s.f.k1)
    s.f.row = 0
    s.f.phase = 0
    copy(s.f.cur, s.f.k0)
    s.active = min(i64(s.p.count), s.cap)
    for i in 0..s.cap {
        spawn(s, i)
        s.age[i] = s.rng.range(0.0, s.life[i])     // not all born at once
    }
}

// The noise potential at (x, y) units and noise time z.
fn potential(p: *Params, seed: u32, x: f32, y: f32, z: f32) -> f32 {
    fx := x / (p.feature * sqrt(p.stretch))
    fy := y / (p.feature / sqrt(p.stretch))
    if p.warp > 0.0 {                                  // displace the domain by a coarser noise
        wx := noise3(fx * 0.5 + 3.7, fy * 0.5, z * 0.5, seed + 101)
        wy := noise3(fx * 0.5, fy * 0.5 + 8.3, z * 0.5, seed + 202)
        fx += p.warp * wx
        fy += p.warp * wy
    }
    octaves := i64(p.octaves + 0.5)
    sum := 0.0
    amp := 1.0
    for o in 0..max(octaves, 1) {
        sum += amp * noise3(fx, fy, z, seed + u32(o))
        fx = fx * 2.0 + 17.0
        fy = fy * 2.0 - 11.0
        amp *= 0.5
    }
    sum
}

// Row j of the potential of the keyframe being built.
priv fn psi_row(s: *Sim, j: i64) {
    f := &s.f
    seed := u32(s.seed & 0xFFFF_FFFF)
    pw := f.gw + 2
    y := f32(j - 2) * CELL
    for i in 0..pw {
        f.psi[j * pw + i] = potential(&s.p, seed, f32(i - 2) * CELL, y, f.z)
    }
}

// The velocities of the keyframe from the finished potential: its curl, scaled so that the
// mean speed is the preset's, plus wind, swirl and radial streaming.
priv fn finish_keyframe(s: *Sim, out: []vec2) {
    f := &s.f
    p := &s.p
    pw := f.gw + 2
    inv := 1.0 / (2.0 * CELL)
    total := 0.0
    for j in 0..f.gh {
        for i in 0..f.gw {
            c := (j + 1) * pw + i + 1
            v := vec2((f.psi[c + pw] - f.psi[c - pw]) * inv, -(f.psi[c + 1] - f.psi[c - 1]) * inv)
            out[j * f.gw + i] = v
            total += length(v)
        }
    }
    gain := if total > 0.0 { p.speed * f32(f.gw * f.gh) / total } else { 0.0 }
    focus := vec2(p.focus.x * s.w, p.focus.y * s.h)
    for j in 0..f.gh {
        for i in 0..f.gw {
            d := vec2(f32(i - 1) * CELL, f32(j - 1) * CELL) - focus
            r := length(d) + 1.0
            dir := d / r
            k := j * f.gw + i
            spin := p.swirl * min(r / 300.0, 1.0)
            out[k] = out[k] * gain + p.drift + dir * p.radial * min(r / 40.0, 1.0) + perp(dir) * spin
        }
    }
}

// A whole keyframe at once (at the start), then the noise time moves on.
priv fn field_full(s: *Sim, out: *[]vec2) {
    for j in 0..s.f.gh + 2 {
        psi_row(s, j)
    }
    finish_keyframe(s, *out)
    s.f.z += s.p.evolve * f32(KF_STEPS) * DT
}

// One step of the field: a share of the next keyframe's rows, the keyframes rotated when it
// is complete, and the mix for this step.
fn field_step(s: *Sim) {
    f := &s.f
    rows := f.gh + 2
    per := (rows + KF_STEPS - 2) / (KF_STEPS - 1)  // done one step before it is needed
    for k in 0..per {
        if f.row < rows {
            psi_row(s, f.row)
            f.row += 1
        }
    }
    f.phase += 1
    if f.phase >= KF_STEPS {
        finish_keyframe(s, f.next)
        f.z += s.p.evolve * f32(KF_STEPS) * DT
        old := f.k0
        f.k0 = f.k1
        f.k1 = f.next
        f.next = old
        f.row = 0
        f.phase = 0
    }
    t := f32(f.phase) / f32(KF_STEPS)
    t = t * t * (3.0 - 2.0 * t)                      // no kink in the speed at a keyframe
    for k in 0..f.gw * f.gh {
        f.cur[k] = f.k0[k] + (f.k1[k] - f.k0[k]) * t
    }
}

// The field's velocity at (x, y) units, bilinear between nodes.
inline fn sample(f: *Field, x: f32, y: f32) -> vec2 {
    gx := clamp(x / CELL + 1.0, 0.0, f32(f.gw - 2) + 0.999)
    gy := clamp(y / CELL + 1.0, 0.0, f32(f.gh - 2) + 0.999)
    i := i64(gx)
    j := i64(gy)
    tx := gx - f32(i)
    ty := gy - f32(j)
    k := j * f.gw + i
    a := f.cur[k] + (f.cur[k + 1] - f.cur[k]) * tx
    b := f.cur[k + f.gw] + (f.cur[k + f.gw + 1] - f.cur[k + f.gw]) * tx
    a + (b - a) * ty
}

const DROPS = 5                   // Drops: points that release ink at once
const DROP_STEPS = 9 * HZ         // each moves elsewhere after this long (staggered)

priv fn unit_hash(a: i64, b: i64, c: i64, seed: u64) -> f32 {
    f32(noise_hash(a, b, c, u32(seed & 0xFFFF_FFFF)) >> 8) / 16777216.0
}

// Where drop k is at step `t`.
fn drop_at(s: *Sim, k: i64, t: i64) -> vec2 {
    epoch := (t + k * DROP_STEPS / DROPS) / DROP_STEPS
    vec2(s.w * (0.1 + 0.8 * unit_hash(k, epoch, 1, s.seed)), s.h * (0.08 + 0.35 * unit_hash(k, epoch, 2, s.seed)))
}

// How much a place is wanted at time t (0..1): slowly drifting clouds of noise.
priv fn density(s: *Sim, x: f32, y: f32, t: f32) -> f32 {
    seed := u32(s.seed & 0xFFFF) + 900
    n := noise2(x / 380.0 + t * 0.015, y / 380.0, seed) + 0.5 * noise2(x / 160.0, y / 160.0 - t * 0.02, seed + 1)
    smoothstep(-0.15, 0.55, n)
}

// Particle i starts a new life.
fn spawn(s: *Sim, i: i64) {
    r := &s.rng
    t := f32(s.steps) * DT
    tag := r.next_f32()
    p := vec2(0.0)
    match s.spawn {
        Anywhere => { p = vec2(r.range(0.0, s.w), r.range(0.0, s.h)) }
        Clouds => {                                  // more where the noise is high
            for k in 0..8 {
                p = vec2(r.range(0.0, s.w), r.range(0.0, s.h))
                if r.next_f32() < density(s, p.x, p.y, t) {
                    break
                }
            }
        }
        Curtain => {                                 // a base line folding slowly in two waves,
            x := 0.0                                 // brighter in some stretches than in others
            for k in 0..6 {
                x = r.range(-0.05 * s.w, 1.05 * s.w)
                if r.next_f32() < 0.2 + 0.8 * density(s, x, 0.0, t * 3.0) {
                    break
                }
            }
            u := x / s.w * 6.2832
            y := s.p.focus.y * s.h + 42.0 * sin(u * 1.1 + t * 0.11) + 20.0 * sin(u * 2.7 - t * 0.23 + 1.0)
            p = vec2(x, y + r.normal(0.0, s.spread))
        }
        Drops => {                                   // each drop has its own ink: tag by drop
            k := i64(r.below(DROPS))
            p = drop_at(s, k, s.steps) + r.in_circle() * s.spread
            tag = (f32(k) + 0.35 * tag) / f32(DROPS)
        }
        Ring => {
            d := r.unit_vec2()
            p = vec2(s.p.focus.x * s.w, s.p.focus.y * s.h) + d * (s.spread + fabs(r.normal(0.0, 4.0)))
        }
    }
    s.pos[i] = p
    s.last[i] = p
    s.vel[i] = vec2(0.0)
    s.age[i] = 0.0
    s.life[i] = r.range(s.p.life.x, max(s.p.life.y, s.p.life.x + 0.01))
    s.tag[i] = tag
}

// One fixed step of everything.
fn sim_step(s: *Sim, m: Mouse) {
    field_step(s)
    want := clamp(i64(s.p.count + 0.5), 0, s.cap)
    for i in s.active..want {                       // more particles: born now
        spawn(s, i)
    }
    s.active = want
    margin := 40.0
    reach := 1.0 / (170.0 * 170.0)
    pull := m.pull * 260.0
    for i in 0..s.active {
        p := s.pos[i]
        v := sample(&s.f, p.x, p.y)
        if pull != 0.0 {                             // the mouse: a pull with a twist, fading as 1/r^2
            d := m.pos - p
            r2 := d.x * d.x + d.y * d.y
            dir := d / sqrt(r2 + 100.0)
            v = v + (dir + perp(dir) * 0.6) * (pull / (1.0 + r2 * reach))
            if pull > 0.0 && r2 < 25.0 {
                s.age[i] = s.life[i]                     // swallowed: born again elsewhere
            }
        }
        p = p + v * DT
        s.pos[i] = p
        s.vel[i] = v
        s.age[i] += DT
        if s.age[i] > s.life[i] || p.x < -margin || p.y < -margin || p.x > s.w + margin || p.y > s.h + margin {
            spawn(s, i)
        }
    }
    s.steps += 1
}

// A checksum of the particles (tests: the same on every machine).
fn sim_checksum(s: *Sim) -> u64 {
    h: u64 = 14695981039346656037
    for i in 0..s.active {
        h = (h ^ u64(cast[u32](s.pos[i].x))) * 1099511628211
        h = (h ^ u64(cast[u32](s.pos[i].y))) * 1099511628211
    }
    h
}

// Every particle starts a new life now, at an age somewhere in it (a new piece of another
// kind: what the old one's particles would draw does not belong there).
fn sim_respawn(s: *Sim) {
    for i in 0..s.active {
        spawn(s, i)
        s.age[i] = s.rng.range(0.0, s.life[i])
    }
}
