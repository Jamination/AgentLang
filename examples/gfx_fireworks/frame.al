// One frame of the show (render.al has the art and the bloom chain): the scene in its render
// texture, the screen with the water, and the HUD.
use std.font
use std.gfx
use std.gfx_text

const BLOOM: u32 = 0xE6         // how strongly glow[0] is added to the scene (alpha of the tint)
const STRETCH: f32 = 1.35       // the reflection reaches this much higher than the water is deep
const MOON = vec2(1060.0, 100.0)

// ---- the scene -------------------------------------------------------------------------------

priv fn sky_at(s: *Show, x: f32, y: f32) -> u32 {
    n := fbm2(x * 0.0035, y * 0.006 + f32(s.time) * 0.004, 3, 11) * 0.018
    rgba(sky_color(y) * (1.0 + n * 2.5) + light_at(s, vec2(x, y)) * 0.055, 1.0)
}

priv fn draw_sky(g: *Gfx, a: *Art, s: *Show) {
    t := f32(s.time)
    g.set_blend(BlendAlpha)
    nx := 16
    ny := 10
    cw := VW / f32(nx)
    for j in 0..ny {
        y0 := HORIZON * f32(j) / f32(ny)
        y1 := HORIZON * f32(j + 1) / f32(ny)
        for i in 0..nx {
            x0 := f32(i) * cw
            grad_quad(g, vec4(x0, y0, cw, y1 - y0), sky_at(s, x0, y0), sky_at(s, x0 + cw, y0), sky_at(s, x0, y1), sky_at(s, x0 + cw, y1))
        }
    }
    g.set_blend(BlendAdd)
    for st in a.stars {
        tw := 0.72 + 0.28 * sin(t * st.rate + st.phase)
        fade := 1.0 - 0.85 * smoothstep(250.0, HORIZON - 40.0, st.pos.y)
        blob(g, a, r_spark(), st.pos, st.size * 2.2, rgba(st.tint, st.bright * tw * fade))
    }
    moon := MOON
    blob(g, a, r_glow(), moon, 320.0, rgba(vec3(0.45, 0.52, 0.75), 0.13))
    blob(g, a, r_glow(), moon, 110.0, rgba(vec3(0.7, 0.75, 0.9), 0.12))
    for f in s.flashes[..s.nflashes] {                 // the bursts light the air around them
        p := flash_power(f)
        if p > 0.04 {
            blob(g, a, r_glow(), f.pos, 600.0 * sqrt(f.power), rgba(f.col, fmin(0.14 * p, 0.2)))
        }
    }
    g.set_blend(BlendAlpha)
    blob(g, a, r_moon(), moon, 64.0, 0xFFFFFFFF)
    for c in a.clouds {
        x := fmod(c.pos.x + t * c.speed + 600.0, VW + 1200.0) - 600.0
        mid := vec2(x + c.size.x * 0.5, c.pos.y + c.size.y * 0.5)
        col := vec3(0.10, 0.085, 0.15) + light_at(s, mid) * 0.30
        g.sprite(a.atlas, r_cloud(), vec4(x, c.pos.y, c.size.x, c.size.y), rgba(col, c.alpha))
    }
}

// The light on a wall: nearer bursts matter more than for the sky, and many bursts together
// saturate softly instead of flattening the city into one colour.
priv fn wall_light(s: *Show, p: vec2) -> vec3 {
    l := light_at(s, p, 170.0)
    l / (vec3(1.0) + l * 0.8) * 1.5
}

