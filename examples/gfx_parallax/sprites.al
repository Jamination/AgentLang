// Sprites drawn pixel by pixel at start-up: the ground tiles (auto-tiled edges, dithered depth
// bands), the wanderer's sprite sheet (idle, run and jump frames posed from a little skeleton,
// then shaded and outlined), the moon, and a coverage atlas of glows, the sun's disc, birds and
// the dither ramps the sky and the haze are blended with.
use std.image

fn pset(img: *Image, x: i64, y: i64, c: u32) {
    if x >= 0 && y >= 0 && x < img.w && y < img.h {
        img.set(x, y, vec4(rgb(c), 1.0))
    }
}

// ---- ground tiles

const TILE = 8
const TILE_CELL_H = 12            // a tile with 4 rows above it for the grass that pokes up
const TILE_COLS = 12

// The index of a tile in the atlas. Surface tiles (grass on top) come in 3 variants, the earth
// below in 4 depth bands of 4 variants; `left` / `right` say the side is open (a cliff face).
fn tile_index(surface: bool, depth: i64, left: bool, right: bool, variant: i64) -> i64 {
    sides := (if left { 1 } else { 0 }) + (if right { 2 } else { 0 })
    if surface {
        return sides + 4 * (variant % 3)
    }
    12 + min(depth, 3) * 16 + sides + 4 * (variant % 4)
}

fn tile_src(i: i64) -> vec4 {
    vec4(f32((i % TILE_COLS) * TILE), f32((i / TILE_COLS) * TILE_CELL_H), f32(TILE), f32(TILE_CELL_H))
}

priv const GRASS = [_]u32{0xb4e05a, 0x7cc048, 0x4c9a44, 0x2e7040, 0x1e4c36}
priv const EARTH = [_]u32{0x8a5a3a, 0x6e4430, 0x56342a, 0x422626, 0x301c22, 0x22141c}
priv const STONE_HI: u32 = 0x8e7c70
priv const STONE: u32 = 0x5e4e4a

fn make_tiles() -> Image {
    img := image_new(TILE_COLS * TILE, 7 * TILE_CELL_H, 4)
    for i in 0..76 {
        ox := (i % TILE_COLS) * TILE
        oy := (i / TILE_COLS) * TILE_CELL_H + 4
        surface := i < 12
        left := i % 4 == 1 || i % 4 == 3
        right := i % 4 >= 2
        depth := if surface { 0 } else { (i - 12) / 16 }
        variant := if surface { (i % 12) / 4 } else { ((i - 12) % 16) / 4 }
        seed := u32(i * 131 + 7)
        // earth: the colour of the depth band, frayed into the band above at the top
        for y in 0..TILE {
            for x in 0..TILE {
                band := depth + 1
                fray := noise_hash(x, y, variant, seed + 3) % 3
                if !surface && (y == 0 && fray != 0 || y == 1 && fray == 0) {
                    band -= 1
                }
                c := EARTH[band]
                h := noise_hash(x, y, variant, seed) % 100
                if h < 5 {
                    c = EARTH[min(band + 1, 5)]           // dark specks
                } else if h < 7 {
                    c = EARTH[max(band - 1, 0)]           // light grains
                }
                pset(&img, ox + x, oy + y, c)
            }
        }
        // now and then a pebble, or a root hanging from the grass
        if !surface && depth < 2 && variant == 3 {
            rx := 2 + i64(seed % 4)
            for y in 0..5 - depth * 2 {
                pset(&img, ox + rx + (y / 2) % 2, oy + y, EARTH[min(depth + 3, 5)])
            }
        }
        for k in 0..1 {
            hsh := noise_hash(k, variant, depth, seed + 5)
            if hsh % 4 != 0 || variant == 3 {
                continue
            }
            px := ox + 1 + i64(hsh % 5)
            py := oy + (if surface { 4 } else { 1 }) + i64((hsh / 7) % 3)
            pset(&img, px, py, STONE_HI)
            pset(&img, px + 1, py, STONE)
            pset(&img, px, py + 1, STONE)
            pset(&img, px + 1, py + 1, EARTH[min(depth + 3, 5)])
        }
        if surface {
            for x in 0..TILE {
                fringe := 3 + i64(noise_hash(x, variant, 1, seed) % 3)        // grass hangs 3..5 rows
                for y in 0..fringe {
                    shade := if y == 0 { 0 } else if y == 1 { 1 } else if y < fringe - 1 { 2 } else { 3 }
                    if y == 0 && bayer(x + variant, y) > 0.6 {
                        shade = 1
                    }
                    pset(&img, ox + x, oy + y, GRASS[shade])
                }
                pset(&img, ox + x, oy + fringe, EARTH[4])                       // the shadow under the lip
                // blades above the tile
                hb := noise_hash(x, variant, 2, seed) % 7
                if hb < 3 {
                    pset(&img, ox + x, oy - 1, GRASS[if hb == 0 { 0 } else { 1 }])
                    if hb == 0 {
                        pset(&img, ox + x, oy - 2, GRASS[1])
                    }
                }
            }
        }
        // open sides: a dark edge, grass wrapping over the corner
        for side in 0..2 {
            open := if side == 0 { left } else { right }
            if !open {
                continue
            }
            ex := if side == 0 { 0 } else { TILE - 1 }
            ix := if side == 0 { 1 } else { TILE - 2 }
            for y in 0..TILE {
                pset(&img, ox + ex, oy + y, EARTH[5])
                if y % 3 != 1 {
                    pset(&img, ox + ix, oy + y, EARTH[min(depth + 3, 5)])
                }
            }
            if surface {
                for y in 0..5 {
                    pset(&img, ox + ex, oy + y, GRASS[if y < 2 { 2 } else { 3 }])
                }
                img.set(ox + ex, oy - 1, vec4(0.0))
                pset(&img, ox + ex, oy + 5, GRASS[4])
            }
        }
    }
    img
}

