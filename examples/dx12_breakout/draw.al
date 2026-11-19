// What a frame of the breakout shows: the playfield in its neon frame, the wall of glass
// bricks, paddle, ball and effects, the score line, and the title screen, pause menu and game
// over screen, as sprites of render.al's batch. Reads the game and the effects; changes
// neither.
use "logic.al"
use "sheet.al"
use "render.al"
use "fx.al"

const CYAN = vec3(0.30, 0.92, 1.0)
const MAGENTA = vec3(1.0, 0.22, 0.68)
const VIOLET = vec3(0.55, 0.30, 1.0)
const GOLD = vec3(1.0, 0.80, 0.30)
const INK = vec3(1.0, 1.0, 1.0)
const DIM = vec3(0.58, 0.56, 0.78)
const NIGHT = vec3(0.03, 0.02, 0.08)

// The look of the frame apart from the sprites (render.al's background and composite).
fn make_look(g: *Game, fx: *Fx) -> Look {
    tint := match g.mode { Paused => vec3(0.75, 0.75, 0.9); GameOver => vec3(1.0, 0.55, 0.62); _ => vec3(1.0) }
    flash := vec4(1.0, 0.12, 0.10, 0.30 * fx.lost_flash * fx.lost_flash)
    if fx.clear_flash > 0.0 {
        flash = vec4(0.6, 0.85, 1.0, 0.16 * fx.clear_flash * fx.clear_flash)
    }
    Look{time: f32(fx.time), shake: fx.shake_off, ripple: fx.ripple, field: vec4(FIELD_L, FIELD_T, FIELD_R, f32(VIEW_H) + 40.0),
        tint: tint, flash: flash, bloom: 1.0}
}

// The whole frame. `alpha`: how far between the last two steps (for the paddle and the ball).
fn draw_frame(b: *Batch, g: *Game, fx: *Fx, alpha: f32, note: str) {
    t := f32(fx.time)
    ball := ball_at(g, alpha)
    // the playfield shakes; the text over it does not
    b.cam = fx.shake_off
    draw_bricks(b, g, fx)
    draw_parts(b, fx, true)
    if g.mode == Title {
        // the title screen plays by itself
        draw_paddle(b, fx, clamp(fx.demo.x, FIELD_L + PADDLE_W / 2.0, FIELD_R - PADDLE_W / 2.0))
        draw_ball(b, fx, fx.demo, false)
    } else {
        draw_paddle(b, fx, lerp(g.paddle_prev, g.paddle, alpha))
        draw_ball(b, fx, ball, g.stuck)
    }
    draw_parts(b, fx, false)
    draw_game_sparks(b, g)
    draw_walls(b, fx, t)
    draw_popups(b, fx)
    b.cam = vec2(0.0)
    draw_hud(b, g, fx)
    cx := f32(VIEW_W) / 2.0
    match g.mode {
        Title => draw_title(b, g, fx)
        Playing => {
            if g.banner > 0.0 {
                draw_banner(b, g, fx)
            } else if g.stuck {
                k := 0.5 + 0.5 * sin(t * 5.0)
                centered(b, cx, 128.0, 1.0, "SPACE OR A TO LAUNCH", paint(INK, 0.55 + 0.45 * k), CYAN, 0.25 + 0.3 * k)
            }
        }
        Paused => draw_menu(b, g, fx)
        GameOver => draw_game_over(b, g, fx)
    }
    if note != "" {
        text(b, 4.0, f32(VIEW_H) - 10.0, 1.0, note, paint(vec3(0.5, 0.8, 1.0), 1.0), paint(vec3(0.5, 0.8, 1.0), 1.0), 0.0, 0.0, 0.0)
    }
}

// Where the ball is drawn.
fn ball_at(g: *Game, alpha: f32) -> vec2 {
    if g.mode == Playing && !g.stuck { lerp(g.ball_prev, g.ball, alpha) } else { g.ball }
}

// ---- text helpers ----------------------------------------------------------------------------

// A line of neon text centred on x: a soft glow of `halo` (strength k), then the glyphs.
fn centered(b: *Batch, x: f32, y: f32, size: f32, s: str, ink: vec4, halo: vec3, k: f32) {
    x0 := floor(x - text_w(s, size, 0.0) / 2.0)
    if k > 0.0 {
        text(b, x0, y, size, s, glow(halo, k), glow(halo, k), 0.0, 1.8, 0.0)
    }
    text(b, x0, y, size, s, ink, ink, 0.05, 0.0, 0.0)
}