// Buildings take the light of the bursts at their corners (the GPU blends it across them),
// and their roofs catch a thin rim of it.
priv fn draw_layer(g: *Gfx, a: *Art, s: *Show, layer: i64, beacon_on: bool) {
    base := layer_color(layer)
    alb := layer_albedo(layer)
    g.set_blend(BlendAlpha)
    for b in a.blocks {
        if b.layer != layer {
            continue
        }
        r := b.r
        ltl := wall_light(s, r.xy)
        ltr := wall_light(s, vec2(r.x + r.z, r.y))
        lb := wall_light(s, vec2(r.x + r.z * 0.5, HORIZON))
        bottom := rgba(base * 0.8 + lb * (alb * 0.35), 1.0)
        grad_quad(g, r, rgba(base + ltl * alb, 1.0), rgba(base + ltr * alb, 1.0), bottom, bottom)
    }
    for sp in a.spires {
        if sp.layer != layer {
            continue
        }
        tip := sp.base - vec2(0.0, sp.h)
        lc := rgba(base + wall_light(s, tip) * alb, 1.0)
        bc := rgba(base + wall_light(s, sp.base) * alb, 1.0)
        g.triangle(sp.base - vec2(sp.half, 0.0), tip, sp.base + vec2(sp.half, 0.0), bc, lc, bc)
    }
    g.set_blend(BlendAdd)
    edge := rgba(base * 0.9 + vec3(0.012, 0.010, 0.016), 1.0)
    for b in a.blocks {
        if b.layer != layer {
            continue
        }
        if layer > 0 {                                 // a lighter corner edge gives the blocks volume
            g.rect(vec4(b.r.x, b.r.y, 1.0, b.r.w), edge)
        }
        l := wall_light(s, vec2(b.r.x + b.r.z * 0.5, b.r.y))
        if l.x + l.y + l.z > 0.05 {
            g.rect(vec4(b.r.x, b.r.y, b.r.z, 1.0), rgba(l * (alb * 1.4), 1.0))
        }
    }
    for w in a.wins {
        if w.layer != layer {
            continue
        }
        // now and then somebody switches a light off, or on again
        if noise_hash(w.id, i64(s.time / 11.0), 0, 5) % 23 == 0 {
            continue
        }
        g.rect(w.r, rgba(w.col, 0.9))
    }
    if beacon_on && layer > 0 {
        for p in a.beacons {
            blob(g, a, r_spark(), p, 7.0, 0xFF3030FF)
        }
    }
}

// A band of haze over the horizon: alpha from 0 at y0 to `alpha` at the horizon.
priv fn haze(g: *Gfx, y0: f32, col: vec3, alpha: f32) {
    g.set_blend(BlendAlpha)
    grad_quad(g, vec4(0.0, y0, VW, HORIZON - y0), rgba(col, 0.0), rgba(col, 0.0), rgba(col, alpha), rgba(col, alpha))
}

priv fn draw_smoke(g: *Gfx, a: *Art, s: *Show) {
    g.set_blend(BlendAlpha)
    for p in s.puffs[..s.npuffs] {
        t := p.age / p.life
        fade := smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.45, 1.0, t))
        own := p.col * (0.35 * exp(-2.5 * p.age))
        col := vec3(0.075, 0.07, 0.10) + light_at(s, p.pos) * 0.42 + own
        g.sprite(a.atlas, r_smoke(), p.pos, vec2(p.size), p.spin + p.age * 0.05, vec2(p.size * 0.5), rgba(col, p.alpha * fade))
    }
}

priv fn draw_sparks(g: *Gfx, a: *Art, s: *Show, alpha: f32) {
    g.set_blend(BlendAdd)
    for p in s.parts[..s.nparts] {
        if p.age < 0.0 {
            continue
        }
        c, b := spark_look(p, s.steps)
        if b < 0.01 {
            continue
        }
        pos := p.pos + p.vel * (alpha * DT)
        if p.flags & F_POP != 0 {
            blob(g, a, r_flare(), pos, 6.0 + 9.0 * b, rgba(c, b))
            continue
        }
        speed := length(p.vel)
        tail := fmin(speed * 0.085, 60.0)
        if tail > 2.5 {
            w := p.size * 2.0
            g.sprite(a.atlas, r_streak(), pos, vec2(tail, w), atan2(p.vel.y, p.vel.x), vec2(tail, w * 0.5), rgba(c, 0.65 * b))
        }
        if p.flags & F_STROBE != 0 && b > 0.5 {
            blob(g, a, r_flare(), pos, 10.0, rgba(c, b))             // a glitter star at its peak
        }
        blob(g, a, r_spark(), pos, p.size * 3.4, rgba(c, b))
    }
    for sh in s.shells[..s.nshells] {
        pos := sh.pos + sh.vel * (alpha * DT)
        blob(g, a, r_spark(), pos, 9.0, rgba(vec3(1.0, 0.9, 0.7), 1.0))
    }
}

