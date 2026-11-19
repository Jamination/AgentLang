// Drawing. A frame is drawn in two passes:
//
// 1. The world into `scene`, a 480 x 270 render texture with nearest filtering: the banded,
//    dithered sky, stars, sun and moon, clouds, four parallax strips (each a stack of masks
//    tinted with the colours of the moment and faded into the haze of its distance), birds, and
//    the playfield (props, auto-tiled ground, the bridge, grass and flowers, the wanderer).
//    Drawing at the virtual resolution keeps every pixel on one grid, whatever moves.
// 2. The scene onto the screen through set_view (an integer scale gives square pixels), then
//    what must not be mirrored: the lakes, each row of which is a one-pixel slice of the scene
//    from above the water line, flipped, shifted by a wave and tinted; fireflies with additive
//    glows, leaves, rain, the grass and reeds of the foreground.
use std.gfx

struct Art {
    scene: Texture
    far: Strip
    mid: Strip
    hills: Strip
    forest: Strip
    clouds: Strip
    props: Props
    tiles: Texture
    hero: Texture
    moon: Texture
    misc: Texture
}

const STRIP_W = 1024
const WHITE: u32 = 0xFFFFFFFF

fn make_art(g: *Gfx, seed: u32) -> Art {
    a := Art{scene: g.render_texture(VIEW_W, VIEW_H, FilterNearest)}
    p := painter(STRIP_W, 140, true)
    paint_range(&p, 6.0, 100.0, 0.0075, 0.85, 52.0, 0.0, seed + 100)
    a.far = strip_upload(g, &p, []u8{MAT_ROCK, MAT_SNOW})
    p = painter(STRIP_W, 120, true)
    paint_range(&p, 8.0, 56.0, 0.011, 0.55, -100.0, 0.55, seed + 200)
    a.mid = strip_upload(g, &p, []u8{MAT_ROCK, MAT_LEAF})
    p = painter(STRIP_W, 100, true)
    paint_hills(&p, 10.0, 34.0, 0.006, seed + 300)
    a.hills = strip_upload(g, &p, []u8{MAT_GROUND, MAT_LEAF, MAT_AUTUMN, MAT_TRUNK})
    p = painter(STRIP_W, 130, true)
    paint_forest(&p, 84.0, seed + 400)
    a.forest = strip_upload(g, &p, []u8{MAT_GROUND, MAT_LEAF, MAT_AUTUMN, MAT_TRUNK})
    p = painter(2 * CLOUD_CELL_W, (CLOUD_COUNT / 2) * CLOUD_CELL_H, false)
    paint_clouds(&p, seed + 500)
    a.clouds = strip_upload(g, &p, []u8{MAT_CLOUD})
    a.props = paint_props(g, seed + 600)
    a.tiles = g.texture(make_tiles(), FilterNearest)
    a.hero = g.texture(make_hero(), FilterNearest)
    a.moon = g.texture(make_moon(), FilterNearest)
    a.misc = g.texture(make_misc(), FilterNearest)
    a
}

// ---- colours of materials

// The daylight colours of a material (shadow, mid tone, highlight; 0xRRGGBB), per layer:
// 0 far mountains, 1 near mountains, 2 hills, 3 forest, 4 props, 5 clouds (from the light).
struct Tones { shadow: u32, mid: u32, hi: u32 }

fn tones_of(layer: i64, m: u8) -> Tones {
    match (layer, m) {
        (0, MAT_ROCK) => Tones{0x48588a, 0x7084b4, 0xa4b6dc}
        (0, MAT_SNOW) => Tones{0x96a8d4, 0xd4e0f4, 0xffffff}
        (1, MAT_ROCK) => Tones{0x2e4866, 0x4c727e, 0x7a9c88}
        (1, MAT_LEAF) => Tones{0x1e3646, 0x274c4c, 0x34604c}
        (2, MAT_GROUND) => Tones{0x24484a, 0x3c7050, 0x70a058}
        (2, MAT_LEAF) => Tones{0x1a3e38, 0x2a6440, 0x4e8e44}
        (2, MAT_AUTUMN) => Tones{0x7a3430, 0xb86434, 0xe8a448}
        (2, MAT_TRUNK) => Tones{0x2e2228, 0x463030, 0x5a4036}
        (3, MAT_GROUND) => Tones{0x163428, 0x204a34, 0x2e5e38}
        (3, MAT_LEAF) => Tones{0x123428, 0x1e5434, 0x3c8236}
        (3, MAT_AUTUMN) => Tones{0x6a2628, 0xb25226, 0xec9436}
        (3, MAT_TRUNK) => Tones{0x24181e, 0x3e2a26, 0x5a3e2e}
        (_, MAT_LEAF) => Tones{0x183e30, 0x2a6e38, 0x66aa3e}
        (_, MAT_AUTUMN) => Tones{0x7e2a2c, 0xcc5a28, 0xf8b040}
        (_, MAT_TRUNK) => Tones{0x34202a, 0x5a3828, 0x8a5a36}
        (_, MAT_BARK) => Tones{0x7c7c98, 0xd0d0dc, 0xffffff}
        (_, MAT_ROCK) => Tones{0x464660, 0x76768a, 0xb0aab4}
        (_, MAT_LINE) => Tones{0x120e1c, 0x120e1c, 0x120e1c}
        _ => Tones{0xff00ff, 0xff00ff, 0xff00ff}
    }
}

