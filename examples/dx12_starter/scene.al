// What a frame of the starter shows, as sprites for render.al: the gas giant and the parallax
// stars over the nebula background, the tumbling rocks, the ship with its engine flames, the
// shots, the particles of fx.al, score pop-ups, the end and pause panels, and the HUD. It
// reads the game and the effects and changes neither.
use "../starter/logic.al"
use "art.al"
use "fx.al"
use "render.al"

const WHITE3 = vec3(1.0, 1.0, 1.0)
const SHOT_BLUE = vec3(0.35, 0.75, 1.0)
const HOT_RED = vec3(1.0, 0.36, 0.24)
const LABEL = vec3(0.50, 0.72, 0.95)
const GOLD = vec3(1.0, 0.86, 0.45)

// ---- text and panels -------------------------------------------------------------------------

// A line of text `size` virtual pixels per em, its capitals' top left corner at (x, y), kerned;
// `mode` SDF_TEXT for the letters, SDF_HALO for the soft light (or shadow) around them.
priv fn glyphs(b: *Batch, a: *Art, x: f32, y: f32, size: f32, text: str, color: vec4, mode: f32) {
    t := &a.text
    k := size / f32(SDF_EM)
    base := y + t.cap * size
    pen := x
    prev := -1
    b.mode = mode
    for c in text {
        g := sdf_glyph(t, c)
        if prev >= 0 {
            pen += f32(kerning(t.font, prev, g.glyph)) * t.scale * k
        }
        if c != ' ' {
            b.sprite(pen + g.xoff * k, base + g.yoff * k, g.w * k, g.h * k, Tile{g.x, g.y, g.w, g.h}, color)
        }
        pen += g.advance * k
        prev = g.glyph
    }
    b.mode = 0.0
}

fn draw_text(b: *Batch, a: *Art, x: f32, y: f32, size: f32, text: str, color: vec4) {
    glyphs(b, a, x, y, size, text, color, SDF_TEXT)
}

fn draw_text_centered(b: *Batch, a: *Art, x: f32, y: f32, size: f32, text: str, color: vec4) {
    draw_text(b, a, x - text_w(&a.text, size, text) / 2.0, y, size, text, color)
}

// Neon text: a halo of `rgb` under a core paler and brighter, `k` 0..1 fades it.
fn draw_neon_centered(b: *Batch, a: *Art, x: f32, y: f32, size: f32, text: str, rgb: vec3, k: f32) {
    x0 := x - text_w(&a.text, size, text) / 2.0
    glyphs(b, a, x0, y, size, text, light(rgb, 0.8 * k), SDF_HALO)
    draw_text(b, a, x0, y, size, text, cover(lerp(rgb, WHITE3, 0.2), k))
}

// Text with a soft dark shadow under it, for the HUD over a busy picture.
priv fn shadowed(b: *Batch, a: *Art, x: f32, y: f32, size: f32, text: str, color: vec4) {
    glyphs(b, a, x + size * 0.04, y + size * 0.06, size, text, cover(vec3(0.0), 0.7 * color.w), SDF_HALO)
    draw_text(b, a, x, y, size, text, color)
}

// A 9-slice of tile t: its corners keep their size, its edges and middle stretch.
priv fn nine(b: *Batch, x: f32, y: f32, w: f32, h: f32, t: Tile, color: vec4) {
    e := f32(PANEL_EDGE)
    v := e / f32(TEXELS)
    xs := [4]f32{x, x + v, x + w - v, x + w}
    ys := [4]f32{y, y + v, y + h - v, y + h}
    us := [4]f32{t.x, t.x + e, t.x + t.w - e, t.x + t.w}
    vs := [4]f32{t.y, t.y + e, t.y + t.h - e, t.y + t.h}
    for j in 0..3 {
        for i in 0..3 {
            b.sprite(xs[i], ys[j], xs[i + 1] - xs[i], ys[j + 1] - ys[j], Tile{us[i], vs[j], us[i + 1] - us[i], vs[j + 1] - vs[j]}, color)
        }
    }
}