priv fn draw_shore(g: *Gfx, a: *Art, s: *Show) {
    g.set_blend(BlendAlpha)
    g.rect(vec4(0.0, HORIZON - 3.0, VW, 3.0), rgba(vec3(0.012, 0.012, 0.022), 1.0))
    for x in PADS {
        g.rect(vec4(x - 18.0, HORIZON - 6.0, 36.0, 4.0), rgba(vec3(0.02, 0.02, 0.03), 1.0))
        g.rect(vec4(x - 6.0, HORIZON - 9.0, 12.0, 3.0), rgba(vec3(0.02, 0.02, 0.03), 1.0))
    }
    g.set_blend(BlendAdd)
    for i, l in a.lamps {
        flicker := 0.85 + 0.15 * f32(noise_hash(i64(i), s.steps / 4, 0, 9) & 255) / 255.0
        blob(g, a, r_spark(), l, 5.0, rgba(vec3(1.0, 0.72, 0.42), flicker))
    }
    for x in PADS {
        blob(g, a, r_spark(), vec2(x - 15.0, HORIZON - 7.0), 4.0, 0xFF2020FF)
        blob(g, a, r_spark(), vec2(x + 15.0, HORIZON - 7.0), 4.0, 0xFF40FF40)
    }
}

priv fn draw_scene(g: *Gfx, a: *Art, s: *Show, alpha: f32) {
    g.set_target(a.scene)
    g.clear(0xFF000000)
    beacon_on := fract(f32(s.time) * 0.6) < 0.35
    draw_sky(g, a, s)
    draw_layer(g, a, s, 0, beacon_on)
    haze(g, HORIZON - 170.0, vec3(0.20, 0.11, 0.17), 0.55)
    draw_layer(g, a, s, 1, beacon_on)
    haze(g, HORIZON - 90.0, vec3(0.16, 0.09, 0.14), 0.32)
    draw_layer(g, a, s, 2, beacon_on)
    draw_shore(g, a, s)
    draw_smoke(g, a, s)
    draw_sparks(g, a, s, alpha)
    g.set_blend(BlendAdd)
    g.sprite(a.glow[0], vec4(0.0, 0.0, a.gw[0], a.gh[0]), vec4(0.0, 0.0, VW, VH), (BLOOM << 24) | 0xFFFFFF)
}

// ---- the screen: the scene, the water, the vignette ------------------------------------------