// How far each layer has faded into the haze.
priv const LAYER_FOG = [_]f32{0.4, 0.25, 0.12, 0.07, 0.0}

struct Cols { shadow: vec3, mid: vec3, hi: vec3 }

fn cols_of(layer: i64, m: u8, l: *Light) -> Cols {
    if m == MAT_CLOUD {
        return Cols{l.cloud_shade, l.cloud_body, l.cloud_lit}
    }
    t := tones_of(layer, m)
    fog := LAYER_FOG[min(layer, 4)]
    lit := lerp(l.amb, l.rim, 0.55)
    Cols{lerp(rgb(t.shadow) * l.amb, l.fog, fog), lerp(rgb(t.mid) * lit, l.fog, fog), lerp(rgb(t.hi) * l.rim, l.fog, fog)}
}

// The five masks of material k (rows k * MASKS * h + ...) of a stacked texture, from the cell
// `src` (y relative to the first mask) into `dst`. The lit masks of the two key lights are
// blended by where the light comes from; `alpha` fades the whole material.
fn draw_masks(g: *Gfx, tex: Texture, h: i64, k: i64, src: vec4, dst: vec4, c: Cols, fr: f32, alpha: f32, mirror: bool) {
    fn at(src: vec4, h: i64, k: i64, j: i64, mirror: bool) -> vec4 {
        s := vec4(src.x, src.y + f32((k * MASKS + j) * h), src.z, src.w)
        if mirror {
            s.x += s.z
            s.z = -s.z
        }
        s
    }
    if mirror {
        fr = 1.0 - fr
    }
    g.sprite(tex, at(src, h, k, 0, mirror), dst, cola(c.shadow, alpha))
    if fr < 0.999 {
        g.sprite(tex, at(src, h, k, 1, mirror), dst, cola(c.mid, alpha * (1.0 - fr)))
        g.sprite(tex, at(src, h, k, 2, mirror), dst, cola(c.hi, alpha * (1.0 - fr)))
    }
    if fr > 0.001 {
        g.sprite(tex, at(src, h, k, 3, mirror), dst, cola(c.mid, alpha * fr))
        g.sprite(tex, at(src, h, k, 4, mirror), dst, cola(c.hi, alpha * fr))
    }
}

// A strip, scrolled: copies side by side from x (<= 0) across the view. On whole pixels: a
// fraction would sample the last row of the mask stacked above.
fn draw_strip(g: *Gfx, s: *Strip, layer: i64, l: *Light, scroll: f32, y: f32) {
    fw := f32(s.w)
    y = floor(y + 0.5)
    x0 := -floor(fmod(fmod(scroll, fw) + fw, fw))
    for k in 0..len(s.mats) {
        c := cols_of(layer, s.mats[k], l)
        x := x0
        while x < f32(VIEW_W) {
            r := vec4(0.0, 0.0, fw, f32(s.h))
            draw_masks(g, s.tex, s.h, k, r, vec4(x, y, fw, f32(s.h)), c, l.from_right, 1.0, false)
            x += fw
        }
    }
}

// Haze below y: a dithered ramp into the fog colour, then the fog itself.
fn haze(g: *Gfx, a: *Art, y: f32, c: vec3, alpha: f32) {
    y = floor(y + 0.5)
    g.sprite(a.misc, vec4(0.0, f32(RAMP16_Y), f32(VIEW_W), 16.0), vec4(0.0, y, f32(VIEW_W), 16.0), cola(c, alpha))
    g.rect(vec4(0.0, y + 16.0, f32(VIEW_W), f32(VIEW_H) - y - 16.0), cola(c, alpha))
}

// ---- the sky

