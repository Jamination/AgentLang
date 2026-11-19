// The GPU side of examples/gfx_flow: trails by render-texture feedback, bloom, the final
// picture. std.gfx has two blend modes and no shaders of its own, so everything here is
// sprites of render textures drawn into each other:
//
//   fade      the previous picture is drawn into the other texture of its pair, darkened
//             toward black (Light: the light that is there) or lightened toward white (Ink:
//             how much of the paper shows through), slightly zoomed and turned if the preset
//             says so (ink instead moves a quarter texel aside each frame, which diffuses
//             it); then this frame's segments are drawn on top of it, added (Light) or
//             blended over (Ink: toward the ink's colour)
//   bloom     the light picture is halved down to 1/4 and 1/8 size (each halving is an exact
//             2x2 box filter: linear filtering sampled between texels), blurred there with
//             5 taps across and 5 down (binomial weights), and added back at full size
//   final     ground gradient, stars, the ink layer tinted by the paper colour (a tint
//             multiplies: paper times what shows through), light layer and bloom (added),
//             mountains, vignette and film grain, into one texture that is shown, saved by S
//             and read back by --shot
//
// The two layers are drawn at twice the picture's size (supersampling: the 1-unit lines get
// smooth edges and the trails no stair steps) and halved by the linear filter when composed.
//
// Render textures hold 8 bits per channel. Fading a value v by a factor f each frame stops
// when v * (1 - f) < 0.5 (the rounding gives v back): slow trails would leave a permanent
// haze of about 0.5 / (1 - f) levels. Two things keep the ground clean: the fade alternates
// between two factors whose mean is the wanted one (the stronger one lowers the level where
// it stalls), and a sparse dither (a tile with a few texels that darken the light layer or
// lighten the ink layer, at a random place every frame) removes what is left a few levels at
// a time. Measured: the sky under Aurora after 20 s of Silk differs from a fresh Aurora sky
// by about 1 level of 255.

const TILE = 256                   // the dither and grain tiles
const DITHER_P: f32 = 0.03         // share of texels of the dither tile that darken
const DITHER_LO = 24               // and by how much (of 255): uniformly between these
const DITHER_HI = 72
const STARS = 700
const DOT = 16                     // the soft disc stars are drawn with
const RIDGE_STEP = 8

struct Pair { a: Texture, b: Texture, live: bool }   // a: this frame's picture after `flip`

struct Star { pos: vec2, size: f32, color: u32 }   // pos: fraction of the picture

struct Look {
    w: i64                         // picture size in pixels
    h: i64
    ss: i64                        // the layers are drawn at ss times that size (supersampling)
    lw: i64
    lh: i64
    light: Pair
    ink: Pair
    down: Texture                  // bloom chain: the layer at picture size (ss 2),
    half: Texture                  // halved again, and so on
    q1: Texture
    q2: Texture
    e1: Texture
    e2: Texture
    final: Texture
    dither: Texture
    grain: Texture
    vignette: Texture
    dot: Texture
    disc: Texture                  // the moon of a Ring piece
    stars: []Star
    ridges: []f32                  // heights in pixels of two ridges, RIDGE_STEP pixels apart
    grain_a: f32                   // opacity of the film grain
    rng: Rng                       // where the tiles go each frame (cosmetic, not the simulation's)
    frame: i64
}

priv fn tile_image(seed: u64, dither: bool) -> Image {
    r := rng(seed)
    img := image_new(TILE, TILE, 4)
    for k in 0..TILE * TILE {
        if dither {
            hit := r.next_f32() < DITHER_P
            a := r.range(DITHER_LO, DITHER_HI + 1)
            img.pix[k * 4] = 255                    // white (tinted black for the light layer),
            img.pix[k * 4 + 1] = 255                // mostly transparent
            img.pix[k * 4 + 2] = 255
            img.pix[k * 4 + 3] = if hit { u8(a) } else { 0 }
        } else {
            v := u8(r.below(256))
            img.pix[k * 4] = v
            img.pix[k * 4 + 1] = v
            img.pix[k * 4 + 2] = v
            img.pix[k * 4 + 3] = 255
        }
    }
    img
}