// The same, starting at x.
fn left_text(b: *Batch, x: f32, y: f32, size: f32, s: str, ink: vec4, halo: vec3, k: f32) {
    if k > 0.0 {
        text(b, x, y, size, s, glow(halo, k), glow(halo, k), 0.0, 1.8, 0.0)
    }
    text(b, x, y, size, s, ink, ink, 0.05, 0.0, 0.0)
}

// Big letters: a wide glow behind, a dark outline, a hot rim, a gradient fill, each letter
// bobbing a little, and a band of light sweeping over them.
fn headline(b: *Batch, cx: f32, y: f32, size: f32, s: str, top: vec3, bottom: vec3, halo: vec3, t: f32, on: f32) {
    spacing: f32 = 0.6
    w := text_w(s, size, spacing)
    x0 := floor(cx - w / 2.0)
    sweep := fmod(t * 0.45, 2.2) * (w + 80.0) - 40.0
    for i in 0..len(s) {
        ch := s[i..i + 1]
        lx := x0 + (if i == 0 { 0.0 } else { text_pen(s, i - 1, spacing) }) * size
        ly := y + sin(t * 2.2 + f32(i) * 0.7) * size * 0.35
        text(b, lx, ly, size, ch, glow(halo, 0.55 * on), glow(halo, 0.35 * on), 0.0, 2.0, 0.0)
        text(b, lx + size * 0.35, ly + size * 0.45, size, ch, paint(NIGHT, 0.8 * on), paint(NIGHT, 0.8 * on), 0.55, 0.0, 0.0)
        text(b, lx, ly, size, ch, paint(vec3(0.10, 0.02, 0.18), on), paint(vec3(0.10, 0.02, 0.18), on), 0.7, 0.0, 0.0)
        text(b, lx, ly, size, ch, paint(lerp(halo, vec3(1.0), 0.3) * 1.6, on), paint(halo * 1.4, on), 0.28, 0.0, 0.0)
        text(b, lx, ly, size, ch, paint(top, on), paint(bottom, on), 0.0, 0.0, 0.0)
        shine := exp(-(lx + 3.0 * size - sweep) * (lx + 3.0 * size - sweep) / 900.0)
        if shine > 0.02 {
            text(b, lx, ly, size, ch, glow(vec3(1.0), 0.9 * shine * on), glow(vec3(1.0), 0.3 * shine * on), 0.0, 0.0, 0.0)
        }
    }
}

// A glass panel with a glowing edge.
fn glass(b: *Batch, x: f32, y: f32, w: f32, h: f32, edge: vec3, k: f32) {
    panel(b, TILE_PANEL, x, y, w, h, 8.0, paint(vec3(0.09, 0.07, 0.20), 0.95), paint(vec3(0.03, 0.02, 0.08), 0.97))
    panel(b, TILE_EDGE, x - 1.5, y - 1.5, w + 3.0, h + 3.0, 9.0, glow(edge, 0.9 * k), glow(edge, 0.55 * k))
}

// ---- the playfield ---------------------------------------------------------------------------

// The neon tubes run cyan at the bottom of the side walls to magenta along the top.
fn tube_color(y: f32) -> vec3 {
    k := clamp((y - FIELD_T) / (f32(VIEW_H) - FIELD_T), 0.0, 1.0)
    lerp(MAGENTA, CYAN, k)
}