fn sky_at(l: *Light, y: f32) -> vec3 {
    if y < 112.0 {
        return lerp(l.sky_top, l.sky_mid, smoothstep(0.0, 112.0, y))
    }
    lerp(l.sky_mid, l.sky_hor, smoothstep(112.0, 196.0, y))
}

fn draw_sky(g: *Gfx, a: *Art, w: *World, l: *Light) {
    band := 9.0
    y := 0.0
    while y < f32(VIEW_H) {
        g.rect(vec4(0.0, y, f32(VIEW_W), band), col(sky_at(l, y + band * 0.5)))
        next := sky_at(l, y + band * 1.5)
        g.sprite(a.misc, vec4(0.0, f32(RAMP4_Y), f32(VIEW_W), 4.0), vec4(0.0, y + band - 4.0, f32(VIEW_W), 4.0), col(next))
        y += band
    }
    t := f32(w.time)
    // stars
    if l.night > 0.01 {
        for i in 0..STARS {
            s := &w.stars[i]
            tw := 0.65 + 0.35 * sin(t * (1.5 + s.bright * 2.0) + s.phase)
            al := l.night * (0.25 + s.bright * 0.75) * tw
            p := vec2(floor(s.pos.x), floor(s.pos.y))
            c := if i % 5 == 0 { vec3(1.0, 0.92, 0.8) } else if i % 7 == 0 { vec3(0.75, 0.85, 1.0) } else { vec3(1.0) }
            g.rect(vec4(p.x, p.y, 1.0, 1.0), cola(c, al))
            if s.bright > 0.82 {
                g.rect(vec4(p.x - 1.0, p.y, 3.0, 1.0), cola(c, al * 0.45))
                g.rect(vec4(p.x, p.y - 1.0, 1.0, 3.0), cola(c, al * 0.45))
            }
        }
        if w.meteor_age >= 0.0 {
            fade := l.night * (1.0 - smoothstep(0.5, 0.9, w.meteor_age))
            dir := normalize(w.meteor_vel)
            for k in 0..14 {
                p := w.meteor_pos - dir * f32(k) * 1.6
                g.rect(vec4(floor(p.x), floor(p.y), 1.0, 1.0), cola(vec3(1.0, 0.95, 0.85), fade * (1.0 - f32(k) / 14.0)))
            }
        }
    }
    // sun and moon, with banded glows
    g.set_blend(BlendAdd)
    if l.moon.y < HORIZON_Y + 10.0 {
        m := vec2(floor(l.moon.x), floor(l.moon.y))
        half := f32(GLOW_BIG) * 0.5
        g.sprite(a.misc, vec4(0.0, 0.0, f32(GLOW_BIG), f32(GLOW_BIG)), vec4(m.x - half, m.y - half, f32(GLOW_BIG), f32(GLOW_BIG)),
            cola(vec3(0.45, 0.55, 0.9), 0.2 * l.night))
    }
    if l.sun.y < HORIZON_Y + 12.0 {
        s := vec2(floor(l.sun.x), floor(l.sun.y))
        half := f32(GLOW_BIG)
        low := 1.0 - smoothstep(0.0, 0.5, l.sun_elev)
        half = f32(GLOW_BIG) * 0.5
        g.sprite(a.misc, vec4(0.0, 0.0, f32(GLOW_BIG), f32(GLOW_BIG)), vec4(s.x - half, s.y - half, half * 2.0, half * 2.0),
            cola(l.sun_col, 0.3 + 0.3 * low))
    }
    g.set_blend(BlendAlpha)
    if l.moon.y < HORIZON_Y + 10.0 {
        m := vec2(floor(l.moon.x), floor(l.moon.y))
        h := f32(MOON_SIZE) * 0.5
        g.sprite(a.moon, vec4(0.0, 0.0, f32(MOON_SIZE), f32(MOON_SIZE)), vec4(m.x - h, m.y - h, f32(MOON_SIZE), f32(MOON_SIZE)),
            cola(vec3(1.0), clamp(l.night * 1.4, 0.0, 1.0)))
    }
    if l.sun.y < HORIZON_Y + 12.0 {
        s := vec2(floor(l.sun.x), floor(l.sun.y))
        h := f32(DISC_SIZE) * 0.5
        g.sprite(a.misc, vec4(96.0, 16.0, f32(DISC_SIZE), f32(DISC_SIZE)), vec4(s.x - h, s.y - h, f32(DISC_SIZE), f32(DISC_SIZE)),
            col(lerp(l.sun_col, vec3(1.0, 1.0, 0.92), 0.6)))
    }
}

