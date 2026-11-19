// The pieces of examples/gfx_flow: what each preset looks like, as numbers, and how two of
// them are mixed while the picture cross-fades from one to the next.
//
// Distances are in picture units: the picture is 720 units high whatever its pixel size (and
// as wide as the window's aspect makes it), so a preset looks the same at every resolution.

// Light: luminous trails added on a dark ground (additive blending). Ink: trails laid over
// paper (alpha blending), each segment moving it toward the ink's colour.
enum Mode { Light, Ink }

// Where a particle starts its life.
enum Spawn {
    Anywhere            // uniformly over the picture
    Clouds              // over the picture, more where slowly drifting noise is high
    Curtain             // along a slowly waving line across the picture at `focus.y`
    Drops               // around a few points that move on every few seconds (`spread`: radius)
    Ring                // on a circle of radius `spread` around `focus`
}

// What picks a particle's colour from the palette ramp: the sum of these, clamped to 0..1.
struct ColorKey {
    speed: f32          // times speed / (2 * preset speed)
    angle: f32          // times 0.5 + 0.5 * cos(direction - phase)
    phase: f32
    age: f32            // times age / life
    y: f32              // times height in the picture (0 top, 1 bottom)
    seed: f32           // times a random number fixed per particle
    base: f32
}

struct Preset {
    name: str
    mode: Mode
    ramp: [5]u32        // palette ramp from key 0 to key 1
    top: u32            // ground: a vertical gradient
    bottom: u32
    hud: u32            // colour of the HUD text over this ground
    count: i64          // particles
    width: f32          // line width in units
    alpha: f32          // opacity of one segment (0..1)
    trail: f32          // seconds until a trail has faded to 1/e
    fade_in: f32        // seconds a new particle takes to reach full opacity
    feature: f32        // size of the flow's features in units
    stretch: f32        // > 1: features wider than tall (the flow runs across); < 1: taller
    octaves: i64        // octaves of the noise potential
    warp: f32           // domain warp of the potential (0: none)
    evolve: f32         // how fast the field changes (noise time per second)
    speed: f32          // mean speed of the turbulent flow (units per second)
    drift: vec2         // a constant wind (units per second)
    swirl: f32          // turning about `focus` (units per second at 300 units)
    radial: f32         // streaming away from `focus` (units per second)
    focus: vec2         // fraction of the picture's width and height
    spawn: Spawn
    spread: f32
    life: vec2          // shortest and longest life in seconds
    key: ColorKey
    zoom: f32           // feedback: the previous picture is scaled by this per frame
    spin: f32           // and turned by this (radians per frame) about the centre
    glow: f32           // strength of the bloom (Light)
    stars: f32          // brightness of a sprinkle of stars behind the trails
    vignette: f32       // darkening of the corners
    moon: f32           // radius of a dark disc at `focus` hiding the stars behind it (0: none)
    ridge: f32          // opacity of two mountain ridges in front of everything
}

const PRESET_COUNT = 5