// The frame: metal rails with neon tubes, a light where the ball touched it, corner blocks.
fn draw_walls(b: *Batch, fx: *Fx, t: f32) {
    bottom := f32(VIEW_H) + 2.0
    top := FIELD_T - 3.0
    // the rails: the top one, and the side ones with their inner side towards the field
    strip(b, TILE_RAIL, vec2(FIELD_L - 6.0, top), vec2(FIELD_R + 6.0, top), 6.0, paint(INK, 1.0))
    strip(b, TILE_RAIL, vec2(FIELD_L - 3.0, bottom), vec2(FIELD_L - 3.0, top), 6.0, paint(INK, 1.0))
    strip(b, TILE_RAIL, vec2(FIELD_R + 3.0, top), vec2(FIELD_R + 3.0, bottom), 6.0, paint(INK, 1.0))
    // the tubes in their channels, in pieces to colour them along their length
    pulse := 0.85 + 0.15 * sin(t * 1.7)
    ty := FIELD_T - 1.25
    lx := FIELD_L - 1.25
    rx := FIELD_R + 1.25
    n := 10
    for k in 0..n {
        y0 := lerp(bottom, ty, f32(k) / f32(n))
        y1 := lerp(bottom, ty, f32(k + 1) / f32(n))
        tube(b, vec2(lx, y0), vec2(lx, y1), tube_color(y0), tube_color(y1), pulse)
        tube(b, vec2(rx, y0), vec2(rx, y1), tube_color(y0), tube_color(y1), pulse)
    }
    tube(b, vec2(lx, ty), vec2(rx, ty), MAGENTA, MAGENTA, pulse)
    // a light running along the top tube now and then
    run := fmod(t * 0.35, 3.0)
    if run < 1.0 {
        x := lerp(FIELD_L, FIELD_R, run)
        sprite(b, TILE_GLOW, x - 10.0, ty - 5.0, 20.0, 10.0, glow(vec3(1.0, 0.6, 0.9), 0.9 * sin(run * 3.1416)))
    }
    // where the ball touched the wall
    if fx.wall_flash > 0.0 {
        p := fx.wall_hit
        s := 10.0 + 10.0 * (1.0 - fx.wall_flash)
        sprite(b, TILE_GLOW, p.x - s, p.y - s, 2.0 * s, 2.0 * s, glow(vec3(1.0, 0.55, 0.95), 1.4 * fx.wall_flash))
    }
    // the corner blocks
    sprite(b, TILE_CORNER, FIELD_L - 8.0, FIELD_T - 8.0, 8.0, 8.0, paint(INK, 1.0))
    sprite(b, TILE_CORNER, FIELD_R, FIELD_T - 8.0, 8.0, 8.0, paint(INK, 1.0))
    sprite(b, TILE_GLOW, FIELD_L - 9.0, FIELD_T - 9.0, 10.0, 10.0, glow(MAGENTA, 0.8 * pulse))
    sprite(b, TILE_GLOW, FIELD_R - 1.0, FIELD_T - 9.0, 10.0, 10.0, glow(MAGENTA, 0.8 * pulse))
}

// A piece of neon tube from p0 to p1: a wide soft halo, then the hot core.
fn tube(b: *Batch, p0: vec2, p1: vec2, c0: vec3, c1: vec3, k: f32) {
    strip2(b, TILE_BEAM, p0, p1, 14.0, glow(c0, 0.75 * k), glow(c1, 0.75 * k))
    strip2(b, TILE_BEAM, p0, p1, 4.0, glow(lerp(c0, vec3(1.0), 0.45), 2.4 * k), glow(lerp(c1, vec3(1.0), 0.45), 2.4 * k))
}

// The wall: shadows and halos, then the glass bricks with their armour or cracks and lit edges;
// a brick flashes when it is hit.
fn draw_bricks(b: *Batch, g: *Game, fx: *Fx) {
    t := f32(fx.time)
    layout := LEVELS[(max(g.level, 1) - 1) % len(LEVELS)]
    // a glint sweeps diagonally over the wall every few seconds
    glint_x := fmod(t * 90.0, 900.0) - 150.0
    // shadows and the light the bricks give off, then the bricks, so no shadow falls on a brick
    for pass in 0..2 {
        for i in 0..ROWS * COLS {
            hp := g.bricks[i]
            if hp <= 0 {
                continue
            }
            full := i64(layout[i / COLS][i % COLS] - '0')
            row := i / COLS
            r := brick_rect(i)
            flash := fx.brick_flash[i]
            if pass == 0 {
                sprite(b, TILE_SOFTBOX, r.x - 2.0, r.y + 0.5, r.z + 6.0, r.w + 6.0, paint(vec3(0.0), 0.6))
                sprite(b, TILE_SOFTBOX, r.x - 9.0, r.y - 8.0, r.z + 18.0, r.w + 16.0, glow(brick_base(row), 0.16 + 0.6 * flash))
                continue
            }
            x := r.x - BRICK_MARGIN
            y := r.y - BRICK_MARGIN
            w := r.z + 2.0 * BRICK_MARGIN
            h := r.w + 2.0 * BRICK_MARGIN
            sprite(b, tile_brick(row), x, y, w, h, paint(vec3(1.0), 1.0))
            if hp >= 3 {
                sprite(b, TILE_ARMOUR, x, y, w, h, paint(vec3(1.0), 1.0))
            } else if i64(hp) < full {
                sprite(b, if full - i64(hp) >= 2 { TILE_CRACK2 } else { TILE_CRACK1 }, x, y, w, h, paint(vec3(1.0), 1.0))
            }
            // the glass edge lights up
            d := r.x + r.y * 2.5 - glint_x
            glint := exp(-d * d / 300.0)
            edge := lerp(brick_light(row), vec3(1.0), 0.3)
            panel(b, TILE_EDGE, r.x - 0.5, r.y - 0.5, r.z + 1.0, r.w + 1.0, 3.0, glow(edge, 0.55 + 0.6 * glint + flash), glow(edge, 0.2 + 0.3 * glint + flash))
            k := flash * 0.9 + glint * 0.3
            if k > 0.01 {
                sprite(b, tile_brick(row), x, y, w, h, glow(vec3(1.0), k))
            }
        }
    }
}