// A dark glass panel with a glowing edge of colour `edge`; `k` 0..1 fades it in.
priv fn panel(b: *Batch, a: *Art, cx: f32, cy: f32, w: f32, h: f32, edge: vec3, k: f32) {
    x := cx - w / 2.0
    y := cy - h / 2.0
    nine(b, x, y, w, h, a.panel, cover(vec3(0.025, 0.03, 0.07), 0.86 * k))
    nine(b, x - 2.0, y - 2.0, w + 4.0, h + 4.0, a.panel_line, light(edge, 1.25 * k))
}

// ---- the world -------------------------------------------------------------------------------

// Where an entity is shown: between two steps, and after the end drifting on as it was going.
priv fn shown_at(e: *Entity, alpha: f32, fx: *Fx) -> vec2 { e.pos + e.vel * (alpha / f32(HZ) + fx.over_time) }

priv fn eased(u: f32) -> f32 { 1.0 - (1.0 - u) * (1.0 - u) }

priv fn draw_sky(b: *Batch, a: *Art, fx: *Fx, t: f32) {
    // the stars: three layers that scroll at their own speeds, twinkling
    for s in fx.stars {
        y := fmod(s.pos.y + t * STAR_SPEED[s.layer], f32(WORLD_H) + 6.0) - 3.0
        tw := 0.7 + 0.3 * sin(t * (1.5 + s.phase) + s.phase * 7.0)
        b.quad(vec2(s.pos.x, y), vec2(s.size / 2.0), vec2(1.0, 0.0), a.glow, light(s.tint, s.bright * tw))
        if s.bright > 1.05 {
            b.quad(vec2(s.pos.x, y), vec2(s.size * 1.6), vec2(1.0, 0.0), a.flare, light(s.tint, 0.55 * tw))
        }
    }
    // the gas giant, far below the action, sinking slowly out of view and back in from the top
    py := fmod(150.0 + t * 0.6 + 60.0, 420.0) - 60.0
    b.quad(vec2(34.0, py), vec2(50.0), vec2(1.0, 0.0), a.planet, cover(vec3(0.5), 1.0))
}

priv fn draw_rock(b: *Batch, a: *Art, g: *Game, fx: *Fx, i: i64, t: f32, alpha: f32) {
    e := &g.ents.items[i]
    h := g.ents.handle_at(i)
    seed := noise_hash(i64(h.idx), i64(h.gen), 0, 9)
    kind := i64(seed % u32(ROCK_KINDS))
    spin := (0.10 + f32(seed >> 8 & 255) / 255.0 * 0.22) * (if seed & 0x10000 != 0 { 1.0 } else { -1.0 })
    turn := fract(t * spin + f32(seed >> 20 & 255) / 255.0) * f32(ROCK_FRAMES)
    f0 := i64(turn) % ROCK_FRAMES
    f1 := (f0 + 1) % ROCK_FRAMES
    p := shown_at(e, alpha, fx)
    half := vec2(f32(ROCK_CELL) / 2.0 * e.radius * 1.22 / ROCK_R)
    up := vec2(1.0, 0.0)
    // two neighbouring frames, the second over the first, so the turning is smooth
    b.quad(p, half, up, a.rocks[kind][f0], cover(WHITE3, 1.0))
    b.quad(p, half, up, a.rocks[kind][f1], cover(WHITE3, fract(turn)))
    if e.hp < 2 {
        // cracked: it glows from within and smoulders
        glow := 0.45 + 0.2 * sin(t * 11.0 + f32(seed & 63))
        b.quad(p, half, up, a.rocks[kind][f0], light(vec3(1.0, 0.45, 0.15), glow))
        b.quad(p, vec2(e.radius * 1.8), up, a.glow, light(vec3(1.0, 0.35, 0.1), 0.35 * glow))
    }
    if fx.hit[i] > 0.0 {
        b.quad(p, half, up, a.rocks[kind][f0], light(WHITE3, fx.hit[i] * 2.5))
    }
}

