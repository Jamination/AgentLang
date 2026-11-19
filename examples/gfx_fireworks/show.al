// The fireworks show itself: rising shells, the sparks of their bursts, the flashes that light
// the city and the smoke they leave, and the choreography that launches them. Pure simulation
// on a fixed step from a seed: no window, no GPU, and no allocation after show_new (particles,
// shells, flashes and smoke live in arrays of fixed size; what does not fit is not spawned).
//
// Coordinates are the pixels of a 1280 x 720 picture, y down; the water starts at HORIZON.

const HZ = 60
const DT: f32 = 1.0 / 60.0
const VW: f32 = 1280.0
const VH: f32 = 720.0
const HORIZON: f32 = 492.0
const GRAVITY: f32 = 62.0            // pixels / s^2 on the sparks
const SHELL_G: f32 = 160.0           // on rising shells: they climb fast and slow down visibly
const LIGHT_R: f32 = 300.0           // how far a flash lights the sky, the smoke and the city

const MAX_PARTS = 16000
const MAX_SHELLS = 64
const MAX_FLASHES = 40
const MAX_PUFFS = 420

// What a particle does besides flying (Particle.flags).
const F_CRACKLE: u32 = 1             // pops into a few tiny white flashes when it burns out
const F_STROBE: u32 = 2              // glitters (on / off) in the second half of its life
const F_POP: u32 = 4                 // one of those flashes: very short, white
const F_EMBER: u32 = 8               // a trail ember or a shell's tail spark: born glowing, not white hot

// The launch pads: barges along the far shore.
const PADS = [_]f32{150.0, 330.0, 500.0, 640.0, 780.0, 950.0, 1130.0}

enum Pattern { Peony, Chrysanthemum, Ring, Willow, Crackle, Pistil, Palm, Glitter, Rainbow }
const N_PATTERNS = 9                 // (Pattern(k) and variant_count[Pattern]() once build\alc.exe has them)
const PATTERNS = [_]Pattern{Peony, Chrysanthemum, Ring, Willow, Crackle, Pistil, Palm, Glitter, Rainbow}

struct Particle {
    pos: vec2
    vel: vec2
    col: vec3            // its own colour; the renderer heats it to white at birth, cools it to red at the end
    age: f32             // seconds; below 0 it waits (a crackle pop not yet popped)
    life: f32
    size: f32            // radius of its head in pixels
    drag: f32            // velocity lost per second (fraction)
    grav: f32            // times GRAVITY
    rate: f32            // trail embers per second (0: none)
    emit: f32            // embers owed
    flags: u32
    seed: u32            // the phase of its glitter
}

struct Shell {
    pos: vec2
    vel: vec2
    age: f32
    fuse: f32            // bursts at this age: near the top of its climb
    pattern: Pattern
    a: vec3              // its colours
    b: vec3
    scale: f32           // of the burst
    emit: f32
    puff: f32
}

// A burst's light: what colours the sky, the smoke, the buildings and the water.
struct Flash { pos: vec2, col: vec3, age: f32, power: f32 }

struct Puff { pos: vec2, vel: vec2, col: vec3, age: f32, life: f32, size: f32, grow: f32, alpha: f32, spin: f32 }

// One part of the choreography: how long it lasts, the mean time between cues, shells per cue,
// the patterns it draws from (bits of Pattern) and whether cues come as mirrored pairs.
struct Act { secs: f32, gap: f32, salvo: i64, mask: u32, mirror: bool }

const ALL: u32 = 0x1FF
const ACTS = [_]Act{
    Act{secs: 7.0, gap: 0.55, salvo: 1, mask: 0x027, mirror: false},  // overture: peonies, chrysanthemums, rings, pistils
    Act{secs: 8.0, gap: 1.25, salvo: 2, mask: 0x048, mirror: true},   // gold willows and palms in pairs
    Act{secs: 9.0, gap: 0.42, salvo: 1, mask: 0x1A5, mirror: false},  // colour: peonies, rings, pistils, glitter, rainbows
    Act{secs: 7.0, gap: 0.48, salvo: 1, mask: 0x092, mirror: false},  // crackle and glitter
    Act{secs: 7.0, gap: 0.15, salvo: 1, mask: ALL, mirror: false},    // finale
    Act{secs: 4.0, gap: 100.0, salvo: 0, mask: 0, mirror: false},     // a breath: the smoke drifts off
}

const ACT_NAMES = [_]str{"overture", "willows", "colours", "crackle", "finale", "interlude"}

