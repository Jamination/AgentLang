// Draws tiles.png, the sprite sheet of the breakout example (the game embeds the file and
// decodes it with std.image). Run it from the repository root after changing the art:
//   alc run examples/dx12_breakout/make_tiles.al
// Everything is computed per texel from signed distances, so every edge is anti-aliased; the
// layout (and the colours of the rows of bricks) is in sheet.al. The letters are not here: the
// game makes them at start-up from a system font (glyphs.al).
use std.image
use "sheet.al"

// ---- painting helpers ------------------------------------------------------------------------

// Lays colour c (straight alpha) over the texel at (x, y).
fn over(img: *Image, x: i64, y: i64, c: vec4) {
    if c.a <= 0.0 {
        return
    }
    d := img.get(x, y)
    a := c.a + d.a * (1.0 - c.a)
    rgb := (c.xyz * c.a + d.xyz * (d.a * (1.0 - c.a))) / fmax(a, 0.0001)
    img.set(x, y, vec4(rgb, fmin(a, 1.0)))
}

// The signed distance from p to a box of half size `half` with corners rounded by r
// (negative inside).
fn sd_box(p: vec2, half: vec2, r: f32) -> f32 {
    q := abs(p) - half + vec2(r)
    length(max(q, vec2(0.0))) + fmin(fmax(q.x, q.y), 0.0) - r
}

// The distance from p to the segment a..b.
fn sd_segment(p: vec2, a: vec2, b: vec2) -> f32 {
    ab := b - a
    t := clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0)
    length(p - (a + ab * t))
}

// How much of a texel at signed distance d (texels) is inside.
fn cover(d: f32) -> f32 { clamp(0.5 - d, 0.0, 1.0) }

// The outward direction of a rounded box's edge nearest to p.
fn box_normal(p: vec2, half: vec2, r: f32) -> vec2 {
    e: f32 = 0.5
    dx := sd_box(p + vec2(e, 0.0), half, r) - sd_box(p - vec2(e, 0.0), half, r)
    dy := sd_box(p + vec2(0.0, e), half, r) - sd_box(p - vec2(0.0, e), half, r)
    v := vec2(dx, dy)
    if length(v) < 0.0001 { vec2(0.0, -1.0) } else { normalize(v) }
}

fn white(a: f32) -> vec4 { vec4(1.0, 1.0, 1.0, a) }

// A texel centre relative to the centre of a tile.
fn local(t: Tile, x: i64, y: i64) -> vec2 {
    vec2(f32(x) + 0.5 - t.w / 2.0, f32(y) + 0.5 - t.h / 2.0)
}

// The light comes from the top left, a little in front.
const LIGHT2 = vec2(-0.33, -0.94)

// ---- bricks ----------------------------------------------------------------------------------

const BRICK_HALF = vec2(46.0, 14.0)      // the body: 23 x 7 view pixels
const BRICK_R: f32 = 6.0