// White, with a Gaussian falloff of alpha (white everywhere: see "Textures" in std/gfx.md).
priv fn dot_image() -> Image {
    img := image_new(DOT, DOT, 4)
    c := f32(DOT) / 2.0
    for y in 0..DOT {
        for x in 0..DOT {
            d := length(vec2(f32(x) + 0.5 - c, f32(y) + 0.5 - c)) / c
            k := (y * DOT + x) * 4
            img.pix[k] = 255
            img.pix[k + 1] = 255
            img.pix[k + 2] = 255
            img.pix[k + 3] = u8(clamp(exp(-d * d * 5.0) * 255.0 - 2.0, 0.0, 255.0))
        }
    }
    img
}

// A white disc with an antialiased edge.
priv fn disc_image() -> Image {
    n := 256
    img := image_new(n, n, 4)
    c := f32(n) / 2.0
    for y in 0..n {
        for x in 0..n {
            d := length(vec2(f32(x) + 0.5 - c, f32(y) + 0.5 - c))
            k := (y * n + x) * 4
            img.pix[k] = 255
            img.pix[k + 1] = 255
            img.pix[k + 2] = 255
            img.pix[k + 3] = u8(clamp(c - 1.0 - d, 0.0, 1.0) * 255.0)
        }
    }
    img
}

// A sky: many faint stars, a few bright ones, a little colour.
priv fn make_stars(seed: u64) -> []Star {
    r := rng(seed)
    stars := alloc[Star](STARS)
    for i in 0..STARS {
        b := pow(r.next_f32(), 6.0)                  // most are faint
        warm := r.next_f32()
        c := lerp(vec4(0.75, 0.85, 1.0, 1.0), vec4(1.0, 0.9, 0.75, 1.0), warm)
        stars[i] = Star{vec2(r.next_f32(), r.next_f32()), 1.6 + 5.0 * b, color_u32(vec4(c.x, c.y, c.z, 0.12 + 0.88 * b))}
    }
    stars
}

// Two mountain ridges: a far one, higher and smoother, and a near one, lower and rougher.
priv fn make_ridges(w: i64, h: i64, seed: u64) -> []f32 {
    n := w / RIDGE_STEP + 2
    out := alloc[f32](2 * n)
    s := u32(seed & 0xFFFF)
    u := f32(h) / 720.0
    for i in 0..n {
        x := f32(i * RIDGE_STEP) / u
        far := fbm2(x / 300.0, 0.5, 5, s)
        near := fbm2(x / 260.0, 7.5, 5, s + 1)
        peaks := 1.0 - fabs(far)                     // ridged: sharp crests
        out[i] = (625.0 - 150.0 * peaks * peaks - 25.0 * far) * u
        out[n + i] = (668.0 - 40.0 * (1.0 - fabs(near)) - 30.0 * near) * u
    }
    out
}

// Black, transparent in the middle and darker toward the corners (drawn stretched).
priv fn vignette_image() -> Image {
    w := 192
    h := 108
    img := image_new(w, h, 4)
    for y in 0..h {
        for x in 0..w {
            d := vec2((f32(x) + 0.5) / f32(w) - 0.5, ((f32(y) + 0.5) / f32(h) - 0.5) * 0.8)
            a := smoothstep(0.25, 0.8, length(d) * 1.35)
            img.pix[(y * w + x) * 4 + 3] = u8(a * a * 230.0)
        }
    }
    img
}

fn look_new(g: *Gfx, w: i64, h: i64, seed: u64) -> Look {
    ss := if h <= 1100 { 2 } else { 1 }   // 4K-sized windows: no supersampling
    l := Look{w: w, h: h, ss: ss, lw: w * ss, lh: h * ss, grain_a: 0.03, rng: rng(seed ^ 0x5EED)}
    rt := fn(g: *Gfx, w: i64, h: i64) -> Texture { g.render_texture(max(w, 1), max(h, 1), FilterLinear) }
    l.light = Pair{rt(g, l.lw, l.lh), rt(g, l.lw, l.lh), false}
    l.ink = Pair{rt(g, l.lw, l.lh), rt(g, l.lw, l.lh), false}
    l.down = rt(g, w, h)
    l.half = rt(g, w / 2, h / 2)
    l.q1 = rt(g, w / 4, h / 4)
    l.q2 = rt(g, w / 4, h / 4)
    l.e1 = rt(g, w / 8, h / 8)
    l.e2 = rt(g, w / 8, h / 8)
    l.final = rt(g, w, h)
    l.dither = g.texture(tile_image(seed + 1, true), FilterNearest)
    l.grain = g.texture(tile_image(seed + 2, false), FilterNearest)
    l.vignette = g.texture(vignette_image(), FilterLinear)
    l.dot = g.texture(dot_image(), FilterLinear)
    l.disc = g.texture(disc_image(), FilterLinear)
    l.stars = make_stars(seed + 3)
    l.ridges = make_ridges(w, h, seed + 4)
    l
}