priv fn draw_ship(b: *Batch, a: *Art, e: *Entity, fx: *Fx, t: f32, alpha: f32) {
    p := e.pos + e.vel * (alpha / f32(HZ))
    pose := clamp(i64(round(fx.bank * 2.0)) + 2, 0, SHIP_POSES - 1)
    squash := 1.0 - 0.085 * fabs(f32(pose - 2))
    up := vec2(1.0, 0.0)
    // engine flames: an outer blue tongue and a white core, each flickering on its own
    for side in [_]f32{-1.0, 1.0} {
        nozzle := p + vec2(side * 3.2 * squash, 7.6)
        flick := 0.85 + 0.15 * noise2(t * 23.0, side * 3.0, 11)
        len := (0.75 + 0.65 * fx.thrust) * flick
        frame := (i64(t * 26.0) + (if side > 0.0 { 2 } else { 0 })) % FLAME_FRAMES
        b.quad(nozzle + vec2(0.0, 6.5 * len), vec2(2.8, 7.0 * len), up, a.flame[frame], light(vec3(0.35, 0.5, 1.0), 2.3))
        b.quad(nozzle + vec2(0.0, 3.6 * len), vec2(1.2, 4.0 * len), up, a.flame[(frame + 1) % FLAME_FRAMES], light(vec3(0.85, 0.95, 1.0), 2.8))
        b.quad(nozzle + vec2(0.0, 0.5), vec2(3.2), up, a.glow, light(vec3(0.4, 0.7, 1.0), 0.9))
    }
    half := vec2(f32(SHIP_W), f32(SHIP_H)) / f32(SHIP_TEXELS) / 2.0
    b.quad(p, half, up, a.ship[pose], cover(WHITE3, 1.0))
    if fx.hurt > 0.0 {
        b.quad(p, half, up, a.ship[pose], light(vec3(1.0, 0.6, 0.5), fx.hurt * 1.3))
    }
    // navigation lights on the wing tips, blinking
    blink := if fract(t * 1.1) < 0.12 { 2.4 } else { 0.5 }
    tip := 7.3 * squash
    b.quad(p + vec2(-tip, 5.4), vec2(2.0), up, a.glow, light(vec3(1.0, 0.25, 0.2), blink))
    b.quad(p + vec2(tip, 5.4), vec2(2.0), up, a.glow, light(vec3(0.3, 1.0, 0.45), blink))
    if fx.muzzle > 0.0 {
        b.quad(p + vec2(0.0, -10.0), vec2(2.5 * fx.muzzle + 1.5), up, a.glow, light(vec3(0.5, 0.85, 1.0), 1.5 * fx.muzzle))
    }
}

priv fn draw_shot(b: *Batch, a: *Art, e: *Entity, fx: *Fx, alpha: f32) {
    p := shown_at(e, alpha, fx)
    dir := normalize(e.vel)
    b.quad(p - dir * 7.0, vec2(8.0, 1.3), dir, a.streak, light(SHOT_BLUE, 1.3))
    b.quad(p, vec2(5.0), vec2(1.0, 0.0), a.glow, light(vec3(0.2, 0.5, 1.0), 0.8))
    b.quad(p, vec2(1.7, 4.2), vec2(1.0, 0.0), a.bolt, light(vec3(0.45, 0.85, 1.0), 2.2))
    b.quad(p, vec2(0.7, 3.2), vec2(1.0, 0.0), a.bolt, light(WHITE3, 2.6))
}

// The game's own sparks (its bursts), as short streaks of their colour.
priv fn draw_spark(b: *Batch, a: *Art, e: *Entity, alpha: f32) {
    p := e.pos + e.vel * (alpha / f32(HZ))
    k := saturate(e.life / 0.25)
    c := color_vec4(e.color).xyz
    speed := length(e.vel)
    dir := if speed > 0.0 { e.vel / speed } else { vec2(1.0, 0.0) }
    b.quad(p - dir * (1.0 + speed * 0.02), vec2(1.5 + speed * 0.025, 0.9), dir, a.streak, light(c, 2.6 * k))
    b.quad(p, vec2(2.5), vec2(1.0, 0.0), a.glow, light(c, 0.5 * k))
}