// The paddle centred on x: shadow, glow, the bar and its light strip, a flash where the ball
// hit, the lit end caps.
fn draw_paddle(b: *Batch, fx: *Fx, x: f32) {
    t := f32(fx.time)
    left := x - PADDLE_W / 2.0
    f := fx.paddle_flash
    sprite(b, TILE_SOFTBOX, left - 2.0, PADDLE_Y + 2.0, PADDLE_W + 4.0, PADDLE_H + 4.0, paint(vec3(0.0), 0.6))
    sprite(b, TILE_SOFTBOX, left - 10.0, PADDLE_Y - 9.0, PADDLE_W + 20.0, PADDLE_H + 18.0, glow(CYAN, 0.22 + 0.7 * f))
    sprite(b, TILE_PADDLE, left - PADDLE_MARGIN_X, PADDLE_Y - PADDLE_MARGIN_Y, PADDLE_W + 2.0 * PADDLE_MARGIN_X,
        PADDLE_H + 2.0 * PADDLE_MARGIN_Y, paint(vec3(1.0), 1.0))
    strip(b, TILE_BEAM, vec2(left + 7.0, PADDLE_Y + 3.0), vec2(left + PADDLE_W - 7.0, PADDLE_Y + 3.0), 3.0, glow(CYAN, 0.9))
    if f > 0.0 {
        sprite(b, TILE_PADDLE, left - PADDLE_MARGIN_X, PADDLE_Y - PADDLE_MARGIN_Y, PADDLE_W + 2.0 * PADDLE_MARGIN_X,
            PADDLE_H + 2.0 * PADDLE_MARGIN_Y, glow(vec3(0.7, 1.0, 1.0), 0.9 * f))
        hx := clamp(fx.paddle_hit, left, left + PADDLE_W)
        sprite(b, TILE_FLARE, hx - 10.0 - 6.0 * f, PADDLE_Y - 8.0 - 3.0 * f, 20.0 + 12.0 * f, 16.0 + 6.0 * f, glow(vec3(0.8, 1.0, 1.0), 1.5 * f))
    }
    // the lit end caps
    caps := 0.75 + 0.25 * sin(t * 6.0)
    for side in [_]f32{-1.0, 1.0} {
        cx := x + side * 15.0
        sprite(b, TILE_GLOW, cx - 6.0, PADDLE_Y + 3.0 - 6.0, 12.0, 12.0, glow(MAGENTA, 0.7 * caps))
        sprite(b, TILE_GLOW, cx - 2.0, PADDLE_Y + 3.0 - 2.0, 4.0, 4.0, glow(vec3(1.0, 0.8, 0.6), 0.9))
    }
}