fn look_free(g: *Gfx, l: *Look) {
    for t in []Texture{l.light.a, l.light.b, l.ink.a, l.ink.b, l.down, l.half, l.q1, l.q2, l.e1, l.e2,
        l.final, l.dither, l.grain, l.vignette, l.dot, l.disc} {
        g.free_texture(t)
    }
}

priv fn whole(t: Texture) -> vec4 { vec4(0.0, 0.0, f32(t.w), f32(t.h)) }

priv fn grey(v: f32, a: f32) -> u32 {
    c := u8(clamp(v * 255.0 + 0.5, 0.0, 255.0))
    rgba(c, c, c, u8(clamp(a * 255.0 + 0.5, 0.0, 255.0)))
}

// A tile drawn over the whole target, tinted, at a random offset.
priv fn tiles_tinted(g: *Gfx, l: *Look, t: Texture, w: i64, h: i64, tint: u32) {
    ox := -f32(l.rng.below(TILE))
    oy := -f32(l.rng.below(TILE))
    s := f32(TILE)
    y := oy
    while y < f32(h) {
        x := ox
        while x < f32(w) {
            g.sprite(t, vec4(0.0, 0.0, s, s), vec4(x, y, s, s), tint)
            x += s
        }
        y += s
    }
}

// The fade of this frame (as a tint byte) for a trail of `trail` seconds, `extra` being the
// mean factor the dither adds. Every other frame fades by the factor of two frames and the
// frames between do not fade at all: the stronger factor halves the level where the fade
// stalls, and at 30 Hz the alternation is invisible. Tints come in steps of 1/255, so the
// rounding error is carried from one fading frame to the next.
priv fn fade_byte(trail: f32, frame: i64, extra: f32) -> u8 {
    f := min(exp(-1.0 / (max(trail, 0.05) * f32(HZ))) / extra, 1.0)
    if frame % 2 == 0 {
        return 255
    }
    lose := (1.0 - f * f) * 255.0                    // levels of 255 lost per two frames
    n := f64(frame / 2)
    l := round(f64(lose) * (n + 1.0)) - round(f64(lose) * n)
    u8(clamp(255.0 - f32(l), 0.0, 255.0))
}

// Draws the previous picture of a pair into the other texture, faded; the pair flips so that
// `a` is the new picture.
priv fn fade(g: *Gfx, l: *Look, pr: *Pair, p: *Params, ink: bool, trail: f32) {
    prev := pr.a
    pr.a = pr.b
    pr.b = prev
    g.set_target(pr.a)
    w := f32(l.lw)
    h := f32(l.lh)
    g.clear(if ink { 0xFFFFFFFF } else { 0xFF000000 })   // clean paper / no light
    if !pr.live {
        return
    }
    extra := 1.0 - DITHER_P * f32(DITHER_LO + DITHER_HI) / 510.0
    fb := fade_byte(trail, l.frame, extra)
    tint := if ink { rgba(255, 255, 255, fb) } else { rgba(fb, fb, fb, 255) }
    g.set_blend(BlendAlpha)
    if p.zoom == 1.0 && p.spin == 0.0 {
        o := vec2(0.0)
        if ink {                                     // ink diffuses: a quarter texel aside, in turn
            o = [4]vec2{vec2(0.25, 0.0), vec2(0.0, 0.25), vec2(-0.25, 0.0), vec2(0.0, -0.25)}[l.frame % 4]
        }
        g.sprite(prev, whole(prev), vec4(o.x, o.y, w, h), tint)
    } else {
        size := vec2(w, h) * p.zoom
        g.sprite(prev, whole(prev), vec2(w, h) * 0.5, size, p.spin, size * 0.5, tint)
    }
    tiles_tinted(g, l, l.dither, l.lw, l.lh, if ink { 0xFFFFFFFF } else { 0xFF000000 })
}