fn draw_brick(img: *Image, row: i64) {
    t := tile_brick(row)
    light := brick_light(row)
    base := brick_base(row)
    shadow := brick_shadow(row)
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, BRICK_HALF, BRICK_R)
            // a thin dark contour first: crisp seams on any background
            if d > -0.5 && d < 2.5 {
                over(img, i64(t.x) + x, i64(t.y) + y, vec4(0.02, 0.0, 0.05, 0.6 * clamp(1.0 - d / 2.5, 0.0, 1.0)))
            }
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            v := (p.y + BRICK_HALF.y) / (2.0 * BRICK_HALF.y)
            u := (p.x + BRICK_HALF.x) / (2.0 * BRICK_HALF.x)
            // the body: light above, the colour itself, deep shade below
            col := if v < 0.42 { lerp(lerp(base, light, 0.55), base, v / 0.42) } else { lerp(base, lerp(base, shadow, 0.8), (v - 0.42) / 0.58) }
            // the bevel: a 4 texel rim lit from the top left
            e := -d
            if e < 4.5 {
                k := dot(box_normal(p, BRICK_HALF, BRICK_R), LIGHT2) * (1.0 - e / 4.5)
                col = if k > 0.0 { lerp(col, lerp(light, vec3(1.0), 0.45), k * 0.9) } else { lerp(col, shadow * 0.55, -k * 0.85) }
            }
            // reflected light along the bottom inside the rim
            rim := smoothstep(0.62, 0.88, v) * (1.0 - smoothstep(0.88, 0.97, v)) * smoothstep(0.03, 0.15, u) * (1.0 - smoothstep(0.85, 0.97, u))
            col = col + base * (0.28 * rim)
            // the glossy band and a hot spot
            gloss := smoothstep(0.10, 0.17, v) * (1.0 - smoothstep(0.30, 0.44, v)) * smoothstep(0.04, 0.16, u) * (1.0 - smoothstep(0.84, 0.96, u))
            col = lerp(col, vec3(1.0), gloss * 0.42)
            spot := exp(-((u - 0.2) * (u - 0.2) / 0.006 + (v - 0.24) * (v - 0.24) / 0.004))
            col = col + vec3(spot * 0.45)
            // a faint grain
            col = col * (0.97 + 0.06 * noise2(f32(x) * 0.7, f32(y) * 0.35 + f32(row) * 13.0))
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(clamp(col, vec3(0.0), vec3(1.0)), c))
        }
    }
}

// A steel frame with rivets over the brick: the armour of a brick with three hit points.
fn draw_armour(img: *Image) {
    t := TILE_ARMOUR
    rivets := [_]vec2{vec2(-43.0, 0.0), vec2(43.0, 0.0), vec2(-22.0, -11.5), vec2(22.0, -11.5), vec2(-22.0, 11.5), vec2(22.0, 11.5)}
    inner_half := BRICK_HALF - vec2(5.5, 5.0)
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, BRICK_HALF - vec2(0.5), BRICK_R)
            di := sd_box(p, inner_half, 2.0)
            c := cover(d) * cover(-di)                     // between the edge and the window
            v := (p.y + BRICK_HALF.y) / (2.0 * BRICK_HALF.y)
            steel := lerp(vec3(0.70, 0.72, 0.84), vec3(0.16, 0.16, 0.24), v)
            steel = steel * (0.9 + 0.12 * noise2(f32(x) * 0.15, f32(y) * 1.7))   // brushed
            if c > 0.0 {
                col := steel
                // the outer rim lit from the top left, the window's rim the other way round
                e := -d
                if e < 2.5 {
                    k := dot(box_normal(p, BRICK_HALF, BRICK_R), LIGHT2) * (1.0 - e / 2.5)
                    col = if k > 0.0 { lerp(col, vec3(1.0), k * 0.8) } else { col * (1.0 + k * 0.6) }
                }
                if di < 2.0 {
                    k := dot(box_normal(p, inner_half, 2.0), LIGHT2) * (1.0 - di / 2.0)
                    col = if k > 0.0 { col * (1.0 - k * 0.6) } else { lerp(col, vec3(1.0), -k * 0.7) }
                }
                over(img, i64(t.x) + x, i64(t.y) + y, vec4(clamp(col, vec3(0.0), vec3(1.0)), c))
            }
            // the shadow the frame casts into the window
            if di > -3.0 && di < 0.5 && d < 0.0 {
                over(img, i64(t.x) + x, i64(t.y) + y, vec4(0.0, 0.0, 0.05, 0.35 * clamp((di + 3.0) / 3.0, 0.0, 1.0)))
            }
            for r in rivets {
                q := p - r
                rd := length(q) - 2.0
                rc := cover(rd * 1.5)
                if rc > 0.0 {
                    n := q / 2.0
                    lit := clamp(0.55 - 0.6 * dot(n, vec2(0.6, 0.8)), 0.0, 1.0)
                    col := lerp(vec3(0.25, 0.26, 0.34), vec3(1.0), lit)
                    over(img, i64(t.x) + x, i64(t.y) + y, vec4(col, rc))
                }
            }
        }
    }
}