// The ball at p with its glow and its trail (pulsing while it waits on the paddle).
fn draw_ball(b: *Batch, fx: *Fx, p: vec2, stuck: bool) {
    // the trail: soft dots along the path of the last frames, shrinking and cooling
    if fx.n_trail > 1 {
        dist: f32 = 0.0
        len_max: f32 = 34.0
        for k in 0..fx.n_trail - 1 {
            a := fx.trail[fx.n_trail - 1 - k]
            c := fx.trail[fx.n_trail - 2 - k]
            seg := length(c - a)
            steps := i64(seg / 0.9) + 1
            for j in 0..steps {
                s := dist + seg * f32(j) / f32(steps)
                if s > len_max {
                    break
                }
                u := s / len_max
                q := lerp(a, c, f32(j) / f32(steps))
                r := lerp(3.4, 0.8, u)
                sprite(b, TILE_GLOW, q.x - r * 2.0, q.y - r * 2.0, r * 4.0, r * 4.0, glow(lerp(CYAN, VIOLET, u), 0.22 * (1.0 - u) * (1.0 - u)))
            }
            dist += seg
            if dist > len_max {
                break
            }
        }
    }
    pulse: f32 = if stuck { 0.8 + 0.2 * sin(f32(fx.time) * 8.0) } else { 1.0 }
    sprite(b, TILE_GLOW, p.x - 10.0, p.y - 10.0, 20.0, 20.0, glow(CYAN, 0.7 * pulse))
    sprite(b, TILE_GLOW, p.x - 5.0, p.y - 5.0, 10.0, 10.0, glow(vec3(0.85, 0.97, 1.0), 0.8))
    sprite(b, TILE_BALL, p.x - 4.0, p.y - 4.0, 8.0, 8.0, paint(vec3(1.35), 1.0))
}

// The particles: shards (`solid`), or the light ones (sparks, puffs, rings, flares).
fn draw_parts(b: *Batch, fx: *Fx, solid: bool) {
    for i in 0..fx.n_parts {
        p := fx.parts[i]
        if p.age < 0.0 {
            continue
        }
        k := p.age / p.life
        fade := fmin((p.life - p.age) / 0.25, 1.0)
        match p.kind {
            Shard => {
                if solid {
                    s := p.size
                    sprite_turned(b, tile_shard(p.shard), p.pos, vec2(s, s), p.angle, paint(p.color, fade))
                    sprite_turned(b, tile_shard(p.shard), p.pos, vec2(s, s), p.angle, glow(p.color, 0.35 * fade))
                }
            }
            Spark => {
                if !solid {
                    l := clamp(length(p.vel) * 0.05, 1.5, 9.0)
                    sprite_turned(b, TILE_STREAK, p.pos, vec2(l, 2.2), atan2(p.vel.y, p.vel.x), glow(p.color, 1.9 * fade))
                }
            }
            Puff => {
                if !solid {
                    s := p.size * (0.5 + 0.7 * k)
                    sprite(b, TILE_GLOW, p.pos.x - s / 2.0, p.pos.y - s / 2.0, s, s, glow(p.color, 0.75 * (1.0 - k) * (1.0 - k)))
                }
            }
            Ring => {
                if !solid {
                    s := p.size * (0.25 + 0.9 * ease_out_cubic(k))
                    sprite(b, TILE_RING, p.pos.x - s / 2.0, p.pos.y - s / 2.0, s, s, glow(p.color, 1.3 * (1.0 - k)))
                }
            }
            Flare => {
                if !solid {
                    s := p.size * (1.0 + 0.6 * k)
                    sprite(b, TILE_FLARE, p.pos.x - s / 2.0, p.pos.y - s / 2.0, s, s, glow(p.color, 2.2 * (1.0 - k)))
                }
            }
        }
    }
}

// The game's own sparks (logic.al: ten in the row's colour when a brick breaks).
fn draw_game_sparks(b: *Batch, g: *Game) {
    for i in 0..g.sparks.len {
        if !g.sparks.is_live(i) {
            continue
        }
        p := g.sparks.items[i]
        a := clamp(p.life * 2.5, 0.0, 1.0)
        c := color_vec4(p.color).xyz
        l := clamp(length(p.vel) * 0.04, 1.5, 6.0)
        sprite_turned(b, TILE_STREAK, p.pos, vec2(l, 2.0), atan2(p.vel.y, p.vel.x), glow(lerp(c, vec3(1.0), 0.3), 1.6 * a))
    }
}

// The points of broken bricks, rising and fading.
fn draw_popups(b: *Batch, fx: *Fx) {
    for i in 0..fx.n_popups {
        q := fx.popups[i]
        k := q.age
        a := fmin((1.0 - k) / 0.35, 1.0)
        size := 1.0 + 0.5 * pow(fmax(1.0 - k * 4.0, 0.0), 2.0)
        s := fmt("+", q.value)
        x := floor(q.pos.x - text_w(s, size, 0.0) / 2.0)
        y := q.pos.y - 3.5 * size
        text(b, x, y, size, s, paint(NIGHT, 0.7 * a), paint(NIGHT, 0.7 * a), 0.0, 1.4, 0.0)
        text(b, x, y, size, s, glow(q.color, 0.5 * a), glow(q.color, 0.5 * a), 0.0, 2.0, 0.0)
        text(b, x + 0.4, y + 0.5, size, s, paint(NIGHT, a), paint(NIGHT, a), 0.6, 0.0, 0.0)
        text(b, x, y, size, s, paint(vec3(1.0), a), paint(q.color, a), 0.1, 0.0, 0.0)
    }
}