// The segments each particle moved since the last frame, drawn into the current layer.
priv fn segments(g: *Gfx, s: *Sim, p: *Params, lut: []u32, scale: f32, ink: bool) {
    g.set_transform(xform_scale(vec2(scale)))
    g.set_blend(if ink { BlendAlpha } else { BlendAdd })
    k := p.key
    cphi := cos(k.phase)
    sphi := sin(k.phase)
    inv_speed := 0.5 / max(p.speed, 1.0)
    inv_h := 1.0 / s.h
    amax := p.alpha * 255.0
    width := p.width
    for i in 0..s.active {
        a := s.last[i]
        b := s.pos[i]
        s.last[i] = b
        d := b - a
        if d.x * d.x + d.y * d.y > 2500.0 {          // respawned: no segment across the picture
            continue
        }
        v := s.vel[i]
        sp := sqrt(v.x * v.x + v.y * v.y)
        key := k.base + k.speed * sp * inv_speed + k.y * b.y * inv_h + k.seed * s.tag[i]
        if sp > 0.0 {
            key += k.angle * (0.5 + 0.5 * (v.x * cphi + v.y * sphi) / sp)
        }
        age := s.age[i]
        life := s.life[i]
        key += k.age * age / life
        env := min(age / max(p.fade_in, 0.001), 1.0) * min((life - age) / (0.3 * life), 1.0)
        c := lut[clamp(i64(key * f32(LUT_SIZE - 1) + 0.5), 0, LUT_SIZE - 1)]
        alpha := clamp(amax * env + 0.5, 0.0, 255.0)
        if alpha < 1.0 {
            continue
        }
        g.line(a, b, width, c | (u32(alpha) << 24))
    }
    g.set_transform(xform_identity())
}

// src blurred into dst through tmp: 5 taps across into tmp, 5 down into dst.
priv fn blur(g: *Gfx, src: Texture, tmp: Texture, dst: Texture, spread: f32) {
    weights := [5]f32{1.0, 4.0, 6.0, 4.0, 1.0}
    for pass in 0..2 {
        from := if pass == 0 { src } else { tmp }
        to := if pass == 0 { tmp } else { dst }
        g.set_target(to)
        g.clear(0xFF000000)
        g.set_blend(BlendAdd)
        for t in 0..5 {
            o := f32(t - 2) * spread
            off := if pass == 0 { vec2(o, 0.0) } else { vec2(0.0, o) }
            wb := u8(weights[t] / 16.0 * 255.0 + 0.5)
            g.sprite(from, whole(from), vec4(off.x, off.y, f32(to.w), f32(to.h)), rgba(wb, wb, wb, 255))
        }
    }
}

priv fn color_of(v: vec4) -> u32 { color_u32(vec4(v.x, v.y, v.z, 1.0)) }