struct Show {
    rng: Rng
    parts: []Particle
    nparts: i64
    shells: []Shell
    nshells: i64
    flashes: []Flash
    nflashes: i64
    puffs: []Puff
    npuffs: i64
    time: f64            // seconds simulated
    steps: i64
    act: i64
    act_end: f64
    next_cue: f64
    wind: f32            // pixels / s, drifts the smoke
    launched: i64
    bursts: i64
    auto: bool           // run the choreography (false: only what the user launches)
    click: vec2          // where the last shell was aimed by hand, and when (the HUD marks it)
    click_time: f64
}

fn show_new(seed: u64) -> Show {
    Show{rng: rng(seed), parts: alloc[Particle](MAX_PARTS), shells: alloc[Shell](MAX_SHELLS),
        flashes: alloc[Flash](MAX_FLASHES), puffs: alloc[Puff](MAX_PUFFS),
        act_end: f64(ACTS[0].secs), next_cue: 0.2, auto: true, click_time: -10.0}
}

// Firework colours: saturated, a little lighter than pure primaries so they read as light.
fn palette(i: i64) -> vec3 {
    match i % 9 {
        0 => vec3(1.0, 0.20, 0.16)       // strontium red
        1 => vec3(1.0, 0.62, 0.22)       // gold
        2 => vec3(0.42, 1.0, 0.30)       // barium green
        3 => vec3(0.25, 0.48, 1.0)       // copper blue
        4 => vec3(0.78, 0.36, 1.0)       // violet
        5 => vec3(1.0, 0.34, 0.66)       // rose
        6 => vec3(0.30, 0.95, 1.0)       // cyan
        7 => vec3(1.0, 0.92, 0.42)       // lemon
        _ => vec3(0.88, 0.92, 1.0)       // silver
    }
}

fn gold() -> vec3 { vec3(1.0, 0.66, 0.30) }

// ---- spawning --------------------------------------------------------------------------------

priv fn spark(s: *Show, p: Particle) -> bool {
    if s.nparts >= MAX_PARTS {
        return false
    }
    s.parts[s.nparts] = p
    s.nparts += 1
    true
}

priv fn add_flash(s: *Show, pos: vec2, col: vec3, power: f32) {
    if s.nflashes >= MAX_FLASHES {            // the oldest light gives way
        for i in 1..s.nflashes {
            s.flashes[i - 1] = s.flashes[i]
        }
        s.nflashes -= 1
    }
    s.flashes[s.nflashes] = Flash{pos, col, 0.0, power}
    s.nflashes += 1
}

priv fn add_puff(s: *Show, p: Puff) {
    if s.npuffs < MAX_PUFFS {
        s.puffs[s.npuffs] = p
        s.npuffs += 1
    }
}

// Sends a shell from the pad at x so that it bursts at `to`.
fn launch(s: *Show, x: f32, to: vec2, pattern: Pattern, a: vec3, b: vec3, scale: f32) {
    if s.nshells >= MAX_SHELLS {
        return
    }
    h := fmax(HORIZON - 6.0 - to.y, 40.0)
    v := sqrt(2.0 * SHELL_G * h)
    t := v / SHELL_G
    s.shells[s.nshells] = Shell{pos: vec2(x, HORIZON - 6.0), vel: vec2((to.x - x) / t, -v), fuse: t * s.rng.range(0.96, 1.0),
        pattern: pattern, a: a, b: b, scale: scale}
    s.nshells += 1
    s.launched += 1
}

// The pad nearest to x.
fn nearest_pad(x: f32) -> f32 {
    best := PADS[0]
    for p in PADS {
        if fabs(p - x) < fabs(best - x) {
            best = p
        }
    }
    best
}

fn random_pattern(s: *Show, mask: u32) -> Pattern {
    loop {
        k := i64(s.rng.below(N_PATTERNS))
        if mask & (u32(1) << u32(k)) != 0 {
            return PATTERNS[k]
        }
    }
}

// A shell aimed at a point (a click): from the nearest pad, a random pattern and colour.
fn launch_at(s: *Show, to: vec2) {
    s.click = to
    s.click_time = s.time
    p := random_pattern(s, ALL)
    c := i64(s.rng.below(9))
    launch(s, nearest_pad(to.x), vec2(to.x, fmin(to.y, HORIZON - 60.0)), p, palette(c), palette(c + 1 + i64(s.rng.below(7))), 1.0)
}

// One shell from every pad at once, the bursts in an arc, colours from one family.
fn volley(s: *Show) {
    p := random_pattern(s, 0x1A7)
    c := i64(s.rng.below(9))
    for i, x in PADS {
        u := f32(i) / f32(len(PADS) - 1) * 2.0 - 1.0
        to := vec2(x + u * 40.0, 150.0 + u * u * 110.0)
        launch(s, x, to, p, palette(c + (i & 1) * 4), palette(c + 2), 0.85)
    }
}