// ---- the score line --------------------------------------------------------------------------

// Score (counting up), level and the balls left, above the frame.
fn draw_hud(b: *Batch, g: *Game, fx: *Fx) {
    if g.mode == Title {
        return
    }
    y: f32 = 2.5
    left_text(b, FIELD_L, y, 1.0, "SCORE", paint(DIM, 1.0), VIOLET, 0.0)
    left_text(b, FIELD_L + text_w("SCORE ", 1.0, 0.0), y, 1.0, fmti(i64(fx.score_shown + 0.5), 5, '0'), paint(INK, 1.0), CYAN, 0.45)
    lv := fmt("LEVEL ", g.level)
    centered(b, f32(VIEW_W) / 2.0, y, 1.0, lv, paint(GOLD, 1.0), GOLD, 0.35)
    for k in 0..LIVES {
        x := FIELD_R - 5.0 - f32(k) * 10.0
        if k < g.lives {
            sprite(b, TILE_GLOW, x - 5.0, y - 1.5, 10.0, 10.0, glow(CYAN, 0.5))
            sprite(b, TILE_BALL, x - 3.5, y, 7.0, 7.0, paint(vec3(1.2), 1.0))
        } else {
            sprite(b, TILE_BALL, x - 3.5, y, 7.0, 7.0, paint(vec3(0.18, 0.16, 0.30), 0.8))
        }
    }
}

// ---- the screens -----------------------------------------------------------------------------

// The title screen: the name in lights over a ball that plays by itself, the controls.
fn draw_title(b: *Batch, g: *Game, fx: *Fx) {
    t := f32(fx.time)
    cx := f32(VIEW_W) / 2.0
    on := smoothstep(0.0, 0.6, fx.mode_age + 0.3)
    // a dark band behind the name
    rect2(b, 0.0, 22.0, f32(VIEW_W), 40.0, paint(NIGHT, 0.0), paint(NIGHT, 0.75))
    rect2(b, 0.0, 62.0, f32(VIEW_W), 40.0, paint(NIGHT, 0.75), paint(NIGHT, 0.0))
    headline(b, cx, 38.0, 4.0, "BREAKOUT", vec3(1.0, 0.97, 1.0), vec3(1.0, 0.36, 0.72), MAGENTA, t, on)
    // a neon underline
    strip2(b, TILE_BEAM, vec2(cx - 110.0, 76.0), vec2(cx, 76.0), 6.0, glow(CYAN, 0.0), glow(lerp(CYAN, MAGENTA, 0.5), 1.4))
    strip2(b, TILE_BEAM, vec2(cx, 76.0), vec2(cx + 110.0, 76.0), 6.0, glow(lerp(CYAN, MAGENTA, 0.5), 1.4), glow(MAGENTA, 0.0))
    centered(b, cx, 82.0, 1.0, "N E O N   E D I T I O N", paint(DIM, 0.9), VIOLET, 0.3)
    k := 0.5 + 0.5 * sin(t * 4.0)
    centered(b, cx, 98.0, 1.0, "PRESS ENTER OR A TO PLAY", paint(INK, 0.6 + 0.4 * k), CYAN, 0.3 + 0.5 * k)
    if g.best > 0 {
        centered(b, cx, 110.0, 1.0, fmt("BEST  ", fmti(g.best, 5, '0')), paint(GOLD, 1.0), GOLD, 0.35)
    }
    glass(b, 26.0, 120.0, 268.0, 39.0, VIOLET, 0.7)
    centered(b, cx, 126.0, 1.0, "ARROWS / STICK  MOVE    SPACE / A  LAUNCH", paint(DIM, 1.0), VIOLET, 0.0)
    centered(b, cx, 135.5, 1.0, "ESC / START  PAUSE    F11  FULLSCREEN", paint(DIM, 1.0), VIOLET, 0.0)
    centered(b, cx, 145.0, 1.0, "ESC  QUIT", paint(vec3(0.42, 0.40, 0.58), 1.0), VIOLET, 0.0)
}