// ---- the wanderer

const HERO_W = 16
const HERO_H = 22
const IDLE_FRAMES = 4
const RUN_FRAMES = 8
const JUMP_FRAMES = 3

// Parts of the figure, in the order they are drawn (later parts cover earlier ones).
priv const P_ARM_B = 1
priv const P_LEG_B = 2
priv const P_BOOT_B = 3
priv const P_PACK = 4
priv const P_BODY = 5
priv const P_BELT = 6
priv const P_LEG_F = 7
priv const P_BOOT_F = 8
priv const P_HEAD = 9
priv const P_HAIR = 10
priv const P_SCARF = 11
priv const P_ARM_F = 12
priv const P_EYE = 13
priv const P_COUNT = 14

// highlight, base, shadow of each part (index = part)
priv const HERO_COLS = [_]u32{
    0, 0, 0,
    0xe0a080, 0xb87060, 0x8a4c4c,          // back arm (in the body's shadow)
    0x3e3a62, 0x2e2a4e, 0x221e3a,          // back leg
    0x704428, 0x4e2e20, 0x38201a,          // back boot
    0xc89a5c, 0x946a3e, 0x644228,          // pack
    0x72c4dc, 0x3a8cb4, 0x285a8a,          // tunic
    0xd8a048, 0x6a3e26, 0x4a2a1e,          // belt
    0x5e588a, 0x423e68, 0x2c284a,          // front leg
    0xa86e42, 0x744628, 0x4a2a1e,          // front boot
    0xffdcb4, 0xf2b088, 0xc47a66,          // head
    0x8e4c2c, 0x622e22, 0x401c1e,          // hair
    0xff8c5c, 0xe4463c, 0xa0283a,          // scarf
    0xffdcb4, 0xf2b088, 0xc47a66,          // front arm
    0x1e1226, 0x1e1226, 0x1e1226,          // eye
}
priv const OUTLINE: u32 = 0x1e1226

