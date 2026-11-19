// A complete small game showing the structure recommended in docs/GAMES.md. The rules are in
// logic.al (shared with the Direct3D 12 version, examples/dx12_starter); this file is the
// software front end: it draws into a 960 x 540 framebuffer that std.window shows in the window.
//   - rendering reads the state and never changes it; the effects (fx.al) are state of the
//     front end, derived from the game's events and entities, never fed back into it
//   - the platform layer (window) is a thin shell around `update` / `render`
//   - all art is made by code at start-up and blitted each frame: a frame costs one or two
//     milliseconds of one core (a big explosion a few more)
//
//   alc run examples/starter/game.al                  play it (arrows / WASD / pad move, space / A
//                                                     shoots, F2 scan lines, Esc quits)
//   alc run examples/starter/game.al -- --headless    no window: scripted input, prints a checksum
//   alc run examples/starter/game.al -- --shot tmp/shot.png --frames 600
//                                                     no window: 600 frames of the scripted run
//                                                     (--idle: of no input), drawn as in the window;
//                                                     the last is saved as a PNG, render times printed
//   alc run examples/starter/game.al -- --record tmp/rec --frames 1320 [--seed N]
//                                                     no window: an autopilot plays, frames and
//                                                     sound are written for a video (record.al)
//   options for the window: --frames N (stop after N frames, print frame times), --scanlines
// The art is in art.al (sprites, made at start-up), text.al (the HUD font) and fx.al (effects);
// blit.al has the pixel helpers they draw with.
use std.window
use std.image
use "logic.al"
use "art.al"
use "text.al"
use "fx.al"
use "record.al"

// Everything the front end keeps between frames.
struct View {
    art: Art
    fx: Fx
    canvas: Canvas
    small: TextStyle                 // labels
    big: TextStyle                   // the score
    pop: TextStyle                   // "+10" over a destroyed rock
    title: TextStyle                 // "GAME OVER"
    hint: TextStyle                  // the line under it
    panel: Sprite
    scanlines: bool
}