// The banner while it lasts (2 s): after a cleared wall "WALL CLEARED" first, then "LEVEL n"
// growing in, holding, fading out.
fn draw_banner(b: *Batch, g: *Game, fx: *Fx) {
    cx := f32(VIEW_W) / 2.0
    k := 2.0 - g.banner
    if g.level > 1 && fx.clear_age < 2.0 {
        if k < 0.85 {
            grow := ease_out_back(fmin(k / 0.3, 1.0))
            a := fmin((0.85 - k) / 0.2, 1.0)
            size := 2.5 * grow
            if size > 0.2 {
                big(b, cx, 96.0 - 3.5 * size, size, "WALL CLEARED", vec3(1.0, 0.98, 0.85), GOLD, vec3(1.0, 0.55, 0.1), a)
            }
            return
        }
        k = (k - 0.85) * 2.0 / 1.15                     // the level's banner in the time left
    }
    grow := ease_out_back(fmin(k / 0.4, 1.0))
    a := fmin(g.banner / 0.35, 1.0) * fmin(k / 0.15, 1.0)
    size := 3.0 * grow
    if size > 0.2 {
        big(b, cx, 96.0 - 3.5 * size, size, fmt("LEVEL ", g.level), vec3(1.0, 0.97, 1.0), vec3(1.0, 0.45, 0.8), MAGENTA, a)
    }
    centered(b, cx, 112.0, 1.0, "GET READY", paint(INK, 0.8 * a), CYAN, 0.4 * a)
}

// Large text centred on cx: a glow, a shadow and a gradient.
fn big(b: *Batch, cx: f32, y: f32, size: f32, s: str, top: vec3, bottom: vec3, halo: vec3, a: f32) {
    x := floor(cx - text_w(s, size, 0.0) / 2.0)
    text(b, x, y, size, s, glow(halo, 0.7 * a), glow(lerp(halo, VIOLET, 0.5), 0.7 * a), 0.0, 2.0, 0.0)
    text(b, x + size * 0.35, y + size * 0.45, size, s, paint(NIGHT, 0.7 * a), paint(NIGHT, 0.7 * a), 0.5, 0.0, 0.0)
    text(b, x, y, size, s, paint(top, a), paint(bottom, a), 0.05, 0.0, 0.0)
}

// The pause menu: a glass panel with a gliding highlight and volume bars.
fn draw_menu(b: *Batch, g: *Game, fx: *Fx) {
    t := f32(fx.time)
    cx := f32(VIEW_W) / 2.0
    rect(b, 0.0, 0.0, f32(VIEW_W), f32(VIEW_H), paint(NIGHT, 0.55))
    // the panel slides in
    k := ease_out_cubic(fmin(fx.mode_age / 0.25, 1.0))
    y0 := 30.0 + 12.0 * (1.0 - k)
    glass(b, 78.0, y0, 164.0, 122.0, CYAN, k)
    centered(b, cx, y0 + 9.0, 2.0, "PAUSED", paint(INK, k), CYAN, 0.7 * k)
    strip2(b, TILE_BEAM, vec2(92.0, y0 + 29.0), vec2(cx, y0 + 29.0), 4.0, glow(CYAN, 0.0), glow(CYAN, 0.9 * k))
    strip2(b, TILE_BEAM, vec2(cx, y0 + 29.0), vec2(228.0, y0 + 29.0), 4.0, glow(CYAN, 0.9 * k), glow(CYAN, 0.0))
    labels := [MENU_ITEMS]str{"RESUME", "MUSIC", "SOUND", "FULLSCREEN", "QUIT TO TITLE"}
    top := y0 + 38.0
    // the highlight glides to the selected line and pulses
    hy := top + fx.menu_pos * 15.0 - 3.5
    p := 0.75 + 0.25 * sin(t * 6.0) + 0.5 * fx.menu_pulse
    rect2(b, 86.0, hy, 148.0, 13.0, glow(MAGENTA, 0.18 * p * k), glow(VIOLET, 0.32 * p * k))
    strip2(b, TILE_BEAM, vec2(86.0, hy + 13.0), vec2(234.0, hy + 13.0), 3.0, glow(MAGENTA, 0.9 * p * k), glow(VIOLET, 0.2 * k))
    sprite(b, TILE_GLOW, 82.0, hy + 2.5, 8.0, 8.0, glow(MAGENTA, 1.2 * p * k))
    for i, label in labels {
        y := top + f32(i) * 15.0
        sel := i == g.menu
        ink := if sel { paint(INK, k) } else { paint(DIM, k) }
        left_text(b, 94.0, y, 1.0, label, ink, MAGENTA, if sel { 0.5 * k } else { 0.0 })
        level := if i == MENU_MUSIC { g.settings.music } else if i == MENU_SOUND { g.settings.sound } else { -1 }
        if level >= 0 {
            for s in 0..VOLUME_STEPS {
                sx := 168.0 + f32(s) * 6.0
                h := 3.0 + f32(s) * 0.45
                if s < level {
                    c := lerp(CYAN, MAGENTA, f32(s) / f32(VOLUME_STEPS - 1))
                    rect(b, sx, y + 7.0 - h, 4.0, h, paint(c * 1.15, k))
                    sprite(b, TILE_GLOW, sx - 2.0, y + 7.0 - h - 2.0, 8.0, h + 4.0, glow(c, (if sel { 0.5 } else { 0.25 }) * k))
                } else {
                    rect(b, sx, y + 7.0 - h, 4.0, h, paint(vec3(0.16, 0.14, 0.28), k))
                }
            }
        }
    }
    centered(b, cx, 157.0, 1.0, "UP/DOWN CHOOSE   LEFT/RIGHT CHANGE   ESC/B BACK", paint(DIM, 0.9 * k), VIOLET, 0.0)
}