fn presets() -> [PRESET_COUNT]Preset {
    [PRESET_COUNT]Preset{
        // green curtains rising from a folded base line, violet and rose where they thin out
        Preset{
            name: "Aurora", mode: Light,
            ramp: [5]u32{rgb(150, 255, 180), rgb(60, 255, 130), rgb(30, 205, 125), rgb(70, 110, 195), rgb(170, 55, 165)},
            top: rgb(2, 3, 12), bottom: rgb(14, 36, 46), hud: rgb(170, 235, 205),
            count: 32000, width: 1.0, alpha: 0.09, trail: 0.9, fade_in: 0.08,
            feature: 300.0, stretch: 0.25, octaves: 2, warp: 0.3, evolve: 0.08, speed: 22.0,
            drift: vec2(6.0, -70.0), swirl: 0.0, radial: 0.0, focus: vec2(0.5, 0.5),
            spawn: Curtain, spread: 7.0, life: vec2(1.2, 3.6),
            key: ColorKey{age: 1.0, seed: 0.1},
            zoom: 1.0, spin: 0.0, glow: 0.55, stars: 1.0, vignette: 0.8, moon: 0.0, ridge: 1.0,
        },
        // inks dropped into still water, sinking and curling; each drop its own colour
        Preset{
            name: "Ink in water", mode: Ink,
            ramp: [5]u32{rgb(12, 16, 50), rgb(20, 42, 115), rgb(18, 20, 32), rgb(120, 36, 48), rgb(70, 34, 30)},
            top: rgb(245, 240, 229), bottom: rgb(230, 222, 207), hud: rgb(60, 56, 72),
            count: 24000, width: 1.8, alpha: 0.08, trail: 5.0, fade_in: 0.2,
            feature: 240.0, stretch: 1.0, octaves: 3, warp: 0.8, evolve: 0.10, speed: 40.0,
            drift: vec2(0.0, 30.0), swirl: 0.0, radial: 0.0, focus: vec2(0.5, 0.2),
            spawn: Drops, spread: 24.0, life: vec2(5.0, 11.0),
            key: ColorKey{seed: 1.0},
            zoom: 1.0, spin: 0.0, glow: 0.0, stars: 0.0, vignette: 0.3, moon: 0.0, ridge: 0.0,
        },
        // the corona of an eclipsed sun: white at the limb, streamers cooling to red and violet
        Preset{
            name: "Solar wind", mode: Light,
            ramp: [5]u32{rgb(255, 246, 225), rgb(255, 196, 100), rgb(235, 105, 45), rgb(150, 35, 60), rgb(50, 20, 90)},
            top: rgb(3, 2, 6), bottom: rgb(9, 4, 8), hud: rgb(250, 210, 170),
            count: 40000, width: 1.0, alpha: 0.05, trail: 0.6, fade_in: 0.0,
            feature: 260.0, stretch: 1.0, octaves: 2, warp: 0.4, evolve: 0.12, speed: 32.0,
            drift: vec2(0.0), swirl: 8.0, radial: 95.0, focus: vec2(0.5, 0.5),
            spawn: Ring, spread: 120.0, life: vec2(1.5, 5.0),
            key: ColorKey{age: 1.0, seed: 0.1},
            zoom: 1.001, spin: 0.0, glow: 0.7, stars: 0.5, vignette: 0.8, moon: 119.0, ridge: 0.0,
        },
        // dust and gas in drifting clouds, slowly turning, under stars
        Preset{
            name: "Nebula", mode: Light,
            ramp: [5]u32{rgb(20, 40, 130), rgb(60, 110, 215), rgb(190, 60, 170), rgb(255, 140, 120), rgb(120, 220, 255)},
            top: rgb(3, 3, 12), bottom: rgb(7, 4, 15), hud: rgb(220, 185, 240),
            count: 36000, width: 2.0, alpha: 0.03, trail: 1.4, fade_in: 0.4,
            feature: 480.0, stretch: 1.0, octaves: 3, warp: 1.2, evolve: 0.04, speed: 55.0,
            drift: vec2(0.0), swirl: 30.0, radial: 0.0, focus: vec2(0.5, 0.5),
            spawn: Clouds, spread: 0.0, life: vec2(3.0, 8.0),
            key: ColorKey{angle: 0.55, phase: 0.6, y: 0.35, speed: 0.15},
            zoom: 1.0, spin: 0.0003, glow: 0.7, stars: 1.0, vignette: 0.9, moon: 0.0, ridge: 0.0,
        },
        // long smooth threads with a sheen that turns with their direction
        Preset{
            name: "Silk", mode: Light,
            ramp: [5]u32{rgb(36, 26, 60), rgb(120, 70, 140), rgb(185, 120, 150), rgb(235, 185, 170), rgb(245, 220, 200)},
            top: rgb(13, 11, 16), bottom: rgb(22, 17, 23), hud: rgb(240, 222, 228),
            count: 60000, width: 1.0, alpha: 0.055, trail: 0.7, fade_in: 0.5,
            feature: 520.0, stretch: 1.0, octaves: 1, warp: 0.3, evolve: 0.05, speed: 90.0,
            drift: vec2(0.0), swirl: 0.0, radial: 0.0, focus: vec2(0.5, 0.5),
            spawn: Anywhere, spread: 0.0, life: vec2(6.0, 12.0),
            key: ColorKey{angle: 0.9, seed: 0.1},
            zoom: 1.0, spin: 0.0, glow: 0.3, stars: 0.0, vignette: 0.8, moon: 0.0, ridge: 0.0,
        },
    }
}

// The numbers that drive the simulation and the renderer at one moment: a preset, or two
// presets mixed during a cross-fade.
struct Params {
    count: f32
    width: f32
    alpha: f32
    trail: f32
    fade_in: f32
    feature: f32
    stretch: f32
    octaves: f32
    warp: f32
    evolve: f32
    speed: f32
    drift: vec2
    swirl: f32
    radial: f32
    focus: vec2
    life: vec2
    key: ColorKey
    zoom: f32
    spin: f32
    glow: f32
    stars: f32
    vignette: f32
    moon: f32           // opacity of the disc
    moon_r: f32         // and its radius
    ridge: f32
    top: vec4           // ground colours, 0..1
    bottom: vec4
    hud: vec4
    ink: f32            // 0: Light, 1: Ink
}

