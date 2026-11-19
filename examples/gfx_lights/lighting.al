// Shadow-casting lights for std.gfx, which blends only by alpha (src * a + dst * (1 - a)) and by
// adding (src * a + dst): there is no multiply blend and no shader of the program's own. How a
// coloured light still multiplies the albedo of a textured surface:
//
// 1. The light map. Each light is traced: rays from its centre to every corner of the
//    occluders in reach (and just past each corner), plus rays at even angles, each stopped
//    by the nearest occluder edge, give its visibility polygon. The polygon is drawn as a
//    triangle fan, split into rings whose corners carry the light's colour times its falloff
//    at that distance, additively into a half-resolution render texture cleared to the
//    ambient colour. A light is SUBS sub-lights spread over the size of its flame, each with
//    1/SUBS of its power: their shadows overlap into a penumbra, and the linear filter of the
//    half-resolution map, stretched over the screen, smooths the steps. Light is stored at
//    half its value, so a channel can reach 2 (a bright core) before it clips.
//
// 2. The product albedo x light, one colour channel at a time. A channel texture is cleared
//    to black; the light map is drawn into it with the tint (1, 0, 0) (only red survives);
//    then the albedo's "inverse coverage" for red is drawn over it, a one-channel texture
//    whose coverage is 1 - albedo.r, in black with alpha blending:
//        dst = 0 * (1 - a.r) + dst * a.r = light.r * albedo.r
//    The same for green and blue in their own textures.
//
// 3. On the screen the three channel textures are added (each twice: the factor 2 of step 1).
//    Light then falls on the surfaces in its own colour: an orange torch on grey stone looks
//    orange, a blue orb makes the warm floor violet, and nothing is lit where no light comes.
//    What glows by itself (flames, the orb, embers, sparks, the runes) is added on top.
use std.gfx_core                          // the backend is the main file's choice (std.gfx or std.gfx_vk)

const LM_W = 640                         // the light map: half the virtual resolution
const LM_H = 360
const SUBS = 5                           // sub-lights per light: the soft shadow
const EVEN_RAYS = 96                     // rays at even angles: a round edge where nothing blocks
const RINGS = 6                          // rings of the fan: the falloff curve, piecewise linear
const INSET: f32 = 4.0                   // light reaches this far into an occluder: lit rims
const MAX_SEGS = 256
const MAX_RAYS = 2048
const AMBIENT = vec3(0.042, 0.048, 0.08)  // the darkness is blue, not black

// Where the rings of a fan lie, as a fraction of each ray's length: denser near the centre,
// where the falloff is steep.
const RING_AT = [RINGS + 1]f32{0.0, 0.05, 0.13, 0.26, 0.44, 0.68, 1.0}

struct Seg { a: vec2, b: vec2 }

struct Lighting {
    segs: []Seg
    near: []i64          // indices of the segments in reach of the light being traced
    angles: []f32        // the rays of the light being traced
    pts: []vec2          // where they stop
    dist: []f32
    cols: []u32          // their colour at each ring: (RINGS + 1) per ray
    lightmap: Texture
    chan: [3]Texture     // light x albedo, one channel each
    inv: [3]Texture      // coverage 1 - albedo, per channel
    albedo: Texture
    shadows: bool
    traced: i64          // rays cast in the last light map (for the test's report)
}

// The occluders' edges, shrunk by INSET.
fn segments() -> []Seg {
    segs := alloc[Seg](len(BLOCKS) * 4)
    for i, b in BLOCKS {
        x0 := b.r.x + INSET
        y0 := b.r.y + INSET
        x1 := b.r.x + b.r.z - INSET
        y1 := b.r.y + b.r.w - INSET
        segs[i * 4] = Seg{vec2(x0, y0), vec2(x1, y0)}
        segs[i * 4 + 1] = Seg{vec2(x1, y0), vec2(x1, y1)}
        segs[i * 4 + 2] = Seg{vec2(x1, y1), vec2(x0, y1)}
        segs[i * 4 + 3] = Seg{vec2(x0, y1), vec2(x0, y0)}
    }
    segs
}

fn lighting_new(g: *Gfx, art: *Art) -> Lighting {
    lt := Lighting{segs: segments(), near: alloc[i64](MAX_SEGS), angles: alloc[f32](MAX_RAYS), pts: alloc[vec2](MAX_RAYS),
        dist: alloc[f32](MAX_RAYS), cols: alloc[u32](MAX_RAYS * (RINGS + 1)), shadows: true}
    assert len(lt.segs) <= MAX_SEGS
    lt.lightmap = g.render_texture(LM_W, LM_H, FilterLinear)
    for c in 0..3 {
        lt.chan[c] = g.render_texture(VW, VH, FilterLinear)
        lt.inv[c] = g.texture(inverse_channel(art.albedo, c), FilterNearest)
    }
    lt.albedo = g.texture(art.albedo, FilterLinear)
    lt
}