priv fn draw_water(g: *Gfx, a: *Art, s: *Show) {
    t := f32(s.time)
    deep := VH - HORIZON
    g.set_blend(BlendAlpha)
    rows := i64(deep / 2.0)
    for j in 0..rows {
        d := f32(j) * 2.0
        depth := d / deep
        w1 := sin(d * 0.23 - t * 1.6 + sin(d * 0.045 + t * 0.35) * 2.2)
        w2 := sin(d * 0.71 + t * 2.9 + w1)
        dx := (w1 * 0.75 + w2 * 0.25) * (0.5 + depth * 9.0)
        top := HORIZON - (d + w2 * depth * 3.0) * STRETCH
        shade := (0.92 - depth * 0.45) * (0.92 + 0.08 * w1)
        g.sprite(a.scene, vec4(-24.0, top, VW + 48.0, -2.0 * STRETCH), vec4(dx - 24.0, HORIZON + d, VW + 48.0, 2.0),
            rgba(vec3(0.60, 0.68, 0.86) * shade, 1.0))
    }
    ink := vec3(0.008, 0.014, 0.03)
    grad_quad(g, vec4(0.0, HORIZON, VW, deep), rgba(ink, 0.0), rgba(ink, 0.0), rgba(ink, 0.45), rgba(ink, 0.45))
    // glints: the bursts and the shore lamps drawn out into columns by the waves
    g.set_blend(BlendAdd)
    for f in s.flashes[..s.nflashes] {
        p := flash_power(f)
        if p < 0.03 {
            continue
        }
        for k in 0..18 {
            u := f32(k) / 18.0
            h := noise_hash(i64(k), s.steps / 5, i64(f.pos.x), 3)
            y := HORIZON + 3.0 + pow(u, 1.3) * (deep - 8.0)
            jx := (f32(h & 255) / 255.0 - 0.5) * (8.0 + 46.0 * u)
            w := (12.0 + 60.0 * u) * (0.4 + 0.6 * f32((h >> 8) & 255) / 255.0)
            g.sprite(a.atlas, r_glow(), vec4(f.pos.x + jx - w * 0.5, y - 1.5, w, 3.0 + 3.0 * u), rgba(f.col, fmin(p, 1.2) * 0.42 * (1.0 - u * 0.6)))
        }
    }
    for k in 0..26 {                                  // the moon's path of glitter
        u := f32(k) / 26.0
        h := noise_hash(i64(k), s.steps / 7, 1, 6)
        y := HORIZON + 6.0 + pow(u, 1.15) * (deep - 12.0)
        w := (5.0 + 34.0 * u) * (0.3 + 0.7 * f32(h & 255) / 255.0)
        jx := (f32((h >> 8) & 255) / 255.0 - 0.5) * (6.0 + 50.0 * u)
        g.sprite(a.atlas, r_glow(), vec4(MOON.x + jx - w * 0.5, y - 1.0, w, 2.0 + 2.0 * u), rgba(vec3(0.6, 0.66, 0.85), 0.22 * (1.0 - u * 0.4)))
    }
    for i, l in a.lamps {
        for k in 0..4 {
            h := noise_hash(i64(i), i64(k), s.steps / 6, 4)
            w := 3.0 + f32(h & 7)
            g.sprite(a.atlas, r_glow(), vec4(l.x - w * 0.5 + f32((h >> 4) & 3) - 1.5, HORIZON + 3.0 + f32(k) * 5.0, w, 2.5),
                rgba(vec3(1.0, 0.7, 0.4), 0.30 - f32(k) * 0.06))
        }
    }
    // mist where the water meets the shore
    g.set_blend(BlendAlpha)
    mist := vec3(0.22, 0.13, 0.17)
    grad_quad(g, vec4(0.0, HORIZON - 12.0, VW, 12.0), rgba(mist, 0.0), rgba(mist, 0.0), rgba(mist, 0.25), rgba(mist, 0.25))
    grad_quad(g, vec4(0.0, HORIZON, VW, 10.0), rgba(mist, 0.25), rgba(mist, 0.25), rgba(mist, 0.0), rgba(mist, 0.0))
}

priv fn vignette(g: *Gfx, strength: f32) {
    g.set_blend(BlendAlpha)
    c := vec2(VW, VH) * 0.5
    clear := rgba(vec3(0.0), 0.0)
    dark := rgba(vec3(0.0), strength)
    n := 48
    for i in 0..n {
        a0 := f32(i) / f32(n) * TAU
        a1 := f32(i + 1) / f32(n) * TAU
        i0 := c + vec2(cos(a0) * VW * 0.42, sin(a0) * VH * 0.40)
        i1 := c + vec2(cos(a1) * VW * 0.42, sin(a1) * VH * 0.40)
        o0 := c + vec2(cos(a0) * VW * 0.78, sin(a0) * VH * 0.78)
        o1 := c + vec2(cos(a1) * VW * 0.78, sin(a1) * VH * 0.78)
        g.triangle(i0, o0, o1, clear, dark, dark)
        g.triangle(i0, o1, i1, clear, dark, clear)
    }
}

// ---- HUD -------------------------------------------------------------------------------------

const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
const LIGHT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeuil.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-ExtraLight.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-ExtraLight.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

priv fn load_font(paths: []str) -> (Font, bool) {
    for p in paths {
        f, err := font_load(p)
        if err == "" {
            return (f, true)
        }
    }
    f: Font
    (f, false)
}

// The HUD's fonts, rasterised at the size they have on the screen (see examples/gfx_starter).
struct Hud { font: Font, light: Font, scale: f32, title: GfxFont, small: GfxFont }

hud_mem: Region

fn hud_new() -> Hud {
    f, ok := load_font(FONT_PATHS[..])
    if !ok {
        eprint("no system font found: the text is drawn with the test font of std.font")
        f, _ = font_parse(TEST_FONT)
    }
    l, lok := load_font(LIGHT_PATHS[..])
    Hud{font: f, light: if lok { l } else { f }}
}