// A crack: dark, with a lit lip along one side, clipped to the brick.
fn draw_crack(img: *Image, t: Tile, pts: []vec2, width: f32) {
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            inside := cover(sd_box(p, BRICK_HALF - vec2(1.0), BRICK_R))
            if inside <= 0.0 {
                continue
            }
            d: f32 = 1000.0
            lip: f32 = 1000.0
            for i in 0..len(pts) - 1 {
                if pts[i + 1].x > 900.0 || pts[i].x > 900.0 {
                    continue                        // a break between two polylines
                }
                w := width * (1.0 - 0.5 * f32(i) / f32(len(pts)))
                d = fmin(d, sd_segment(p, pts[i], pts[i + 1]) - w)
                lip = fmin(lip, sd_segment(p - vec2(0.6, 1.3), pts[i], pts[i + 1]) - w * 0.6)
            }
            tx := i64(t.x) + x
            ty := i64(t.y) + y
            if lip < 1.0 {
                over(img, tx, ty, white(0.55 * cover(lip) * inside))
            }
            if d < 1.0 {
                over(img, tx, ty, vec4(0.03, 0.0, 0.06, 0.92 * cover(d) * inside))
            }
            // the glass around a crack is a little darker
            if d < 4.0 {
                over(img, tx, ty, vec4(0.0, 0.0, 0.0, 0.18 * (1.0 - fmax(d, 0.0) / 4.0) * inside))
            }
        }
    }
}

const GAP = vec2(1000.0, 1000.0)          // separates the polylines of a crack

// ---- paddle and ball -------------------------------------------------------------------------

fn draw_paddle(img: *Image) {
    t := TILE_PADDLE
    half := vec2(72.0, 12.0)
    lv := normalize(vec3(-0.3, -0.75, 0.6))
    hv := normalize(lv + vec3(0.0, 0.0, 1.0))
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, half, 12.0)
            tx := i64(t.x) + x
            ty := i64(t.y) + y
            if d > -0.5 && d < 3.0 {
                over(img, tx, ty, vec4(0.0, 0.0, 0.04, 0.55 * clamp(1.0 - d / 3.0, 0.0, 1.0)))
            }
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            ax := fabs(p.x)
            cap := ax > 51.0
            // a cylinder along x; the caps are rounded in x as well
            qx := if cap { fmax(ax - 60.0, 0.0) / 12.0 * sign(p.x) } else { 0.0 }
            qy := clamp(p.y / 12.0, -1.0, 1.0)
            n := vec3(qx, qy, sqrt(fmax(1.0 - qx * qx - qy * qy, 0.0)))
            diff := fmax(dot(n, lv), 0.0)
            spec := pow(fmax(dot(n, hv), 0.0), 40.0)
            col: vec3
            if cap {
                // hot magenta glass with an orange heart
                heart := exp(-((ax - 62.0) * (ax - 62.0) + p.y * p.y) / 40.0)
                col = lerp(vec3(0.45, 0.02, 0.28), vec3(1.0, 0.25, 0.62), 0.25 + 0.75 * diff)
                col = lerp(col, vec3(1.0, 0.72, 0.35), heart * 0.8)
                col = col + vec3(spec * 0.9)
            } else {
                // gunmetal, with the cyan light strip along the middle
                col = lerp(vec3(0.04, 0.04, 0.09), vec3(0.42, 0.45, 0.60), diff * diff)
                col = col + vec3(spec * 0.8)
                strip := exp(-p.y * p.y / 1.6) * smoothstep(48.0, 44.0, ax)
                halo := exp(-p.y * p.y / 10.0) * smoothstep(50.0, 40.0, ax)
                col = col + vec3(0.25, 0.85, 1.0) * (0.35 * halo) + vec3(0.7, 1.0, 1.0) * strip
            }
            // the grooves between body and caps
            g := fabs(ax - 51.0)
            if g < 1.6 {
                col = col * (0.25 + 0.75 * g / 1.6)
            }
            over(img, tx, ty, vec4(clamp(col, vec3(0.0), vec3(1.0)), c))
        }
    }
}