fn draw_clouds(g: *Gfx, a: *Art, w: *World, l: *Light, camx: f32) {
    t := f32(w.time)
    for k in 0..9 {
        s := u32(k) + w.seed
        f := 0.03 + hash01(i64(k), s + 1) * 0.05
        speed := 2.0 + hash01(i64(k), s + 2) * 3.0
        x := hash01(i64(k), s + 3) * 720.0 + t * speed - camx * f
        x = fmod(fmod(x + 120.0, 720.0) + 720.0, 720.0) - 120.0
        y := 8.0 + hash01(i64(k), s + 4) * 52.0           // high: the low sun stays clear
        cell := (k * 3) % CLOUD_COUNT
        src := vec4(f32((cell % 2) * CLOUD_CELL_W), f32((cell / 2) * CLOUD_CELL_H), f32(CLOUD_CELL_W), f32(CLOUD_CELL_H))
        c := cols_of(5, MAT_CLOUD, l)
        // higher clouds are a little hazier
        draw_masks(g, a.clouds.tex, a.clouds.h, 0, src, vec4(floor(x), floor(y), f32(CLOUD_CELL_W), f32(CLOUD_CELL_H)), c,
            l.from_right, 0.92, k % 2 == 1)
    }
}

fn draw_birds(g: *Gfx, a: *Art, w: *World, l: *Light) {
    if w.flock_dir == 0.0 || l.day < 0.05 {
        return
    }
    c := cola(lerp(l.sky_mid, vec3(0.08, 0.06, 0.12), 0.7), l.day)
    for i in 0..BIRDS {
        b := &w.birds[i]
        f := [_]i64{0, 1, 2, 1}[i64(b.phase) % 4]
        src := vec4(f32(96 + f * BIRD_W), 32.0, f32(BIRD_W), f32(BIRD_H))
        if w.flock_dir < 0.0 {
            src = vec4(src.x + src.z, src.y, -src.z, src.w)
        }
        g.sprite(a.misc, src, vec4(floor(b.pos.x), floor(b.pos.y), f32(BIRD_W), f32(BIRD_H)), c)
    }
}

// ---- the playfield

priv const FLOWER_COLS = [_]u32{0xff7aa8, 0xffe066, 0xf4f4ff, 0x92b8ff, 0xff9a40}
priv const GRASS_LO: u32 = 0x4c9a44
priv const GRASS_HI: u32 = 0x9cd650

fn draw_ground(g: *Gfx, a: *Art, w: *World, l: *Light, cam: vec2) {
    seed := w.seed
    amb := col(l.amb)
    tx0 := tile_x(cam.x) - 4
    tx1 := tile_x(cam.x + f32(VIEW_W)) + 4
    bottom := tile_x(cam.y + f32(VIEW_H)) + 1
    // props stand behind everything else of the playfield
    for tx in tx0..=tx1 {
        d := deco_at(tx, seed)
        k := match d {
            Tree(v) => v
            Bush(v) => 8 + v
            Rock(v) => 11 + v
            NoDeco => -1
        }
        if k < 0 {
            continue
        }
        pr := a.props.list[k]
        base := surface_y(tx, seed) + 2.0
        dst := vec4(f32(tx * TILE + TILE / 2) - floor(pr.src.z * 0.5) - cam.x, base - pr.src.w - cam.y, pr.src.z, pr.src.w)
        mirror := noise_hash(tx, 9, 9, seed) % 2 == 0
        for m in 0..len(PROP_MATS) {
            if pr.mats & (u32(1) << u32(m)) != 0 {
                draw_masks(g, a.props.tex, a.props.h, m, pr.src, dst, cols_of(4, PROP_MATS[m], l), l.from_right, 1.0, mirror)
            }
        }
    }
    // the ground, auto-tiled: a tile's sides are open where the neighbour column is lower
    for tx in tx0..=tx1 {
        if is_lake(tx, seed) {
            continue
        }
        top := GROUND_Y / TILE - height(tx, seed)
        hl := if is_lake(tx - 1, seed) { 99 } else { height(tx - 1, seed) }
        hr := if is_lake(tx + 1, seed) { 99 } else { height(tx + 1, seed) }
        for ty in top..=bottom {
            row := GROUND_Y / TILE - ty                  // height of this row
            left := hl == 99 || row > hl
            right := hr == 99 || row > hr
            v := i64(noise_hash(tx, ty, 0, seed) % 6)
            i := tile_index(ty == top, ty - top - 1, left, right, v)
            g.sprite(a.tiles, tile_src(i), vec4(f32(tx * TILE) - cam.x, f32(ty * TILE - 4) - cam.y, f32(TILE), f32(TILE_CELL_H)), amb)
        }
    }
    draw_bridges(g, w, l, cam)
}