fn params_of(p: Preset) -> Params {
    Params{
        count: f32(p.count), width: p.width, alpha: p.alpha, trail: p.trail, fade_in: p.fade_in,
        feature: p.feature, stretch: p.stretch, octaves: f32(p.octaves), warp: p.warp,
        evolve: p.evolve, speed: p.speed, drift: p.drift, swirl: p.swirl, radial: p.radial,
        focus: p.focus, life: p.life, key: p.key, zoom: p.zoom, spin: p.spin, glow: p.glow,
        stars: p.stars, vignette: p.vignette, moon: if p.moon > 0.0 { 1.0 } else { 0.0 }, moon_r: p.moon, ridge: p.ridge, top: color_vec4(p.top), bottom: color_vec4(p.bottom),
        hud: color_vec4(p.hud), ink: if p.mode == Ink { 1.0 } else { 0.0 },
    }
}

priv fn mix(a: f32, b: f32, t: f32) -> f32 { a + (b - a) * t }

priv fn mix(a: ColorKey, b: ColorKey, t: f32) -> ColorKey {
    ColorKey{
        speed: mix(a.speed, b.speed, t), angle: mix(a.angle, b.angle, t), phase: mix(a.phase, b.phase, t),
        age: mix(a.age, b.age, t), y: mix(a.y, b.y, t), seed: mix(a.seed, b.seed, t), base: mix(a.base, b.base, t),
    }
}

// a and b mixed: t = 0 is a, 1 is b.
fn mix_params(a: Params, b: Params, t: f32) -> Params {
    Params{
        count: mix(a.count, b.count, t), width: mix(a.width, b.width, t), alpha: mix(a.alpha, b.alpha, t),
        trail: mix(a.trail, b.trail, t), fade_in: mix(a.fade_in, b.fade_in, t),
        feature: mix(a.feature, b.feature, t), stretch: mix(a.stretch, b.stretch, t),
        octaves: mix(a.octaves, b.octaves, t), warp: mix(a.warp, b.warp, t),
        evolve: mix(a.evolve, b.evolve, t), speed: mix(a.speed, b.speed, t),
        drift: lerp(a.drift, b.drift, t), swirl: mix(a.swirl, b.swirl, t), radial: mix(a.radial, b.radial, t),
        focus: lerp(a.focus, b.focus, t), life: lerp(a.life, b.life, t), key: mix(a.key, b.key, t),
        zoom: mix(a.zoom, b.zoom, t), spin: mix(a.spin, b.spin, t), glow: mix(a.glow, b.glow, t),
        stars: mix(a.stars, b.stars, t), vignette: mix(a.vignette, b.vignette, t), moon: mix(a.moon, b.moon, t),
        ridge: mix(a.ridge, b.ridge, t),
        moon_r: if a.moon_r == 0.0 { b.moon_r } else if b.moon_r == 0.0 { a.moon_r } else { mix(a.moon_r, b.moon_r, t) },
        top: lerp(a.top, b.top, t), bottom: lerp(a.bottom, b.bottom, t), hud: lerp(a.hud, b.hud, t),
        ink: mix(a.ink, b.ink, t),
    }
}

const LUT_SIZE = 256

// The ramp of a preset as LUT_SIZE colours (alpha 0: the alpha byte is filled in per segment).
fn ramp_lut(p: Preset, out: []u32) {
    for i in 0..LUT_SIZE {
        x := f32(i) / f32(LUT_SIZE - 1) * 4.0
        k := min(i64(x), 3)
        c := lerp(color_vec4(p.ramp[k]), color_vec4(p.ramp[k + 1]), smoothstep(0.0, 1.0, x - f32(k)))
        out[i] = color_u32(vec4(c.x, c.y, c.z, 0.0))
    }
}

// Two LUTs mixed into `out`.
fn mix_lut(a: []u32, b: []u32, t: f32, out: []u32) {
    for i in 0..LUT_SIZE {
        out[i] = color_u32(lerp(color_vec4(a[i]), color_vec4(b[i]), t))
    }
}

// An RGBA8 colour (red in the lowest byte, as std.gfx takes it). (std.math's rgb8 / rgba8
// do the same in newer compilers.)
fn rgba(r: u8, g: u8, b: u8, a: u8) -> u32 { u32(r) | u32(g) << 8 | u32(b) << 16 | u32(a) << 24 }

fn rgb(r: u8, g: u8, b: u8) -> u32 { rgba(r, g, b, 255) }