fn draw_ball(img: *Image) {
    t := TILE_BALL
    lv := normalize(vec3(-0.45, -0.6, 0.65))
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            r: f32 = 12.0
            d := length(p) - r
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            q := p / r
            n := vec3(q.x, q.y, sqrt(fmax(1.0 - dot(q, q), 0.0)))
            diff := fmax(dot(n, lv), 0.0)
            spec := pow(fmax(dot(n, normalize(lv + vec3(0.0, 0.0, 1.0))), 0.0), 30.0)
            col := lerp(vec3(0.35, 0.78, 1.0), vec3(1.0, 1.0, 1.0), smoothstep(0.1, 0.8, diff))
            col = col + vec3(spec)
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(clamp(col, vec3(0.0), vec3(1.0)), c))
        }
    }
}

// ---- light and particles ---------------------------------------------------------------------

fn draw_glow(img: *Image) {
    t := TILE_GLOW
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            r := length(local(t, x, y)) / (t.w / 2.0)
            a := (0.72 * exp(-r * r * 5.0) + 0.28 * exp(-r * r * 28.0)) * (1.0 - smoothstep(0.85, 1.0, r))
            over(img, i64(t.x) + x, i64(t.y) + y, white(a))
        }
    }
}

fn draw_flare(img: *Image) {
    t := TILE_FLARE
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            ax := fabs(p.x) / 32.0
            ay := fabs(p.y) / 32.0
            arms := exp(-p.y * p.y / 1.6) * pow(fmax(1.0 - ax, 0.0), 2.0) + exp(-p.x * p.x / 1.6) * pow(fmax(1.0 - ay, 0.0), 2.0)
            r := length(p) / 32.0
            core := exp(-r * r * 40.0) + 0.3 * exp(-r * r * 8.0) * (1.0 - smoothstep(0.8, 1.0, r))
            over(img, i64(t.x) + x, i64(t.y) + y, white(clamp(arms * 0.9 + core, 0.0, 1.0)))
        }
    }
}

// Splinters of glass: convex polygons with one lit and one dark edge (tinted by the game).
fn draw_shard(img: *Image, k: i64) {
    t := tile_shard(k)
    shapes := [SHARD_COUNT][4]vec2{
        [4]vec2{vec2(-9.0, -7.0), vec2(8.0, -4.0), vec2(-2.0, 9.0), vec2(-2.0, 9.0)},
        [4]vec2{vec2(-8.0, -3.0), vec2(2.0, -9.0), vec2(9.0, 4.0), vec2(-4.0, 7.0)},
        [4]vec2{vec2(-10.0, 2.0), vec2(9.0, -5.0), vec2(4.0, 5.0), vec2(4.0, 5.0)},
        [4]vec2{vec2(-5.0, -9.0), vec2(6.0, -6.0), vec2(4.0, 9.0), vec2(-7.0, 5.0)},
    }
    pts := shapes[k]
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d: f32 = -1000.0
            lit: f32 = 0.0
            for i in 0..4 {
                a := pts[i]
                b := pts[(i + 1) % 4]
                if length(b - a) < 0.01 {
                    continue
                }
                n := normalize(vec2(b.y - a.y, a.x - b.x))     // outward for clockwise points
                e := dot(p - a, n)
                if e > d {
                    d = e
                    lit = dot(n, LIGHT2)
                }
            }
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            edge := clamp(1.0 + d / 2.0, 0.0, 1.0)              // 1 at the edge, 0 two texels in
            col := vec3(0.82 + 0.18 * clamp(-p.y / 10.0, -1.0, 1.0))
            col = if lit > 0.0 { lerp(col, vec3(1.0), edge * lit) } else { col * (1.0 + edge * lit * 0.5) }
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(col, c))
        }
    }
}