priv fn draw_particle(b: *Batch, a: *Art, q: *Particle) {
    u := q.age / q.life
    size := lerp(q.size0, q.size1, eased(u))
    c := lerp(q.c0, q.c1, u)
    turn := vec2(cos(q.angle), sin(q.angle))
    match q.look {
        LookGlow => b.quad(q.pos, vec2(size / 2.0), vec2(1.0, 0.0), a.glow, c)
        LookFire => b.quad(q.pos, vec2(size / 2.0), turn, a.fire[q.variant], c)
        LookRing => b.quad(q.pos, vec2(size / 2.0), vec2(1.0, 0.0), a.ring, c)
        LookStreak => {
            speed := length(q.vel)
            dir := if speed > 0.001 { q.vel / speed } else { vec2(1.0, 0.0) }
            long := size * (0.4 + fmin(speed * 0.012, 1.2))
            b.quad(q.pos - dir * long * 0.5, vec2(long, size * 0.16 + 0.5), dir, a.streak, c)
        }
        LookSmoke => b.quad(q.pos, vec2(size / 2.0), turn, a.smoke[q.variant], c)
        LookDebris => {
            fade := 1.0 - smoothstep(0.65, 1.0, u)
            b.quad(q.pos, vec2(size / 2.0), turn, a.chips[q.variant], cover(vec3(0.85, 0.8, 0.75), fade))
            if u < 0.4 {
                b.quad(q.pos, vec2(size / 2.0), turn, a.chips[q.variant], light(vec3(1.0, 0.5, 0.15), (1.0 - u / 0.4) * 1.6))
            }
        }
    }
}

// ---- the frame -------------------------------------------------------------------------------