// Brightness at distance x (a fraction of the radius): a hot core, a long soft tail, exactly 0
// at the radius.
fn falloff(x: f32) -> f32 {
    q := saturate(1.0 - x * x)
    q * q / (1.0 + 14.0 * x * x)
}

fn light_u32(c: vec3) -> u32 { color_u32(vec4(c * 0.5, 1.0)) }   // stored at half: 2x headroom

// Where the ray o + d * t first meets segment s (t >= 0), or 1e9.
fn ray_seg(o: vec2, d: vec2, s: Seg) -> f32 {
    e := s.b - s.a
    den := cross(d, e)
    if fabs(den) < 1e-7 {
        return 1e9
    }
    w := s.a - o
    t := cross(w, e) / den
    u := cross(w, d) / den
    if t >= 0.0 && u >= -1e-4 && u <= 1.0001 { t } else { 1e9 }
}

fn seg_near(c: vec2, s: Seg, r: f32) -> bool {
    lo := min(s.a, s.b) - vec2(r)
    hi := max(s.a, s.b) + vec2(r)
    c.x > lo.x && c.x < hi.x && c.y > lo.y && c.y < hi.y
}

// The visibility polygon of a light at c reaching `radius`: lt.pts[0..n] in angle order.
fn trace(lt: *Lighting, c: vec2, radius: f32) -> i64 {
    nn := 0
    if lt.shadows {
        for i, s in lt.segs {
            // only edges that face the light and come within reach
            if cross(s.b - s.a, c - s.a) <= 0.0 && seg_near(c, s, radius) && nn < MAX_SEGS {
                lt.near[nn] = i
                nn += 1
            }
        }
    }
    n := 0
    for k in 0..EVEN_RAYS {
        lt.angles[n] = f32(k) * TAU / f32(EVEN_RAYS) - PI
        n += 1
    }
    r2 := radius * radius
    for k in 0..nn {
        s := lt.segs[lt.near[k]]
        for p in [2]vec2{s.a, s.b} {
            d := p - c
            if length_sq(d) < r2 && n + 3 <= MAX_RAYS {
                a := atan2(d.y, d.x)
                lt.angles[n] = a - 0.0004
                lt.angles[n + 1] = a
                lt.angles[n + 2] = a + 0.0004
                n += 3
            }
        }
    }
    sort(lt.angles[..n])
    for k in 0..n {
        a := lt.angles[k]
        dir := vec2(cos(a), sin(a))
        best := radius
        for j in 0..nn {
            best = fmin(best, ray_seg(c, dir, lt.segs[lt.near[j]]))
        }
        lt.pts[k] = c + dir * best
        lt.dist[k] = best
    }
    lt.traced += n
    n
}

// The fan of a traced polygon: rings of triangles whose corners carry the falloff.
fn draw_fan(g: *Gfx, lt: *Lighting, c: vec2, n: i64, color: vec3, radius: f32) {
    R1 := RINGS + 1
    for i in 0..n {
        for k in 0..R1 {
            lt.cols[i * R1 + k] = light_u32(color * falloff(RING_AT[k] * lt.dist[i] / radius))
        }
    }
    cc := light_u32(color * falloff(0.0))
    for i in 0..n {
        j := if i + 1 == n { 0 } else { i + 1 }
        di := lt.pts[i] - c
        dj := lt.pts[j] - c
        g.triangle(c, c + di * RING_AT[1], c + dj * RING_AT[1], cc, lt.cols[i * R1 + 1], lt.cols[j * R1 + 1])
        for k in 1..RINGS {
            ci1 := lt.cols[i * R1 + k + 1]
            cj1 := lt.cols[j * R1 + k + 1]
            a0 := c + di * RING_AT[k]
            b0 := c + dj * RING_AT[k]
            a1 := c + di * RING_AT[k + 1]
            b1 := c + dj * RING_AT[k + 1]
            g.triangle(a0, b0, b1, lt.cols[i * R1 + k], lt.cols[j * R1 + k], cj1)
            g.triangle(a0, b1, a1, lt.cols[i * R1 + k], cj1, ci1)
            if ci1 & 0xFFFFFF == 0 && cj1 & 0xFFFFFF == 0 {
                break                                      // black from here outwards
            }
        }
    }
}

// The light that falls on the tops of the blocks from above, unshadowed: a pillar or crate
// top facing a torch is lit, a wall top a little. Cells of at most TOP_CELL pixels, a colour per
// corner.
const TOP_CELL: f32 = 24.0