fn draw_bridges(g: *Gfx, w: *World, l: *Light, cam: vec2) {
    seg0 := tile_x(cam.x) / SEG - 1
    for s in seg0..=seg0 + 2 {
        lk := lake_of(s * SEG + 1, w.seed)
        if lk.end <= lk.start {
            continue
        }
        deck := f32(GROUND_Y - lk.shore * TILE) - cam.y
        x0 := f32(lk.start * TILE) - cam.x - 2.0
        x1 := f32(lk.end * TILE) - cam.x + 2.0
        if x1 < 0.0 || x0 > f32(VIEW_W) {
            continue
        }
        dark := col(rgb(0x3a2228) * l.amb)
        wood := col(rgb(0x9a6a3e) * lerp(l.amb, l.rim, 0.4))
        wood_hi := col(rgb(0xc8945a) * l.rim)
        rope := col(rgb(0xb89a6a) * lerp(l.amb, l.rim, 0.4))
        // posts every 5 columns, standing in the water
        px := x0
        while px <= x1 {
            g.rect(vec4(floor(px), deck - 8.0, 2.0, 30.0), dark)
            g.rect(vec4(floor(px), deck - 8.0, 1.0, 30.0), wood)
            px += f32(5 * TILE)
        }
        // planks
        x := x0
        while x < x1 {
            g.rect(vec4(floor(x), deck, 4.0, 2.0), wood)
            g.rect(vec4(floor(x), deck, 3.0, 1.0), wood_hi)
            g.rect(vec4(floor(x) + 3.0, deck, 1.0, 2.0), dark)
            x += 4.0
        }
        g.rect(vec4(floor(x0), deck + 2.0, floor(x1 - x0), 1.0), dark)
        // the hand rope sags between the posts
        px = x0
        while px + f32(5 * TILE) <= x1 + 0.5 {
            for i in 0..40 {
                f := f32(i) / 40.0
                sag := sin(f * PI) * 3.0
                g.rect(vec4(floor(px + 1.0 + f * f32(5 * TILE)), floor(deck - 7.0 + sag), 1.0, 1.0), rope)
            }
            px += f32(5 * TILE)
        }
    }
}

fn draw_grass(g: *Gfx, w: *World, l: *Light, cam: vec2, hero: vec2) {
    seed := w.seed
    t := f32(w.time)
    lo := lerp(l.amb, l.rim, 0.3)
    tx0 := tile_x(cam.x) - 1
    tx1 := tile_x(cam.x + f32(VIEW_W)) + 1
    for tx in tx0..=tx1 {
        if is_lake(tx, seed) {
            continue
        }
        base := surface_y(tx, seed) - cam.y
        for k in 0..4 {
            h := noise_hash(tx, k, 3, seed)
            bx := f32(tx * TILE) + f32(h % 8)
            if h % 3 == 0 && k > 1 {
                continue
            }
            tall := 2.0 + f32((h / 8) % 4)
            sway := w.wind * 1.2 + sin(t * 2.4 + bx * 0.23) * 0.8
            dx := bx - hero.x
            if fabs(dx) < 6.0 && fabs(hero.y - surface_y(tx, seed)) < 4.0 {
                sway += sign(dx) * (6.0 - fabs(dx)) * 0.7
            }
            sway *= tall / 5.0
            sx := bx - cam.x
            c := col(rgb(if k % 2 == 0 { GRASS_HI } else { GRASS_LO }) * lo)
            for j in 0..i64(tall) {
                f := (f32(j) + 1.0) / tall
                g.rect(vec4(floor(sx + sway * f * f), base - 1.0 - f32(j), 1.0, 1.0), c)
            }
            // a flower on some of the blades
            if (h / 64) % 9 == 0 {
                fc := rgb(FLOWER_COLS[i64((h / 640) % 5)]) * lerp(l.amb, l.rim, 0.5)
                fx := floor(sx + sway)
                fy := base - 1.0 - tall
                g.rect(vec4(fx - 1.0, fy, 3.0, 1.0), col(fc))
                g.rect(vec4(fx, fy - 1.0, 1.0, 3.0), col(fc))
                g.rect(vec4(fx, fy, 1.0, 1.0), col(rgb(0xfff4a0) * l.amb))
            }
        }
    }
}