// `font` draws the text: a font of the system (load_font), or the test font for a picture that
// must be the same on every machine (the headless checksum).
fn view_new(g: *Game, scanlines: bool, font: Font) -> View {
    v: View
    v.art = art_new()
    v.fx = fx_new(g.ents.items.len)
    v.canvas = Canvas{FB_W, FB_H, alloc[u32](FB_W * FB_H)}
    none := vec3(0.0)
    v.small = text_style(font, 21.0, vec3(0.70, 0.92, 1.0), vec3(0.40, 0.68, 1.0), 1.5, 2, 0, none)
    v.big = text_style(font, 42.0, vec3(1.0, 0.96, 0.74), vec3(1.0, 0.72, 0.30), 1.5, 2, 0, none)
    v.pop = text_style(font, 22.0, vec3(1.0, 0.96, 0.72), vec3(1.0, 0.76, 0.32), 1.5, 2, 0, none)
    v.title = text_style(font, 76.0, vec3(1.0, 0.78, 0.60), vec3(0.96, 0.36, 0.26), 2.0, 3, 7, vec3(0.85, 0.22, 0.10))
    v.hint = text_style(font, 19.0, vec3(0.80, 0.80, 0.90), vec3(0.66, 0.66, 0.80), 1.5, 1, 0, none)
    v.panel = panel_sprite(520, 250)
    v.scanlines = scanlines
    v
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(v: *View, g: *Game, alpha: f32) {
    c := &v.canvas
    fx := &v.fx
    art := &v.art
    if g.over {
        alpha = 0.0                  // the world stands still once the game is over
    }
    t := (f64(g.step_no) + f64(alpha)) / HZ
    off := shake_offset(fx)
    draw_space(c, art, t, off)
    fx_draw(c, fx, art, Back, off)
    draw_rocks(c, g, fx, art, alpha, off)
    fx_draw(c, fx, art, Solid, off)
    draw_shots(c, g, art, alpha, off)
    draw_player(c, g, fx, art, alpha, off)
    fx_draw(c, fx, art, Light, off)
    draw_popups(v, off)
    finish(v, g)
    draw_hud(v, g)
    if g.over {
        draw_game_over(v, g)
    }
    if v.scanlines {
        for y in 0..FB_H by 2 {
            darken_rows(c, y, y + 1, 210)
        }
    }
}

// Far nebula, mid stars, near streaks: the farther, the slower they scroll.
fn draw_space(c: *Canvas, art: *Art, t: f64, off: vec2) {
    // the nebula tile, 9 pixels a second, copied row by row
    scroll := i64(t * 9.0) % BG_H
    for y in 0..FB_H {
        src := ((y - scroll) % BG_H + BG_H) % BG_H * FB_W
        copy(c.px[y * FB_W..(y + 1) * FB_W], art.nebula.px[src..src + FB_W])
    }
    span := f64(FB_H + 40)
    for s in art.stars {
        y := f32(fmod(f64(s.pos.y) + t * f64(s.speed), span)) - 20.0
        twinkle := 0.7 + 0.3 * sin(f32(t) * 2.5 + s.phase)
        col := scale4(s.color, u32(twinkle * 256.0))
        at := vec2(s.pos.x, y) + off * 0.25
        mask_at(c, &art.glow, at.x, at.y, s.size * 2.4, Add, col)
        if s.size > 3.6 {
            mask_at(c, &art.flare, at.x, at.y, s.size * 5.0, Add, scale4(col, 150))
        }
    }
    dot := art.glow.level(8.0)
    for s in art.streaks {
        y := f32(fmod(f64(s.pos.y) + t * f64(s.speed), span)) - 20.0
        at := vec2(s.pos.x, y) + off * 0.6
        mask_xf(c, &dot, at.x, at.y, 0.0, s.size / 8.0, s.speed * 0.09 / 8.0, Add, scale4(s.color, 70))
    }
}

fn draw_rocks(c: *Canvas, g: *Game, fx: *Fx, art: *Art, alpha: f32, off: vec2) {
    sizes := ROCK_SIZES.len
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) || g.ents.items[i].kind != Rock {
            continue
        }
        e := &g.ents.items[i]
        at := screen_pos(e, alpha) + off
        r := e.radius * f32(PX) * ROCK_LOOK
        kind, turn, spin := rock_look(g.ents.handle_at(i))
        // a rock moves at a constant speed from y = -8: its age, and so its turn, follows from y
        age := (e.pos.y + 8.0) / e.vel.y + alpha / f32(HZ)
        angle := turn + spin * age
        // the pre-lit frame nearest in size (from above) and angle; the rest by the blit
        s := 0
        while s + 1 < sizes && ROCK_SIZES[s] < r {
            s += 1
        }
        steps := angle / TAU * f32(ROCK_ANGLES)
        nearest := floor(steps + 0.5)
        frame := (i64(nearest) % ROCK_ANGLES + ROCK_ANGLES) % ROCK_ANGLES
        rest := (steps - nearest) / f32(ROCK_ANGLES) * TAU
        sprite := &art.rocks[(kind * sizes + s) * ROCK_ANGLES + frame]
        k := r / ROCK_SIZES[s]
        blit_xf(c, sprite, at.x, at.y, rest, k, k, Over, 256)
        if e.hp == 1 {
            pulse := 0.75 + 0.25 * sin(fx.time * 11.0 + f32(i))
            kc := r / ROCK_SIZES[sizes - 1]
            mask_xf(c, &art.cracks[kind], at.x, at.y, angle, kc, kc, Add, light(vec3(1.0, 0.42, 0.10), pulse))
        }
        if fx.hit[i] > 0.0 {
            blit_xf(c, sprite, at.x, at.y, rest, k, k, Add, u32(fx.hit[i] / 0.12 * 230.0))
        }
    }
}