fn hud_fonts(g: *Gfx, h: *Hud, scale: f32) {
    if scale == h.scale || !(scale > 0.0) {
        return
    }
    if h.scale > 0.0 {
        gfx_font_free(g, h.title)
        gfx_font_free(g, h.small)
    }
    reset(&hud_mem)
    enter(&hud_mem)
    chars := vec[i64]()
    chars.extend(char_range(32, 126))
    chars.push(0xB7)                              // the middle dot
    err := ""
    h.title, err = gfx_font(g, h.light, 30.0 * scale, chars[..])
    assert err == "", err
    h.small, err = gfx_font(g, h.font, 13.0 * scale, chars[..])
    assert err == "", err
    leave()
    h.title.size = 30.0
    h.small.size = 13.0
    h.scale = scale
}

priv fn shadowed(g: *Gfx, f: GfxFont, x: f32, y: f32, text: str, col: u32, align: TextAlign) {
    g.draw_text(f, x + 1.0, y + 1.5, text, 0x99000000, align)
    g.draw_text(f, x, y, text, col, align)
}

// Draws "key description" pairs from x; returns where the next one goes.
priv fn hint(g: *Gfx, f: GfxFont, x: f32, y: f32, key: str, what: str) -> f32 {
    shadowed(g, f, x, y, key, 0xE6FFFFFF, AlignLeft)
    kw, _ := text_size(f, key)
    shadowed(g, f, x + kw + 6.0, y, what, 0x8CFFFFFF, AlignLeft)
    ww, _ := text_size(f, what)
    x + kw + 6.0 + ww + 26.0
}

priv fn draw_hud(g: *Gfx, h: *Hud, s: *Show, fps: str) {
    g.set_blend(BlendAlpha)
    shadowed(g, h.title, 34.0, 24.0, "F I R E W O R K S", 0xF2FFFFFF, AlignLeft)
    y := 24.0 + line_height(h.title) + 2.0
    shadowed(g, h.small, 36.0, y, fmt(s.nparts, " particles  \xC2\xB7  ", fps), 0xA6FFFFFF, AlignLeft)
    act := if s.auto { ACT_NAMES[s.act] } else { "manual" }
    shadowed(g, h.small, VW - 34.0, 34.0, act, 0x8CFFFFFF, AlignRight)
    age := f32(s.time - s.click_time)                 // a ring where a shell was aimed by hand
    if age >= 0.0 && age < 0.7 {
        k := age / 0.7
        r := 6.0 + 26.0 * k
        col := rgba(vec3(1.0), 0.7 * (1.0 - k))
        for i in 0..24 {
            a0 := f32(i) / 24.0 * TAU
            a1 := f32(i + 1) / 24.0 * TAU
            g.line(s.click + vec2(cos(a0), sin(a0)) * r, s.click + vec2(cos(a1), sin(a1)) * r, 1.5, col)
        }
    }
    x := 36.0
    yb := VH - 38.0
    x = hint(g, h.small, x, yb, "Click", "launch a shell")
    x = hint(g, h.small, x, yb, "Space", "volley")
    x = hint(g, h.small, x, yb, "A", if s.auto { "stop the show" } else { "resume the show" })
    x = hint(g, h.small, x, yb, "F11", "fullscreen")
    x = hint(g, h.small, x, yb, "Esc", "quit")
}

// ---- the frame -------------------------------------------------------------------------------

// Draws a frame; `alpha` is how far the display is past the last simulation step (0..1).
// Returns the view transform (for the mouse) and "" or why the GPU failed. false: nothing was
// drawn (minimized).
fn render_frame(g: *Gfx, a: *Art, h: *Hud, s: *Show, alpha: f32, fps: str) -> (Xform, str, bool) {
    if !g.begin_frame(0xFF000000) {
        return (xform_identity(), "", false)
    }
    bright_pass(g, a, s, alpha)
    bloom_chain(g, a)
    draw_scene(g, a, s, alpha)
    g.reset_target()
    view := g.set_view(VW, VH)
    g.set_blend(BlendAlpha)
    g.sprite(a.scene, vec4(0.0, 0.0, VW, HORIZON), vec4(0.0, 0.0, VW, HORIZON), 0xFFFFFFFF)
    draw_water(g, a, s)
    vignette(g, 0.55)
    draw_hud(g, h, s, fps)
    (view, g.end_frame(), true)
}