fn hero_frame(h: *Hero) -> vec4 {
    if !h.on_ground {
        f := if h.vel.y < -70.0 { 0 } else if h.vel.y < 70.0 { 1 } else { 2 }
        return vec4(f32(f * HERO_W), f32(2 * HERO_H), f32(HERO_W), f32(HERO_H))
    }
    if fabs(h.vel.x) > 8.0 {
        f := i64(h.anim) % RUN_FRAMES
        return vec4(f32(f * HERO_W), f32(HERO_H), f32(HERO_W), f32(HERO_H))
    }
    f := i64(h.anim * 0.5) % IDLE_FRAMES
    vec4(f32(f * HERO_W), 0.0, f32(HERO_W), f32(HERO_H))
}

fn draw_hero(g: *Gfx, a: *Art, w: *World, l: *Light, cam: vec2, pos: vec2) {
    src := hero_frame(&w.hero)
    if w.hero.facing < 0.0 {
        src = vec4(src.x + src.z, src.y, -src.z, src.w)
    }
    p := vec2(floor(pos.x + 0.5) - cam.x, floor(pos.y + 0.5) - cam.y)
    // a soft shadow on the ground
    gy := ground_under(pos.x, HERO_HALF, w.seed) - cam.y
    sh := clamp(1.0 - (gy - p.y) / 40.0, 0.0, 1.0)
    g.rect(vec4(p.x - 4.0, gy - 1.0, 8.0, 1.0), cola(vec3(0.05, 0.03, 0.1), 0.45 * sh))
    tint := lerp(l.amb, vec3(1.0), 0.3)
    g.sprite(a.hero, src, vec4(p.x - f32(HERO_W / 2), p.y - f32(HERO_H) + 1.0, f32(HERO_W), f32(HERO_H)), col(tint))
}

// The whole world into the scene texture.
fn draw_scene(g: *Gfx, a: *Art, w: *World, l: *Light, alpha: f32) {
    g.set_target(a.scene)
    cam := lerp(w.prev_cam, w.cam, alpha)
    cam = vec2(floor(cam.x + 0.5), floor(cam.y + 0.5))
    hero := lerp(w.prev_pos, w.hero.pos, alpha)
    draw_sky(g, a, w, l)
    draw_clouds(g, a, w, l, cam.x)
    // the parallax strips, far to near; each sinks into the haze at its foot
    draw_strip(g, &a.far, 0, l, cam.x * 0.05, 58.0 - cam.y * 0.05)
    haze(g, a, 150.0 - cam.y * 0.05, l.fog, 0.5)
    draw_strip(g, &a.mid, 1, l, cam.x * 0.12, 108.0 - cam.y * 0.12)
    haze(g, a, 168.0 - cam.y * 0.12, lerp(l.fog, l.sky_hor, 0.3), 0.4)
    draw_birds(g, a, w, l)
    draw_strip(g, &a.hills, 2, l, cam.x * 0.25, 144.0 - cam.y * 0.25)
    draw_strip(g, &a.forest, 3, l, cam.x * 0.5, 130.0 - cam.y * 0.5)
    draw_ground(g, a, w, l, cam)
    draw_hero(g, a, w, l, cam, hero)
    draw_grass(g, w, l, cam, hero)
    if w.rain_k > 0.0 {
        g.rect(vec4(0.0, 0.0, f32(VIEW_W), f32(VIEW_H)), cola(vec3(0.18, 0.2, 0.28), w.rain_k * 0.3))
    }
    g.reset_target()
}

// ---- the second pass