fn draw_shots(c: *Canvas, g: *Game, art: *Art, alpha: f32, off: vec2) {
    dot := art.glow.level(8.0)
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        at := screen_pos(e, alpha) + off
        if e.kind == Shot {
            blit(c, &art.shot, i64(at.x) - art.shot.w / 2, i64(at.y) - SHOT_HEAD, Add, 256)
        } else if e.kind == Spark {
            // the game's own sparks: short streaks along their motion, fading with their life
            col := color_vec4(e.color).xyz
            k := saturate(e.life / 0.25)
            along := fmax(length(e.vel) * 0.06 * f32(PX), 5.0)
            mask_xf(c, &dot, at.x, at.y, atan2(-e.vel.x, e.vel.y), 0.5, along / 8.0, Add, light(col, k))
        }
    }
}

fn draw_player(c: *Canvas, g: *Game, fx: *Fx, art: *Art, alpha: f32, off: vec2) {
    p := g.ents.get(g.player)
    if p == nil {
        return
    }
    at := screen_pos(p, alpha) + off
    // the flame: longer when climbing, short when braking, flickering
    thrust := 1.0 - p.vel.y / 110.0 * 0.45
    flick := 0.9 + 0.12 * noise2(fx.time * 30.0, 1.5, 70)
    flame := &art.flame[i64(fx.time * 24.0) % FLAME_FRAMES]
    sy := thrust * flick
    nozzle := at + vec2(fx.roll * 1.5, 19.0)
    mask_at(c, &art.glow, nozzle.x, nozzle.y + 6.0, 54.0 * thrust, Add, light(CYAN, 0.28))
    blit_xf(c, flame, nozzle.x, nozzle.y + f32(flame.h) * 0.5 * sy - 1.0, 0.0, 1.0, sy, Add, 256)
    frame := i64(floor((fx.roll + 1.0) * 0.5 * f32(SHIP_FRAMES - 1) + 0.5))
    x := i64(floor(at.x)) - SHIP_W / 2
    y := i64(floor(at.y)) - SHIP_H / 2
    blit(c, &art.ship[frame], x, y, Over, 256)
    if fx.hp_lost < 0.8 && i64(fx.hp_lost * 14.0) % 2 == 0 {
        blit(c, &art.ship_white[frame], x, y, Add, 210)              // hit: blink white
    }
    if fx.muzzle > 0.0 {
        m := fx.muzzle
        mask_at(c, &art.glow, at.x, at.y - 26.0, 34.0 * m, Add, light(vec3(0.7, 0.95, 1.0), m))
        mask_at(c, &art.flare, at.x, at.y - 26.0, 26.0 * m, Add, light(vec3(1.0), m * 0.8))
    }
}

fn draw_popups(v: *View, off: vec2) {
    fx := &v.fx
    for i in 0..fx.count {
        p := &fx.parts[i]
        if p.kind != Pop {
            continue
        }
        t := p.age / p.life
        text := fmt("+", p.look)
        k := u32(saturate((1.0 - t) * 2.5) * 256.0)
        x := i64(p.pos.x + off.x) - text_width(&v.pop, text) / 2
        draw_text(&v.canvas, &v.pop, x, i64(p.pos.y + off.y), text, k)
    }
}

// The pass over every pixel: vignette, the red flash of a hit, the white flash of the ship
// exploding, dimming behind the game-over panel.
fn finish(v: *View, g: *Game) {
    fx := &v.fx
    c := &v.canvas
    dim: u32 = 256
    if g.over {
        dim = u32((1.0 - 0.5 * smoothstep(1.0, 2.0, fx.over_time)) * 256.0)
    }
    red := light(vec3(1.0, 0.1, 0.05), fx.hurt * 0.55)
    white := light(vec3(1.0, 0.95, 0.85), fx.white * 0.9)
    vig := v.art.vignette
    if fx.hurt > 0.0 || fx.white > 0.0 {
        for i in 0..FB_W * FB_H {
            edge := 256 - vig[i]
            px := add4(scale4(c.px[i], vig[i] * dim >> 8), scale4(red, min(edge * 2, 256)))
            c.px[i] = add4(px, white) | 0xFF000000
        }
    } else {
        for i in 0..FB_W * FB_H {
            c.px[i] = scale4(c.px[i], vig[i] * dim >> 8) | 0xFF000000
        }
    }
}