// One cue of the choreography.
priv fn cue(s: *Show) {
    a := ACTS[s.act]
    for k in 0..a.salvo {
        p := random_pattern(s, a.mask)
        c := i64(s.rng.below(9))
        ca := if p == Willow || p == Crackle || (p == Palm && s.rng.chance(0.6)) { gold() } else { palette(c) }
        cb := palette(c + 1 + i64(s.rng.below(7)))
        pad := PADS[s.rng.below(u64(len(PADS)))]
        to := vec2(pad + s.rng.range(-110.0, 110.0), s.rng.range(110.0, 320.0))
        scale := s.rng.range(0.8, 1.2)
        if a.mirror {
            to.x = s.rng.range(170.0, 520.0)
            launch(s, nearest_pad(to.x), to, p, ca, cb, scale)
            launch(s, nearest_pad(VW - to.x), vec2(VW - to.x, to.y), p, ca, cb, scale)
        } else {
            launch(s, nearest_pad(to.x), to, p, ca, cb, scale)
        }
    }
}

// The sparks of a burst. `d` is a direction on the unit sphere seen from the front, so a
// peony is a ball whose edge is denser than its middle, as a real one looks.
priv fn star(s: *Show, at: vec2, vel: vec2, col: vec3, life: f32, size: f32, drag: f32, grav: f32, rate: f32, flags: u32) {
    seed := s.rng.next_u32()
    spark(s, Particle{pos: at, vel: vel, col: col, life: life, size: size, drag: drag, grav: grav, rate: rate,
        emit: s.rng.next_f32(), flags: flags, seed: seed})
}

priv fn burst(s: *Show, sh: *Shell) {
    s.bursts += 1
    at := sh.pos
    base := sh.vel * 0.25
    v := 205.0 * sh.scale
    sc := sh.scale
    power := 1.0
    match sh.pattern {
        Peony => {
            for i in 0..i64(150.0 * sc) {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * s.rng.range(0.92, 1.0), sh.a, s.rng.range(1.5, 2.1), 2.4, 1.3, 1.0, 0.0, 0)
            }
        }
        Chrysanthemum => {
            for i in 0..i64(120.0 * sc) {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * s.rng.range(0.92, 1.0), sh.a, s.rng.range(1.7, 2.3), 2.2, 1.35, 1.0, 14.0, 0)
            }
        }
        Ring => {
            squash := s.rng.range(0.2, 0.9)
            roll := s.rng.range(0.0, TAU)
            n := i64(110.0 * sc)
            for i in 0..n {
                a := f32(i) / f32(n) * TAU + s.rng.range(-0.02, 0.02)
                d := rotate(vec2(cos(a), sin(a) * squash), roll)
                star(s, at, base + d * v * s.rng.range(0.97, 1.0), sh.a, s.rng.range(1.6, 2.0), 2.4, 1.3, 0.9, 0.0, 0)
            }
            for i in 0..36 {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * 0.35, sh.b, s.rng.range(1.0, 1.4), 2.2, 1.6, 0.8, 0.0, 0)
            }
        }
        Willow => {
            power = 0.8
            for i in 0..i64(110.0 * sc) {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * 0.9 * s.rng.range(0.9, 1.0), sh.a, s.rng.range(3.2, 4.2), 2.0, 1.7, 1.15, 26.0, 0)
            }
        }
        Crackle => {
            for i in 0..i64(120.0 * sc) {
                d := s.rng.unit_vec3()
                c := if s.rng.chance(0.5) { gold() } else { palette(8) }
                star(s, at, base + d.xy * v * 0.85 * s.rng.range(0.85, 1.0), c, s.rng.range(0.9, 1.45), 1.9, 1.5, 0.9, 0.0, F_CRACKLE)
            }
        }
        Pistil => {
            for i in 0..i64(130.0 * sc) {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * s.rng.range(0.93, 1.0), sh.a, s.rng.range(1.6, 2.1), 2.3, 1.3, 1.0, 0.0, 0)
            }
            for i in 0..i64(55.0 * sc) {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * 0.45, sh.b, s.rng.range(1.1, 1.5), 2.6, 1.4, 0.8, 0.0, 0)
            }
        }
        Palm => {
            power = 1.2
            arms := 7 + i64(s.rng.below(3))
            turn := s.rng.range(0.0, TAU)
            for i in 0..arms {
                a := turn + f32(i) / f32(arms) * TAU
                d := vec2(cos(a), sin(a) * 0.85 - 0.25)
                star(s, at, base + d * v * 1.05, sh.a, s.rng.range(2.2, 2.7), 4.2, 0.95, 1.25, 70.0, 0)
            }
            for i in 0..50 {
                d := s.rng.unit_vec3()
                star(s, at, base + d.xy * v * 0.6, sh.a, s.rng.range(0.8, 1.3), 1.8, 1.6, 1.0, 0.0, 0)
            }
        }
        Glitter => {
            for i in 0..i64(140.0 * sc) {
                d := s.rng.unit_vec3()
                c := if s.rng.chance(0.7) { palette(8) } else { sh.a }
                star(s, at, base + d.xy * v * s.rng.range(0.9, 1.0), c, s.rng.range(2.2, 3.0), 2.2, 1.4, 0.8, 0.0, F_STROBE)
            }
        }
        Rainbow => {
            turn := s.rng.range(0.0, TAU)
            first := i64(s.rng.below(9))
            for i in 0..i64(170.0 * sc) {
                d := s.rng.unit_vec3()
                sector := i64(floor(fract((atan2(d.y, d.x) + turn) / TAU) * 5.0))
                star(s, at, base + d.xy * v * s.rng.range(0.92, 1.0), palette(first + sector * 2), s.rng.range(1.6, 2.1), 2.4, 1.3, 1.0, 0.0, 0)
            }
        }
    }
    light := if sh.pattern == Willow || sh.pattern == Crackle { gold() } else { lerp(sh.a, vec3(1.0), 0.3) }
    add_flash(s, at, light, power * sc)
    for i in 0..12 {
        off := s.rng.in_circle() * 95.0 * sc
        add_puff(s, Puff{pos: at + off, vel: off * 0.25 + vec2(0.0, -4.0), col: light, life: s.rng.range(7.0, 11.0),
            size: s.rng.range(50.0, 95.0) * sc, grow: s.rng.range(5.0, 10.0), alpha: s.rng.range(0.09, 0.16), spin: s.rng.range(0.0, TAU)})
    }
}