// The end: a flickering neon sign, the score and the best, a new best blinking.
fn draw_game_over(b: *Batch, g: *Game, fx: *Fx) {
    t := f32(fx.time)
    age := fx.mode_age
    cx := f32(VIEW_W) / 2.0
    rect2(b, 0.0, 0.0, f32(VIEW_W), f32(VIEW_H), paint(vec3(0.05, 0.0, 0.05), 0.62), paint(vec3(0.10, 0.0, 0.04), 0.78))
    rect2(b, 0.0, 22.0, f32(VIEW_W), 22.0, paint(NIGHT, 0.0), paint(NIGHT, 0.6))
    rect2(b, 0.0, 44.0, f32(VIEW_W), 46.0, paint(NIGHT, 0.6), paint(NIGHT, 0.0))
    // the sign flickers on like a neon tube, then hums
    on: f32 = 1.0
    if age < 1.1 {
        h := fract(sin(floor(age * 24.0) * 12.9898) * 43758.547)
        on = if h < age { 1.0 } else { 0.08 }
    } else {
        on = 0.93 + 0.07 * sin(t * 50.0) * sin(t * 3.1)
    }
    headline(b, cx, 34.0, 4.0, "GAME OVER", vec3(1.0, 0.9, 0.92), vec3(1.0, 0.18, 0.32), vec3(1.0, 0.15, 0.3), t, on)
    k := ease_out_cubic(clamp((age - 0.6) / 0.4, 0.0, 1.0))
    if k > 0.0 {
        glass(b, 88.0, 82.0, 144.0, 44.0, MAGENTA, k)
        left_text(b, 100.0, 90.0, 1.0, "SCORE", paint(DIM, k), VIOLET, 0.0)
        s := fmti(g.score, 5, '0')
        left_text(b, 220.0 - text_w(s, 2.0, 0.0), 87.0, 2.0, s, paint(INK, k), CYAN, 0.5 * k)
        left_text(b, 100.0, 110.0, 1.0, "BEST", paint(DIM, k), VIOLET, 0.0)
        best := fmti(g.best, 5, '0')
        left_text(b, 220.0 - text_w(best, 1.0, 0.0), 110.0, 1.0, best, paint(GOLD, k), GOLD, 0.4 * k)
        if g.score > fx.best_before && g.score > 0 && fmod(t, 0.8) < 0.55 {
            centered(b, cx, 72.0, 1.0, "NEW BEST!", paint(GOLD, k), GOLD, 0.9 * k)
        }
    }
    if age > 1.2 {
        p := 0.5 + 0.5 * sin(t * 4.0)
        centered(b, cx, 140.0, 1.0, "PRESS ENTER OR A", paint(INK, 0.6 + 0.4 * p), CYAN, 0.3 + 0.4 * p)
    }
}