fn draw_lakes(g: *Gfx, a: *Art, w: *World, l: *Light, cam: vec2) {
    t := f32(w.time)
    seg0 := tile_x(cam.x) / SEG - 1
    for s in seg0..=seg0 + 2 {
        lk := lake_of(s * SEG + 1, w.seed)
        if lk.end <= lk.start {
            continue
        }
        x0 := fmax(0.0, f32(lk.start * TILE) - cam.x)
        x1 := fmin(f32(VIEW_W), f32(lk.end * TILE) - cam.x)
        wy := floor(water_y(lk) - cam.y)
        if x1 <= x0 || wy >= f32(VIEW_H) {
            continue
        }
        ww := x1 - x0
        // the reflection: row by row, mirrored about the water line, rippled
        y := wy
        while y < f32(VIEW_H) {
            dy := y - wy
            sy := fmax(0.0, wy - 1.0 - dy)
            wave := sin(dy * 0.8 - t * 2.6) + sin(dy * 0.27 + t * 1.4) * 0.6
            off := round(wave * fmin(1.8, 0.2 + dy * 0.05))
            k := 1.0 - fmin(dy / 90.0, 1.0) * 0.45
            tint := lerp(vec3(0.62, 0.76, 0.86), l.sky_hor, 0.25) * k
            g.sprite(a.scene, vec4(x0 + off, sy, ww, 1.0), vec4(x0, y, ww, 1.0), col(tint))
            y += 1.0
        }
        // water colour deepening with depth, in dithered steps
        deep := lerp(rgb(0x123850), l.sky_top, 0.3) * lerp(l.amb, vec3(1.0), 0.3)
        g.rect(vec4(x0, wy, ww, f32(VIEW_H) - wy), cola(deep, 0.16))
        for b in 0..3 {
            yb := wy + 14.0 + f32(b) * 16.0
            g.sprite(a.misc, vec4(0.0, f32(RAMP8_Y), ww, 8.0), vec4(x0, yb, ww, 8.0), cola(deep, 0.22))
            g.rect(vec4(x0, yb + 8.0, ww, f32(VIEW_H) - yb - 8.0), cola(deep, 0.22))
        }
        // the bright edge of the water
        g.rect(vec4(x0, wy, ww, 1.0), cola(lerp(l.sky_hor, vec3(1.0), 0.4), 0.55))
        // glints on the path of the sun (or moon)
        g.set_blend(BlendAdd)
        sun_up := l.sun.y < HORIZON_Y
        src := if sun_up { l.sun } else { l.moon }
        gc := if sun_up { l.sun_col } else { vec3(0.7, 0.78, 1.0) }
        strength := if sun_up { l.day } else { l.night * 0.6 }
        slot := i64(t * 5.0)
        for k in 0..18 {
            h := noise_hash(k, slot + k / 3, 4, w.seed)
            dy := f32(1 + i64(h % 40))
            gx := floor(src.x + (f32((h / 64) % 64) - 32.0) * (0.3 + dy * 0.03))
            if gx < x0 || gx > x1 - 3.0 || wy + dy >= f32(VIEW_H) {
                continue
            }
            g.rect(vec4(gx, wy + dy, f32(2 + (h / 8) % 3), 1.0), cola(gc, strength * 0.7))
        }
        g.set_blend(BlendAlpha)
        // ripples: flattened rings that widen and fade
        for i in 0..RIPPLES {
            r := &w.ripples[i]
            if r.age > 1.4 {
                continue
            }
            rx := r.pos.x - cam.x
            ry := floor(r.pos.y - cam.y)
            if rx < x0 || rx > x1 {
                continue
            }
            rad := 1.0 + r.age * 9.0
            c := cola(lerp(l.sky_hor, vec3(1.0), 0.5), 0.6 * (1.0 - r.age / 1.4))
            g.rect(vec4(floor(rx - rad), ry, 2.0, 1.0), c)
            g.rect(vec4(floor(rx + rad) - 1.0, ry, 2.0, 1.0), c)
            g.rect(vec4(floor(rx - rad * 0.6), ry - 1.0, floor(rad * 1.2) + 1.0, 1.0), c)
            g.rect(vec4(floor(rx - rad * 0.6), ry + 1.0, floor(rad * 1.2) + 1.0, 1.0), cola(vec3(0.0, 0.05, 0.1), 0.3 * (1.0 - r.age / 1.4)))
        }
    }
}