// Adds the sprites of a frame to the batch and returns the post-processing settings for it.
// `alpha` is how far the display is between two simulation steps.
fn draw_frame(b: *Batch, a: *Art, g: *Game, fx: *Fx, alpha: f32, paused: bool, note: str) -> Post {
    t := f32(fmod(fx.time, 4096.0))
    draw_sky(b, a, fx, t)
    b.offset = shake_offset(fx)
    for i in 0..g.ents.used {
        if g.ents.is_live(i) && g.ents.items[i].kind == Rock {
            draw_rock(b, a, g, fx, i, t, alpha)
        }
    }
    // what covers first (debris, smoke), then what adds light
    for k in 0..fx.n {
        look := fx.parts[k].look
        if look == LookDebris || look == LookSmoke {
            draw_particle(b, a, &fx.parts[k])
        }
    }
    p := g.ents.get(g.player)
    if p != nil {
        draw_ship(b, a, p, fx, t, alpha)
    }
    for i in 0..g.ents.used {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        if e.kind == Shot {
            draw_shot(b, a, e, fx, alpha)
        } else if e.kind == Spark && !g.over {
            draw_spark(b, a, e, alpha)
        }
    }
    for k in 0..fx.n {
        look := fx.parts[k].look
        if look != LookDebris && look != LookSmoke {
            draw_particle(b, a, &fx.parts[k])
        }
    }
    b.offset = vec2(0.0)
    cx := f32(WORLD_W) / 2.0
    if g.over {
        k := smoothstep(0.15, 0.75, fx.over_time)
        b.rect(0.0, 0.0, f32(WORLD_W), f32(WORLD_H), cover(vec3(0.01, 0.0, 0.03), 0.5 * k))
        panel(b, a, cx, 92.0, 212.0, 92.0, HOT_RED, k)
        draw_neon_centered(b, a, cx, 55.0, 30.0, "GAME OVER", HOT_RED, k)
        draw_text_centered(b, a, cx, 85.0, 10.0, "FINAL SCORE", cover(LABEL, k))
        draw_text_centered(b, a, cx, 98.0, 20.0, fmt(g.score), cover(GOLD, k))
        blink := 0.75 + 0.25 * sin(t * 4.0)
        draw_text_centered(b, a, cx, 121.0, 9.5, "Fire to play again, Escape to quit", cover(vec3(0.75, 0.8, 0.92), k * blink))
    }
    if paused {
        b.rect(0.0, 0.0, f32(WORLD_W), f32(WORLD_H), cover(vec3(0.0, 0.0, 0.02), 0.45))
        panel(b, a, cx, 90.0, 200.0, 56.0, SHOT_BLUE, 1.0)
        draw_neon_centered(b, a, cx, 73.0, 30.0, "PAUSED", SHOT_BLUE, 1.0)
        draw_text_centered(b, a, cx, 101.0, 9.5, "Click the window to go on", cover(vec3(0.75, 0.8, 0.92), 1.0))
    }
    batch_hud(b)
    // score pop-ups: crisp over the explosions they come from
    for pop in fx.popups {
        if pop.age < 0.9 {
            k := 1.0 - smoothstep(0.45, 0.9, pop.age)
            s := 11.0 + 5.0 * (1.0 - smoothstep(0.0, 0.15, pop.age))
            y := fmax(pop.pos.y - 10.0, 30.0) - pop.age * 16.0
            text := fmt("+", pop.value)
            shadowed(b, a, pop.pos.x - text_w(&a.text, s, text) / 2.0, y, s, text, cover(GOLD, k))
        }
    }
    draw_hud(b, a, g, fx, t, note)
    Post{
        time: t, bloom: 1.0, exposure: 1.0, flash: fx.flash * 0.6, flash_color: vec3(1.0, 0.08, 0.04),
        fringe: fx.shake * fx.shake * 1.6, desaturate: if paused { 0.4 } else if g.over { 0.15 * smoothstep(0.0, 1.0, fx.over_time) } else { 0.0 },
    }
}

// Score top left, the hull as ship icons top right, a note about the sound device bottom left.
priv fn draw_hud(b: *Batch, a: *Art, g: *Game, fx: *Fx, t: f32, note: str) {
    shadowed(b, a, 8.0, 6.0, 10.0, "SCORE", cover(LABEL, 1.0))
    s := 21.0 + 4.0 * fx.pulse
    gold := lerp(WHITE3, GOLD, fx.pulse)
    shadowed(b, a, 8.0, 17.0 - (s - 21.0) * 0.7, s, fmt(i64(round(fx.score))), cover(gold, 1.0))
    right := f32(WORLD_W) - 8.0
    shadowed(b, a, right - text_w(&a.text, 10.0, "HULL"), 6.0, 10.0, "HULL", cover(LABEL, 1.0))
    hp := player_hp(g)
    icon := vec2(f32(SHIP_W), f32(SHIP_H)) / f32(SHIP_TEXELS) * 0.55
    for k in 0..3 {
        x := right - icon.x / 2.0 - f32(k) * (icon.x + 2.0)
        c := vec2(x, 15.0 + icon.y / 2.0)
        if k < hp {
            danger := hp == 1 && fract(t * 2.5) < 0.5
            b.quad(c + vec2(0.6), icon / 2.0, vec2(1.0, 0.0), a.ship[2], cover(vec3(0.0), 0.5))
            b.quad(c, icon / 2.0, vec2(1.0, 0.0), a.ship[2], cover(if danger { vec3(1.0, 0.45, 0.4) } else { WHITE3 }, 1.0))
        } else {
            b.quad(c, icon / 2.0, vec2(1.0, 0.0), a.ship[2], cover(vec3(0.25, 0.3, 0.45), 0.35))
        }
    }
    if note != "" {
        shadowed(b, a, 6.0, f32(WORLD_H) - 12.0, 9.5, note, cover(vec3(1.0, 0.75, 0.4), 1.0))
    }
}