fn draw_hud(v: *View, g: *Game) {
    c := &v.canvas
    fx := &v.fx
    for y in 0..96 {
        darken_rows(c, y, y + 1, u32(200.0 + 56.0 * smoothstep(0.0, 96.0, f32(y))))
    }
    draw_text(c, &v.small, 28, 18, "SCORE", 256)
    score := fmt(g.score)
    draw_text(c, &v.big, 28, 46, score, 256)
    if fx.score_pulse > 0.0 {
        draw_text(c, &v.big, 28, 46, score, u32(fx.score_pulse * 140.0))
    }
    // hull: one ship for every hit point left
    hp := player_hp(g)
    label := "HULL"
    draw_text(c, &v.small, FB_W - 28 - text_width(&v.small, label), 18, label, 256)
    for i in 0..3 {
        x := FB_W - 28 - (3 - i) * 30 + 4
        if i < hp {
            blit(c, &v.art.icon, x, 46, Over, 256)
        } else {
            blit(c, &v.art.icon_off, x, 46, Over, 256)
            if i == hp && fx.hp_lost < 1.0 && i64(fx.hp_lost * 10.0) % 2 == 0 {
                blit(c, &v.art.icon, x, 46, Add, 200)
            }
        }
    }
}

fn draw_game_over(v: *View, g: *Game) {
    c := &v.canvas
    fx := &v.fx
    show := smoothstep(1.3, 1.9, fx.over_time)
    if show <= 0.0 {
        return
    }
    k := u32(show * 256.0)
    cx := FB_W / 2
    cy := FB_H / 2 + i64((1.0 - ease_out_cubic(show)) * 40.0)
    blit(c, &v.panel, cx - v.panel.w / 2, cy - v.panel.h / 2, Over, k)
    title := "GAME OVER"
    draw_text(c, &v.title, cx - text_width(&v.title, title) / 2, cy - 88, title, k)
    label := "FINAL SCORE"
    draw_text(c, &v.small, cx - text_width(&v.small, label) / 2, cy + 4, label, k)
    score := fmt(g.score)
    draw_text(c, &v.big, cx - text_width(&v.big, score) / 2, cy + 36, score, k)
    if i64(fx.over_time * 2.0) % 2 == 0 {
        hint := "Press Esc to quit"
        draw_text(c, &v.hint, cx - text_width(&v.hint, hint) / 2, cy + 90, hint, k * 3 / 4)
    }
}

fn checksum(fb: []u32) -> u64 {
    h: u64 = 1469598103934665603
    for p in fb {
        h = (h ^ u64(p)) * 1099511628211
    }
    return h
}

// The input of the headless runs: weave left and right, hold fire.
fn script(inp: *Input, step: i64) {
    if step == 0 {
        inp.feed(Event{kind: EventKeyDown, key: KEY_SPACE})
    }
    if step % 240 == 0 {
        inp.feed(Event{kind: EventKeyUp, key: KEY_RIGHT})
        inp.feed(Event{kind: EventKeyDown, key: KEY_LEFT})
    }
    if step % 240 == 120 {
        inp.feed(Event{kind: EventKeyUp, key: KEY_LEFT})
        inp.feed(Event{kind: EventKeyDown, key: KEY_RIGHT})
    }
}

// Headless run: the same update/render driven by scripted input instead of a window.
fn run_headless() {
    g := game_new(2024)
    inp: Input
    v := view_new(&g, false, test_font())     // (the same picture on every machine)
    for step in 0..2400 {
        inp.begin_frame()
        script(&inp, step)
        update(&g, &inp, 1.0 / f32(HZ))
        fx_update(&v.fx, &g, 1.0 / f32(HZ))
        g.events.clear()                       // no sound in this version
    }
    render(&v, &g, 0.0)
    print("steps", g.step_no, "score", g.score, "entities", g.ents.used, "over", g.over)
    print("frame", hex(checksum(v.canvas.px)))
}