// One frame of the picture into l.final. The segments go into the ink layer if `draw_ink` (the
// piece shown or faded to is an ink piece), else into the light layer; p.ink says how much of
// the ink layer is shown and how little of the light layer (cross-fades). `paper`: the ink
// piece's paper.
fn render_picture(g: *Gfx, l: *Look, s: *Sim, p: *Params, lut: []u32, paper: u32, draw_ink: bool) {
    scale := f32(l.lh) / s.h
    // a layer no longer drawn into fades within about half a second while the cross-fade hides
    // it, then stays empty
    fade(g, l, &l.light, p, false, if draw_ink { min(p.trail, 0.5) } else { p.trail })
    if !draw_ink {
        segments(g, s, p, lut, scale, false)
    }
    fade(g, l, &l.ink, p, true, if draw_ink { p.trail } else { min(p.trail, 0.5) })
    if draw_ink {
        segments(g, s, p, lut, scale, true)
    }
    l.light.live = !draw_ink || l.light.live && p.ink < 0.999
    l.ink.live = draw_ink || l.ink.live && p.ink > 0.001
    // bloom of the light layer
    glow := p.glow * (1.0 - p.ink)
    if glow > 0.004 {
        g.set_blend(BlendAlpha)
        src := l.light.a
        if l.ss == 2 {
            g.set_target(l.down)
            g.sprite(src, whole(src), whole(l.down), 0xFFFFFFFF)
            src = l.down
        }
        g.set_target(l.half)
        g.sprite(src, whole(src), whole(l.half), 0xFFFFFFFF)
        g.set_target(l.q2)
        g.sprite(l.half, whole(l.half), whole(l.q2), 0xFFFFFFFF)
        g.set_target(l.e2)
        g.sprite(l.q2, whole(l.q2), whole(l.e2), 0xFFFFFFFF)
        blur(g, l.q2, l.q1, l.q2, 1.5)
        blur(g, l.e2, l.e1, l.e2, 1.5)
    }
    // the final picture
    g.set_target(l.final)
    g.set_blend(BlendAlpha)
    w := f32(l.w)
    h := f32(l.h)
    top := color_of(p.top)
    bottom := color_of(p.bottom)
    g.triangle(vec2(0.0, 0.0), vec2(w, 0.0), vec2(0.0, h), top, top, bottom)
    g.triangle(vec2(w, 0.0), vec2(w, h), vec2(0.0, h), top, bottom, bottom)
    stars := p.stars * (1.0 - p.ink)
    if stars > 0.004 {
        g.set_blend(BlendAdd)
        for st in l.stars {
            r := st.size * f32(l.h) / 720.0
            a := f32(st.color >> 24) * stars
            g.sprite(l.dot, whole(l.dot), vec4(st.pos.x * w - r, st.pos.y * h - r, 2.0 * r, 2.0 * r),
                (st.color & 0x00FFFFFF) | u32(a) << 24)
        }
        g.set_blend(BlendAlpha)
    }
    if p.moon > 0.004 && p.moon_r > 0.0 {               // the moon hides the stars behind it
        r := p.moon_r * f32(l.h) / 720.0
        c := vec2(p.focus.x * w, p.focus.y * h)
        ground := lerp(p.top, p.bottom, p.focus.y)
        g.sprite(l.disc, whole(l.disc), vec4(c.x - r, c.y - r, 2.0 * r, 2.0 * r), color_u32(vec4(ground.x, ground.y, ground.z, p.moon)))
    }
    if l.ink.live {
        g.sprite(l.ink.a, whole(l.ink.a), vec4(0.0, 0.0, w, h), (paper & 0x00FFFFFF) | u32(p.ink * 255.0 + 0.5) << 24)
    }
    g.set_blend(BlendAdd)
    if l.light.live {
        g.sprite(l.light.a, whole(l.light.a), vec4(0.0, 0.0, w, h), grey(1.0, 1.0 - p.ink))
        if glow > 0.004 {
            g.sprite(l.q2, whole(l.q2), vec4(0.0, 0.0, w, h), grey(1.0, glow * 0.8))
            g.sprite(l.e2, whole(l.e2), vec4(0.0, 0.0, w, h), grey(1.0, glow))
        }
    }
    if p.ridge > 0.004 {
        g.set_blend(BlendAlpha)
        n := len(l.ridges) / 2
        for layer in 0..2 {
            c := if layer == 0 { vec4(0.02, 0.045, 0.06, p.ridge) } else { vec4(0.003, 0.006, 0.012, p.ridge) }
            top := color_u32(c)
            foot := color_u32(vec4(c.x * 0.5, c.y * 0.5, c.z * 0.5, c.w))
            for i in 0..n - 1 {
                x0 := f32(i * RIDGE_STEP)
                x1 := x0 + f32(RIDGE_STEP)
                y0 := l.ridges[layer * n + i]
                y1 := l.ridges[layer * n + i + 1]
                g.triangle(vec2(x0, y0), vec2(x1, y1), vec2(x0, h), top, top, foot)
                g.triangle(vec2(x1, y1), vec2(x1, h), vec2(x0, h), top, foot, foot)
            }
        }
    }
    g.set_blend(BlendAlpha)
    g.sprite(l.vignette, whole(l.vignette), vec4(0.0, 0.0, w, h), grey(1.0, p.vignette))
    tiles_tinted(g, l, l.grain, l.w, l.h, grey(1.0, l.grain_a))
    l.frame += 1
}