struct Pose {
    bob: f32         // the hip moves down by this (pixels)
    lean: f32        // the neck is this far ahead of the hip
    leg_f: f32       // thigh angles from straight down, forward positive (radians)
    leg_b: f32
    knee_f: f32      // how far the shin bends back from the thigh
    knee_b: f32
    arm_f: f32
    arm_b: f32
    scarf: f32       // phase of the scarf's wave
    lift: f32        // how much the scarf streams up (running, falling)
}

priv struct Canvas { ids: [HERO_W * HERO_H]u8 }

priv fn dot_at(c: *Canvas, p: vec2, r: f32, id: u8) {
    for y in 0..HERO_H {
        for x in 0..HERO_W {
            if length(vec2(f32(x) + 0.5, f32(y) + 0.5) - p) <= r {
                c.ids[y * HERO_W + x] = id
            }
        }
    }
}

priv fn seg(c: *Canvas, a: vec2, b: vec2, r: f32, id: u8) {
    for k in 0..=12 {
        dot_at(c, lerp(a, b, f32(k) / 12.0), r, id)
    }
}

priv fn leg(c: *Canvas, hip: vec2, a: f32, knee: f32, id: u8, boot: u8) {
    k := hip + vec2(sin(a), cos(a)) * 3.6
    f := k + vec2(sin(a - knee), cos(a - knee)) * 3.6
    seg(c, hip, k, 1.05, id)
    seg(c, k, f, 1.0, id)
    seg(c, f + vec2(-0.3, -0.6), f + vec2(1.6, 0.2), 0.95, boot)
}

priv fn arm(c: *Canvas, shoulder: vec2, a: f32, id: u8) {
    e := shoulder + vec2(sin(a), cos(a)) * 2.8
    h := e + vec2(sin(a + 0.7), cos(a + 0.7)) * 2.6
    seg(c, shoulder, e, 0.85, id)
    seg(c, e, h, 0.8, id)
}

priv fn draw_pose(img: *Image, ox: i64, oy: i64, p: Pose) {
    c: Canvas
    hip := vec2(8.5, 13.6 + p.bob)
    neck := hip + vec2(p.lean, -5.2)
    head := neck + vec2(0.6, -3.3)
    shoulder := neck + vec2(-0.2, 1.0)
    arm(&c, shoulder + vec2(0.6, 0.0), p.arm_b, P_ARM_B)
    leg(&c, hip + vec2(0.6, 0.0), p.leg_b, p.knee_b, P_LEG_B, P_BOOT_B)
    seg(&c, neck + vec2(-2.4, 1.6), neck + vec2(-2.6, 4.0), 1.5, P_PACK)        // pack on the back
    seg(&c, hip + vec2(0.0, 0.5), neck + vec2(0.0, 0.8), 2.1, P_BODY)
    seg(&c, hip + vec2(-1.6, 0.4), hip + vec2(1.6, 0.4), 0.6, P_BELT)
    leg(&c, hip + vec2(-0.4, 0.0), p.leg_f, p.knee_f, P_LEG_F, P_BOOT_F)
    dot_at(&c, head, 3.2, P_HEAD)
    // hair: the back and the top of the head
    for y in 0..HERO_H {
        for x in 0..HERO_W {
            q := vec2(f32(x) + 0.5, f32(y) + 0.5) - head
            if length(q) <= 3.6 && (q.y < -1.2 || q.x < -0.9 && q.y < 1.6) {
                c.ids[y * HERO_W + x] = P_HAIR
            }
        }
    }
    // the scarf: a band round the neck and two tails streaming back
    seg(&c, neck + vec2(-1.4, -0.2), neck + vec2(1.4, -0.2), 0.9, P_SCARF)
    prev := neck + vec2(-1.2, 0.0)
    for i in 1..5 {
        fi := f32(i)
        pt := neck + vec2(-1.2 - fi * 1.05, sin(p.scarf + fi * 0.9) * 0.28 * fi - p.lift * fi * 0.32 + fi * 0.18)
        seg(&c, prev, pt, if i < 3 { 0.8 } else { 0.6 }, P_SCARF)
        prev = pt
    }
    arm(&c, shoulder + vec2(-0.6, 0.2), p.arm_f, P_ARM_F)
    eye := head + vec2(1.6, 0.0)
    c.ids[i64(eye.y) * HERO_W + i64(eye.x)] = P_EYE
    // colour: highlight where the part ends to the upper left, shadow to the lower right
    for y in 0..HERO_H {
        for x in 0..HERO_W {
            id := c.ids[y * HERO_W + x]
            if id == 0 {
                touches := false
                for d in [_](i64, i64){(1, 0), (-1, 0), (0, 1), (0, -1)} {
                    xx := x + d.0
                    yy := y + d.1
                    if xx >= 0 && yy >= 0 && xx < HERO_W && yy < HERO_H && c.ids[yy * HERO_W + xx] != 0 {
                        touches = true
                    }
                }
                if touches {
                    pset(img, ox + x, oy + y, OUTLINE)
                }
                continue
            }
            fn same(c: *Canvas, x: i64, y: i64, id: u8) -> bool {
                x >= 0 && y >= 0 && x < HERO_W && y < HERO_H && c.ids[y * HERO_W + x] == id
            }
            tone := 1
            if !same(&c, x, y - 1, id) || !same(&c, x - 1, y, id) && !same(&c, x - 1, y - 1, id) {
                tone = 0
            } else if !same(&c, x, y + 1, id) || !same(&c, x + 1, y, id) {
                tone = 2
            }
            pset(img, ox + x, oy + y, HERO_COLS[i64(id) * 3 + tone])
        }
    }
}