fn draw_softbox(img: *Image) {
    t := TILE_SOFTBOX
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            d := fmax(sd_box(local(t, x, y), vec2(16.0, 2.0), 2.0), 0.0)
            a := exp(-d * d / 40.0) * (1.0 - smoothstep(10.0, 14.0, d))
            over(img, i64(t.x) + x, i64(t.y) + y, white(a))
        }
    }
}

fn draw_streak(img: *Image) {
    t := TILE_STREAK
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            a := exp(-(p.x * p.x / 300.0 + p.y * p.y / 5.0)) * 0.8 + exp(-(p.x * p.x / 50.0 + p.y * p.y / 1.2))
            a = a * (1.0 - smoothstep(26.0, 32.0, fabs(p.x)))
            over(img, i64(t.x) + x, i64(t.y) + y, white(clamp(a, 0.0, 1.0)))
        }
    }
}

// The beam and the rail are profiles across (y) and the same all along (x): the game stretches
// them over any length.
fn draw_beam(img: *Image) {
    t := TILE_BEAM
    for y in 0..i64(t.h) {
        q := f32(y) + 0.5 - t.h / 2.0
        a := clamp(exp(-q * q / 1.2) + 0.32 * exp(-q * q / 22.0) * (1.0 - smoothstep(12.0, 16.0, fabs(q))), 0.0, 1.0)
        for x in -4..4 {
            over(img, i64(t.x) + x, i64(t.y) + y, white(a))
        }
    }
}

fn draw_rail(img: *Image) {
    t := TILE_RAIL
    for y in 0..i64(t.h) {
        f := (f32(y) + 0.5) / t.h                          // 0 outside .. 1 at the field
        col: vec3
        if f < 0.08 {
            col = vec3(0.05, 0.05, 0.09)
        } else if f < 0.58 {
            // a rounded bar of metal with a highlight
            s := (f - 0.08) / 0.5
            col = lerp(vec3(0.20, 0.21, 0.32), vec3(0.58, 0.60, 0.76), sin(s * 3.1416) * 0.8)
            col = col + vec3(0.5 * exp(-(s - 0.28) * (s - 0.28) / 0.004))
        } else if f < 0.66 {
            col = vec3(0.02, 0.02, 0.05)                    // the groove
        } else if f < 0.92 {
            col = vec3(0.07, 0.05, 0.14)                    // the channel the neon tube sits in
        } else {
            col = vec3(0.42, 0.44, 0.60)                    // the lip
        }
        for x in -4..4 {
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0))
        }
    }
}

fn draw_corner(img: *Image) {
    t := TILE_CORNER
    half := vec2(14.0, 14.0)
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, half, 5.0)
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            v := (p.y + 14.0) / 28.0
            col := lerp(vec3(0.62, 0.64, 0.80), vec3(0.14, 0.14, 0.24), v)
            e := -d
            if e < 3.0 {
                k := dot(box_normal(p, half, 5.0), LIGHT2) * (1.0 - e / 3.0)
                col = if k > 0.0 { lerp(col, vec3(1.0), k * 0.7) } else { col * (1.0 + k * 0.7) }
            }
            // a jewel in the middle
            r := length(p)
            jewel := cover((r - 5.0) * 1.5)
            if jewel > 0.0 {
                jc := lerp(vec3(1.0, 0.3, 0.7), vec3(1.0, 0.85, 0.95), exp(-length(p + vec2(1.5, 1.5)) * 0.6))
                col = lerp(col * 0.4, jc, jewel)
            }
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(clamp(col, vec3(0.0), vec3(1.0)), c))
        }
    }
}