// A screenshot without a window: `frames` frames at 60 per second (two steps each) of the
// scripted run, or of none with `idle`, each drawn as the window would; the last one is saved.
fn run_shot(path: str, frames: i64, idle: bool, scanlines: bool) {
    g := game_new(2024)
    inp: Input
    t0 := clock_ns()
    v := view_new(&g, scanlines, load_font())
    t1 := clock_ns()
    step := 0
    total := 0
    worst := 0
    for f in 0..frames {
        for k in 0..2 {
            inp.begin_frame()
            if !idle {
                script(&inp, step)
            }
            update(&g, &inp, 1.0 / f32(HZ))
            step += 1
        }
        fx_update(&v.fx, &g, 2.0 / f32(HZ))
        g.events.clear()
        frame_begin()
        r0 := clock_ns()
        render(&v, &g, 0.5)
        r := clock_ns() - r0
        frame_end()
        total += r
        worst = max(worst, r)
    }
    if !png_save(path, image_of(Sprite{FB_W, FB_H, v.canvas.px})) {
        eprint(fmt("cannot write ", path))
        exit(1)
    }
    print("saved", path, "step", g.step_no, "score", g.score, "hp", player_hp(&g), "particles", v.fx.count)
    print("art", fmtf(f64(t1 - t0) / 1e6, 1), "ms, render: average", fmtf(f64(total) / f64(frames) / 1e6, 2), "ms, slowest",
        fmtf(f64(worst) / 1e6, 2), "ms")
}

fn run_window(frames: i64, scanlines: bool) {
    w, ok := window_open(WindowDesc{title: "AL starter", width: FB_W, height: FB_H, resizable: true})
    if !ok {
        eprint("cannot open a window (no display?): `--headless` runs the scripted demo without one")
        exit(1)
    }
    gamepad_open(&w.input.pad, 0)
    g := game_new(u64(time_ns()))
    v := view_new(&g, scanlines, load_font())
    clock := frame_clock()
    steps := fixed_step(HZ)
    count := 0
    render_ns := 0
    start := clock_ns()
    worst := 0
    last := start
    while !w.should_close() && count != frames {
        w.poll()
        gamepad_poll(&w.input.pad)
        if g.keys.action_pressed(&w.input, g.act.quit) {
            w.closing = true
        }
        if w.input.key_pressed(KEY_F2) {
            v.scanlines = !v.scanlines
        }
        n := steps.advance(clock.tick())
        for k in 0..n {
            update(&g, &w.input, f32(steps.step))
        }
        fx_update(&v.fx, &g, f32(n) * f32(steps.step))
        g.events.clear()
        frame_begin()                          // the HUD's strings live for one frame
        r0 := clock_ns()
        render(&v, &g, steps.alpha())
        render_ns += clock_ns() - r0
        w.present(as_bytes(v.canvas.px), FB_W, FB_H)
        frame_end()
        sleep_ms(4)
        now := clock_ns()
        if count > 0 {
            worst = max(worst, now - last)
        }
        last = now
        count += 1
    }
    w.close()
    print("score", g.score)
    if frames >= 0 && count > 0 {
        print("frames", count, "average frame", fmtf(f64(last - start) / f64(count) / 1e6, 2), "ms, render",
            fmtf(f64(render_ns) / f64(count) / 1e6, 2), "ms, slowest frame", fmtf(f64(worst) / 1e6, 2), "ms")
    }
}

fn main() {
    a := args()
    shot := ""
    record := ""
    seed: u64 = 1
    frames := -1
    idle := false
    scanlines := false
    for i, arg in a {
        if arg == "--headless" {
            run_headless()
            return
        } else if arg == "--shot" && i + 1 < a.len {
            shot = a[i + 1]
        } else if arg == "--record" && i + 1 < a.len {
            record = a[i + 1]
        } else if arg == "--seed" && i + 1 < a.len {
            seed = u64(parse_i64(a[i + 1]).0)
        } else if arg == "--frames" && i + 1 < a.len {
            frames = parse_i64(a[i + 1]).0
        } else if arg == "--idle" {
            idle = true
        } else if arg == "--scanlines" {
            scanlines = true
        }
    }
    if record != "" {
        run_record(record, max(frames, 1), seed)
        return
    }
    if shot != "" {
        run_shot(shot, max(frames, 1), idle, scanlines)
        return
    }
    run_window(frames, scanlines)
}