fn draw_tops(g: *Gfx, l: Light, pos: vec2, color: vec3) {
    for b in BLOCKS {
        k := match b.kind {
            Wall => 0.65
            Pillar => 0.45
            Crate => 0.75
        }
        r := b.r
        if !seg_near(pos, Seg{r.xy, r.xy + r.zw}, l.radius) {
            continue
        }
        nx := i64(ceil(r.z / TOP_CELL))
        ny := i64(ceil(r.w / TOP_CELL))
        sx := r.z / f32(nx)
        sy := r.w / f32(ny)
        for cy in 0..ny {
            for cx in 0..nx {
                p00 := r.xy + vec2(f32(cx) * sx, f32(cy) * sy)
                p11 := p00 + vec2(sx, sy)
                p10 := vec2(p11.x, p00.y)
                p01 := vec2(p00.x, p11.y)
                f00 := falloff(distance(p00, pos) / l.radius)
                f10 := falloff(distance(p10, pos) / l.radius)
                f01 := falloff(distance(p01, pos) / l.radius)
                f11 := falloff(distance(p11, pos) / l.radius)
                if f00 + f10 + f01 + f11 < 0.004 {
                    continue
                }
                c := color * k
                g.triangle(p00, p10, p11, light_u32(c * f00), light_u32(c * f10), light_u32(c * f11))
                g.triangle(p00, p11, p01, light_u32(c * f00), light_u32(c * f11), light_u32(c * f01))
            }
        }
    }
}

// Where a light is drawn: between its last two steps.
fn light_at(l: Light, alpha: f32) -> vec2 { lerp(l.prev, l.pos, alpha) }

// Renders the light map of this frame.
fn draw_lightmap(g: *Gfx, lt: *Lighting, w: *World, alpha: f32) {
    lt.traced = 0
    g.set_target(lt.lightmap)
    g.clear(light_u32(AMBIENT))
    g.set_transform(xform_scale(vec2(f32(LM_W) / f32(VW), f32(LM_H) / f32(VH))))
    g.set_blend(BlendAdd)
    for l in w.lights {
        pos := light_at(l, alpha)
        color := l.color * (l.power * l.level)
        for s in 0..SUBS {
            // sub-lights on a small disc, turned a little every frame against banding
            a := (f32(s) + 0.5) * TAU / f32(SUBS) + l.seed
            c := if SUBS == 1 { pos } else { pos + vec2(cos(a), sin(a)) * l.size }
            n := trace(lt, c, l.radius)
            draw_fan(g, lt, c, n, color / f32(SUBS), l.radius)
        }
        draw_tops(g, l, pos, color)
    }
    g.reset_target()
}

const CHANNEL_MASK = [3]u32{0xFF0000FF, 0xFF00FF00, 0xFFFF0000}

// The three products light x albedo (see the top of this file).
fn draw_channels(g: *Gfx, lt: *Lighting) {
    full := vec4(0.0, 0.0, f32(VW), f32(VH))
    for c in 0..3 {
        g.set_target(lt.chan[c])
        g.clear(0xFF000000)
        g.set_blend(BlendAlpha)
        g.sprite(lt.lightmap, vec4(0.0, 0.0, f32(LM_W), f32(LM_H)), full, CHANNEL_MASK[c])
        g.sprite(lt.inv[c], full, full, 0xFF000000)
    }
    g.reset_target()
}

// Adds the lit room to the current target (the screen, in virtual pixels).
fn draw_lit(g: *Gfx, lt: *Lighting) {
    full := vec4(0.0, 0.0, f32(VW), f32(VH))
    g.set_blend(BlendAdd)
    for k in 0..2 {
        for c in 0..3 {
            g.sprite(lt.chan[c], full, full, 0xFFFFFFFF)
        }
    }
}

// The light map itself (the debug view), at the brightness it has on a white surface.
fn draw_lightmap_view(g: *Gfx, lt: *Lighting) {
    g.set_blend(BlendAdd)
    for k in 0..2 {
        g.sprite(lt.lightmap, vec4(0.0, 0.0, f32(LM_W), f32(LM_H)), vec4(0.0, 0.0, f32(VW), f32(VH)), 0xFFFFFFFF)
    }
}

// The light at p as the CPU sees it (for the dust: a mote shows only where light reaches it):
// every light's falloff, if no occluder edge lies between.
fn light_on(lt: *Lighting, w: *World, p: vec2, alpha: f32) -> vec3 {
    sum := vec3(0.0)
    for l in w.lights {
        c := light_at(l, alpha)
        d := distance(p, c)
        if d >= l.radius {
            continue
        }
        f := falloff(d / l.radius)
        if f < 0.003 {
            continue
        }
        if lt.shadows {
            dir := (p - c) / fmax(d, 1e-3)
            blocked := false
            for s in lt.segs {
                if seg_near(c, s, d) && ray_seg(c, dir, s) < d {
                    blocked = true
                    break
                }
            }
            if blocked {
                continue
            }
        }
        sum = sum + l.color * (l.power * l.level * f)
    }
    sum
}

// Light scattered by the air: a faint wash of the light map over everything, which shows the
// light's colour also over dark mortar and walls and makes the pools of light read as volumes.
fn draw_haze(g: *Gfx, lt: *Lighting) {
    g.set_blend(BlendAdd)
    g.sprite(lt.lightmap, vec4(0.0, 0.0, f32(LM_W), f32(LM_H)), vec4(0.0, 0.0, f32(VW), f32(VH)), color_u32(vec4(1.0, 1.0, 1.0, 0.13)))
}