// The sheet: a row of idle frames, a row of run frames, a row of jump frames (rising, at the
// top, falling).
fn make_hero() -> Image {
    img := image_new(RUN_FRAMES * HERO_W, 3 * HERO_H, 4)
    for k in 0..IDLE_FRAMES {
        ph := f32(k) / f32(IDLE_FRAMES) * TAU
        breathe := if k >= 2 { 1.0 } else { 0.0 }
        draw_pose(&img, k * HERO_W, 0, Pose{bob: breathe * 0.6, lean: 0.4, leg_f: 0.1, leg_b: -0.12, knee_f: 0.1,
            knee_b: 0.1, arm_f: 0.25 - breathe * 0.1, arm_b: -0.2, scarf: ph, lift: -0.3})
    }
    for k in 0..RUN_FRAMES {
        ph := f32(k) / f32(RUN_FRAMES) * TAU
        s := sin(ph)
        draw_pose(&img, k * HERO_W, HERO_H, Pose{bob: fabs(s) * 1.1 - 0.4, lean: 1.4,
            leg_f: s * 0.95, leg_b: -s * 0.95, knee_f: fmax(0.0, -cos(ph)) * 1.4 + 0.25,
            knee_b: fmax(0.0, cos(ph)) * 1.4 + 0.25, arm_f: -s * 1.0 + 0.2, arm_b: s * 1.0 + 0.2,
            scarf: ph * 2.0, lift: 0.5})
    }
    poses := [_]Pose{
        Pose{bob: -0.6, lean: 1.0, leg_f: 1.0, leg_b: -0.5, knee_f: 1.5, knee_b: 0.7, arm_f: 2.5, arm_b: -0.7, scarf: 1.0, lift: -0.6},
        Pose{bob: -0.4, lean: 0.8, leg_f: 0.7, leg_b: 0.2, knee_f: 1.6, knee_b: 1.4, arm_f: 1.4, arm_b: 0.9, scarf: 2.0, lift: 0.3},
        Pose{bob: 0.0, lean: 0.5, leg_f: 0.35, leg_b: -0.3, knee_f: 0.3, knee_b: 0.5, arm_f: 2.2, arm_b: 1.8, scarf: 3.0, lift: 1.4},
    }
    for k in 0..JUMP_FRAMES {
        draw_pose(&img, k * HERO_W, 2 * HERO_H, poses[k])
    }
    img
}

// ---- the moon: a gibbous disc with craters