fn draw_particles(g: *Gfx, a: *Art, w: *World, l: *Light, cam: vec2) {
    t := f32(w.time)
    // falling leaves
    leaf_cols := [_]u32{0xe8a040, 0xd05a2a, 0xf0d060, 0x8ab040}
    for i in 0..LEAVES {
        lf := &w.leaves[i]
        p := vec2(floor(lf.pos.x - cam.x), floor(lf.pos.y - cam.y))
        al := if lf.rest > 0.0 { fmin(1.0, lf.rest) } else { 1.0 }
        if sin(lf.spin) > 0.0 {
            g.rect(vec4(p.x, p.y, 2.0, 1.0), cola(rgb(leaf_cols[lf.kind]) * lerp(l.amb, l.rim, 0.5), al))
        } else {
            g.rect(vec4(p.x, p.y, 1.0, 2.0), cola(rgb(leaf_cols[lf.kind]) * l.amb, al))
        }
    }
    // rain: slanted two-pixel steps
    if w.rain_k > 0.0 {
        rc := cola(lerp(l.sky_hor, vec3(0.8, 0.85, 1.0), 0.5), 0.55 * w.rain_k)
        for i in 0..DROPS {
            d := &w.drops[i]
            if f32(i) > f32(DROPS) * w.rain_k {
                break
            }
            p := vec2(floor(d.pos.x - cam.x), floor(d.pos.y - cam.y))
            g.rect(vec4(p.x, p.y, 1.0, 3.0), rc)
            g.rect(vec4(p.x - 1.0, p.y - 3.0, 1.0, 3.0), rc)
        }
    }
    // fireflies: a pulsing additive glow and a bright core
    if l.night > 0.05 {
        g.set_blend(BlendAdd)
        for i in 0..FLIES {
            f := &w.flies[i]
            pulse := smoothstep(0.1, 0.9, sin(t * 1.7 * f.speed + f.phase) * 0.5 + 0.5)
            al := l.night * pulse
            if al < 0.02 {
                continue
            }
            p := vec2(floor(f.pos.x - cam.x), floor(f.pos.y - cam.y))
            hs := f32(GLOW_SMALL / 2)
            g.sprite(a.misc, vec4(96.0, 0.0, f32(GLOW_SMALL), f32(GLOW_SMALL)), vec4(p.x - hs, p.y - hs, f32(GLOW_SMALL), f32(GLOW_SMALL)),
                cola(vec3(0.7, 1.0, 0.35), 0.55 * al))
            g.rect(vec4(p.x, p.y, 1.0, 1.0), cola(vec3(1.0, 1.0, 0.75), al))
        }
        g.set_blend(BlendAlpha)
    }
}

// Grass, reeds and ferns right in front of the camera: dark, large, swaying.
fn draw_foreground(g: *Gfx, w: *World, l: *Light, cam: vec2) {
    t := f32(w.time)
    f := 1.4
    fx := cam.x * f
    c0 := col(rgb(0x14281e) * lerp(l.amb, vec3(0.5), 0.25))
    c1 := col(rgb(0x1e3c26) * lerp(l.amb, l.rim, 0.4))
    step := 3
    i0 := i64(floor(fx / f32(step)))
    for i in i0..i0 + VIEW_W / step + 2 {
        wx := f32(i * step)
        n := noise2(wx * 0.011, 9.5, w.seed + 70)
        if n < 0.12 {
            continue
        }
        h := noise_hash(i, 1, 1, w.seed)
        tall := (6.0 + f32(h % 18)) * (0.5 + n * 1.6)
        sx := floor(wx - fx)
        sway := (w.wind * 2.0 + sin(t * 2.0 + wx * 0.07) * 1.4) * tall / 14.0
        c := if h % 3 == 0 { c1 } else { c0 }
        wd := if h % 4 == 0 { 2.0 } else { 1.0 }
        j := 0
        while f32(j) < tall {
            q := f32(j) / tall
            g.rect(vec4(sx + floor(sway * q * q), f32(VIEW_H) - 1.0 - f32(j), wd, 1.0), c)
            j += 1
        }
        // a cattail on the tallest
        if tall > 26.0 && h % 5 == 0 {
            g.rect(vec4(sx + floor(sway) - 1.0, f32(VIEW_H) - tall - 4.0, 3.0, 5.0), col(rgb(0x3a2418) * l.amb))
        }
    }
}

// The second pass: the scene and everything over it, in virtual pixels under `view`.
fn draw_screen(g: *Gfx, a: *Art, w: *World, l: *Light, alpha: f32) {
    cam := lerp(w.prev_cam, w.cam, alpha)
    cam = vec2(floor(cam.x + 0.5), floor(cam.y + 0.5))
    g.sprite(a.scene, vec4(0.0, 0.0, f32(VIEW_W), f32(VIEW_H)), vec4(0.0, 0.0, f32(VIEW_W), f32(VIEW_H)), WHITE)
    draw_lakes(g, a, w, l, cam)
    // the bottom of the picture sinks into shade, so the eye stays on the horizon
    shade := cola(lerp(l.sky_top, vec3(0.02, 0.0, 0.04), 0.7), 0.4)
    g.sprite(a.misc, vec4(0.0, f32(RAMP16_Y), f32(VIEW_W), 16.0), vec4(0.0, f32(VIEW_H) - 34.0, f32(VIEW_W), 16.0), shade)
    g.rect(vec4(0.0, f32(VIEW_H) - 18.0, f32(VIEW_W), 18.0), shade)
    draw_particles(g, a, w, l, cam)
    draw_foreground(g, w, l, cam)
}