// ---- the step --------------------------------------------------------------------------------

// The light of a flash `age` seconds after its burst: a bright blink, then a glow that lasts
// while the sparks burn.
fn flash_power(f: Flash) -> f32 {
    f.power * (1.3 * exp(-7.0 * f.age) + 0.42 * exp(-0.9 * f.age))
}

// The light all bursts throw on point p (a colour, about 0..2); `reach` is the distance at
// which a flash gives half its light.
fn light_at(s: *Show, p: vec2, reach: f32) -> vec3 {
    sum := vec3(0.0)
    for f in s.flashes[..s.nflashes] {
        d := p - f.pos
        sum = sum + f.col * (flash_power(f) / (1.0 + dot(d, d) / (reach * reach)))
    }
    sum
}

fn light_at(s: *Show, p: vec2) -> vec3 { light_at(s, p, LIGHT_R) }

fn show_step(s: *Show) {
    s.steps += 1
    s.time = f64(s.steps) / f64(HZ)
    s.wind = 9.0 + 6.0 * sin(f32(s.time) * 0.07)
    if s.auto {
        while s.time >= s.act_end {
            s.act = (s.act + 1) % len(ACTS)
            s.act_end += f64(ACTS[s.act].secs)
            s.next_cue = fmax(s.next_cue, s.time + 0.3)
        }
        if s.time >= s.next_cue {
            cue(s)
            s.next_cue += f64(ACTS[s.act].gap * s.rng.range(0.6, 1.4))
        }
    }
    step_shells(s)
    step_parts(s)
    step_flashes(s)
    step_puffs(s)
}

priv fn step_shells(s: *Show) {
    i := 0
    while i < s.nshells {
        sh := &s.shells[i]
        sh.age += DT
        sh.vel.y += SHELL_G * DT
        sh.pos = sh.pos + sh.vel * DT
        sh.emit += 80.0 * DT                     // the comet tail of the rising shell
        while sh.emit >= 1.0 {
            sh.emit -= 1.0
            star(s, sh.pos + s.rng.in_circle() * 1.5, sh.vel * 0.12 + s.rng.in_circle() * 22.0, vec3(1.0, 0.6, 0.28),
                s.rng.range(0.3, 0.65), 1.4, 2.6, 0.5, 0.0, F_EMBER)
        }
        sh.puff += DT
        if sh.puff > 0.09 {
            sh.puff = 0.0
            add_puff(s, Puff{pos: sh.pos, vel: vec2(0.0, -2.0), col: vec3(1.0, 0.6, 0.3), life: s.rng.range(2.5, 3.5),
                size: 7.0, grow: 9.0, alpha: 0.075, spin: s.rng.range(0.0, TAU)})
        }
        if sh.age >= sh.fuse {
            burst(s, sh)
            s.shells[i] = s.shells[s.nshells - 1]
            s.nshells -= 1
            continue
        }
        i += 1
    }
}