const MOON_SIZE = 15

fn make_moon() -> Image {
    img := image_new(MOON_SIZE, MOON_SIZE, 4)
    c := f32(MOON_SIZE) * 0.5
    for y in 0..MOON_SIZE {
        for x in 0..MOON_SIZE {
            q := vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c)
            if length(q) > 6.6 {
                continue
            }
            mc: u32 = 0xf4f0dc
            crater := noise2(f32(x) * 0.42, f32(y) * 0.42, 41)
            if crater > 0.22 {
                mc = 0xc8c4bc
            } else if crater > 0.12 {
                mc = 0xdcd8cc
            }
            // the shadowed limb
            sh := length(q - vec2(-3.4, -1.0))
            if sh > 8.0 || sh > 7.2 && bayer(x, y) > 0.5 {
                mc = if crater > 0.12 { 0x5a5a7a } else { 0x6e6e8c }
            }
            pset(&img, x, y, mc)
        }
    }
    img
}

// ---- the coverage atlas

const MISC_W = 512
const MISC_H = 128
const GLOW_BIG = 96              // (0, 0): a big glow, 96 x 96
const GLOW_SMALL = 15            // (96, 0): a small glow, 15 x 15
const DISC_SIZE = 13             // (96, 16): a disc (the sun)
const BIRD_W = 7                 // (96, 32): birds, 3 frames of 7 x 5
const BIRD_H = 5
const RAMP16_Y = 96              // rows 96..111: a dither ramp from 1/32 to 31/32
const RAMP4_Y = 112              // rows 112..115: a dither ramp from 1/5 to 4/5 coverage
const RAMP8_Y = 116              // rows 116..123: a dither ramp from 1/16 to 15/16

// A glow in banded steps: 4 levels of coverage with dithered boundaries, so that even the
// soft light of the sun keeps to the pixel grid.
priv fn glow(img: *Image, ox: i64, oy: i64, size: i64, falloff: f32) {
    c := f32(size) * 0.5
    for y in 0..size {
        for x in 0..size {
            r := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c)) / c
            v := pow(fmax(0.0, 1.0 - r), falloff)
            level := floor(v * 4.0 + bayer(x, y) - 0.5)
            img.set(ox + x, oy + y, 0, u8(clamp(level, 0.0, 4.0) * 63.0))
        }
    }
}

priv const BIRD_FRAMES = `
.......
#.....#
.#...#.
..#.#..
...#...
.......
.......
#.....#
.##.##.
...#...
.......
.......
.......
.#####.
#..#..#
`

fn make_misc() -> Image {
    img := image_new(MISC_W, MISC_H, 1)
    glow(&img, 0, 0, GLOW_BIG, 2.2)
    glow(&img, 96, 0, GLOW_SMALL, 1.6)
    c := f32(DISC_SIZE) * 0.5
    for y in 0..DISC_SIZE {
        for x in 0..DISC_SIZE {
            if length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c)) <= c - 0.2 {
                img.set(96 + x, 16 + y, 0, 255)
            }
        }
    }
    rows := lines(trim(BIRD_FRAMES))
    for i, row in rows {
        f := i64(i) / BIRD_H
        for x in 0..min(len(row), BIRD_W) {
            if row[x] == '#' {
                img.set(96 + f * BIRD_W + x, 32 + i64(i) % BIRD_H, 0, 255)
            }
        }
    }
    for x in 0..MISC_W {
        for r in 0..4 {
            if bayer(x, r) < (f32(r) + 1.0) / 5.0 {
                img.set(x, RAMP4_Y + r, 0, 255)
            }
        }
        for r in 0..8 {
            if bayer(x, r) < (f32(r) + 0.5) / 8.0 {
                img.set(x, RAMP8_Y + r, 0, 255)
            }
        }
        for r in 0..16 {
            if bayer(x, r) < (f32(r) + 0.5) / 16.0 {
                img.set(x, RAMP16_Y + r, 0, 255)
            }
        }
    }
    img
}