const PANEL_HALF = vec2(26.0, 26.0)
const PANEL_R: f32 = 10.0

fn draw_panel(img: *Image) {
    t := TILE_PANEL
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, PANEL_HALF, PANEL_R)
            c := cover(d)
            if c <= 0.0 {
                continue
            }
            v := (p.y + PANEL_HALF.y) / (2.0 * PANEL_HALF.y)
            // lighter towards the top (the slices of the middle are stretched: a soft gradient)
            g := 1.0 - 0.3 * v
            over(img, i64(t.x) + x, i64(t.y) + y, vec4(g, g, g, c))
        }
    }
}

fn draw_edge(img: *Image) {
    t := TILE_EDGE
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            p := local(t, x, y)
            d := sd_box(p, PANEL_HALF, PANEL_R) + 1.2
            line := cover(fabs(d) - 0.9)
            outer := if d > 0.0 { 0.45 * exp(-d * d / 8.0) } else { 0.22 * exp(-d * d / 14.0) }
            over(img, i64(t.x) + x, i64(t.y) + y, white(clamp(line + outer, 0.0, 1.0)))
        }
    }
}

fn draw_ring(img: *Image) {
    t := TILE_RING
    for y in 0..i64(t.h) {
        for x in 0..i64(t.w) {
            r := length(local(t, x, y))
            a := exp(-(r - 56.0) * (r - 56.0) / 5.0) + 0.3 * exp(-(r - 54.0) * (r - 54.0) / 60.0)
            a = a * (1.0 - smoothstep(61.0, 64.0, r))
            over(img, i64(t.x) + x, i64(t.y) + y, white(clamp(a, 0.0, 1.0)))
        }
    }
}

fn draw_white(img: *Image) {
    for y in 56..72 {
        for x in 496..512 {
            img.set(x, y, white(1.0))
        }
    }
}

fn main() {
    img := image_new(SHEET_W, SHEET_H, 4)
    for row in 0..6 {
        draw_brick(&img, row)
    }
    draw_armour(&img)
    crack1 := []vec2{vec2(-10.0, -14.5), vec2(-6.0, -8.0), vec2(-10.0, -2.0), vec2(-3.0, 3.0), vec2(-6.0, 9.0), GAP,
        vec2(-6.0, -8.0), vec2(1.0, -7.0), vec2(5.0, -10.0)}
    draw_crack(&img, TILE_CRACK1, crack1, 1.3)
    crack2 := []vec2{vec2(-10.0, -14.5), vec2(-6.0, -8.0), vec2(-10.0, -2.0), vec2(-3.0, 3.0), vec2(-6.0, 9.0), vec2(-2.0, 14.5), GAP,
        vec2(-6.0, -8.0), vec2(1.0, -7.0), vec2(5.0, -10.0), GAP,
        vec2(30.0, 14.5), vec2(24.0, 7.0), vec2(28.0, 1.0), vec2(19.0, -4.0), vec2(23.0, -10.0), GAP,
        vec2(24.0, 7.0), vec2(14.0, 9.0), GAP,
        vec2(-46.0, -6.0), vec2(-37.0, -3.0), vec2(-33.0, 4.0), vec2(-26.0, 6.0)}
    draw_crack(&img, TILE_CRACK2, crack2, 1.4)
    draw_paddle(&img)
    draw_ball(&img)
    draw_glow(&img)
    draw_flare(&img)
    for k in 0..SHARD_COUNT {
        draw_shard(&img, k)
    }
    draw_softbox(&img)
    draw_beam(&img)
    draw_streak(&img)
    draw_white(&img)
    draw_rail(&img)
    draw_corner(&img)
    draw_panel(&img)
    draw_edge(&img)
    draw_ring(&img)
    if !png_save("examples/dx12_breakout/tiles.png", img) {
        eprint("cannot write examples/dx12_breakout/tiles.png")
        exit(1)
    }
    print("wrote examples/dx12_breakout/tiles.png")
}