priv fn step_parts(s: *Show) {
    i := 0
    while i < s.nparts {
        p := &s.parts[i]
        p.age += DT
        if p.age < 0.0 {                         // a pop that has not popped yet
            i += 1
            continue
        }
        if p.age >= p.life {
            if p.flags & F_CRACKLE != 0 {
                for k in 0..2 + i64(s.rng.below(3)) {
                    pos := p.pos + s.rng.in_circle() * 9.0
                    spark(s, Particle{pos: pos, vel: p.vel * 0.1, col: vec3(1.0, 0.93, 0.75), age: -s.rng.range(0.0, 0.35),
                        life: s.rng.range(0.05, 0.12), size: 1.6, flags: F_POP})
                }
            }
            s.parts[i] = s.parts[s.nparts - 1]
            s.nparts -= 1
            continue
        }
        p.vel = p.vel * (1.0 - p.drag * DT)
        p.vel.y += GRAVITY * p.grav * DT
        p.vel.x += s.wind * 0.15 * DT
        p.pos = p.pos + p.vel * DT
        if p.rate > 0.0 {
            p.emit += p.rate * DT * (1.0 - p.age / p.life)
            while p.emit >= 1.0 {
                p.emit -= 1.0
                long := p.rate > 20.0 && p.rate < 40.0       // willow: a long, drooping veil
                life := if long { s.rng.range(1.2, 2.2) } else { s.rng.range(0.45, 0.9) }
                spark(s, Particle{pos: p.pos + s.rng.in_circle() * 1.2, vel: p.vel * 0.06 + s.rng.in_circle() * 5.0,
                    col: p.col * 0.85, life: life, size: 1.25, drag: 2.0, grav: 0.32, flags: F_EMBER, seed: p.seed})
            }
        }
        i += 1
    }
}

priv fn step_flashes(s: *Show) {
    n := 0
    for i in 0..s.nflashes {
        f := s.flashes[i]
        f.age += DT
        f.pos.y += 14.0 * DT                     // the sparks sink, and their light with them
        if f.age < 5.0 {
            s.flashes[n] = f
            n += 1
        }
    }
    s.nflashes = n
}

priv fn step_puffs(s: *Show) {
    i := 0
    while i < s.npuffs {
        p := &s.puffs[i]
        p.age += DT
        if p.age >= p.life {
            s.puffs[i] = s.puffs[s.npuffs - 1]
            s.npuffs -= 1
            continue
        }
        p.vel = p.vel * (1.0 - 0.6 * DT) + vec2(s.wind, -3.0) * (0.6 * DT)
        p.pos = p.pos + p.vel * DT
        p.size += p.grow * DT
        i += 1
    }
}

// A number that changes when anything in the simulation does: for the test.
fn show_checksum(s: *Show) -> u64 {
    h: u64 = 0xcbf29ce484222325
    fn mix(h: u64, v: f32) -> u64 { (h ^ u64(i64(v * 16.0))) * 1099511628211 }
    for p in s.parts[..s.nparts] {
        h = mix(mix(h, p.pos.x), p.pos.y)
    }
    for p in s.puffs[..s.npuffs] {
        h = mix(h, p.size)
    }
    h
}

test "a show is the same from the same seed" {
    a := show_new(7)
    b := show_new(7)
    for i in 0..600 {
        show_step(&a)
        show_step(&b)
    }
    assert a.nparts > 1000, "the show is under way after 10 s"
    assert show_checksum(&a) == show_checksum(&b)
    assert a.launched == b.launched && a.bursts > 5
}

test "a clicked shell bursts where it was aimed; a volley leaves every pad" {
    s := show_new(3)
    s.auto = false
    launch_at(&s, vec2(420.0, 210.0))
    for i in 0..600 {
        show_step(&s)
        if s.bursts > 0 {
            break
        }
    }
    assert s.bursts == 1 && s.nflashes == 1
    assert length(s.flashes[0].pos - vec2(420.0, 210.0)) < 12.0, fmt("burst at ", s.flashes[0].pos)
    volley(&s)
    assert s.nshells == len(PADS)
}
