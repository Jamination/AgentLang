// examples/dx12_starter drawn with std.gfx instead of its own Direct3D 12 code: the same rules
// (../starter/logic.al), sounds and music (../dx12_starter/sound.al), headless run
// (../dx12_starter/headless.al) and options (../gamekit/options.al). What dx12_starter takes
// from gamekit's dx12_gpu.al and screen.al (device, swap chain, frames in flight, sprite
// batcher, letterbox, resizing: about 700 lines) is std.gfx here, its bitmap font is a
// TrueType font of the system drawn with std.gfx_text, and the game runs on Linux (Vulkan) as
// well as Windows (Direct3D 12).
//
// It is also the showcase of what std.gfx can look like. All art is painted at start-up into
// one atlas (art.al); effects that only look at the game (explosions, sparks, exhaust, screen
// shake, pop-ups: fx.al) and a bloom and frosted-glass post-process made of render textures
// (post.al) surround a render function that, as in every game here, only reads the state.
//
//   alc run examples/gfx_starter/game.al                 play
//   alc run examples/gfx_starter/game.al -- --headless   no window, GPU or sound device: checksums
//   alc run examples/gfx_starter/game.al -- --shot tmp/shot.png --frames 600 [--paused]
//                                                        the scripted run of --headless for that
//                                                        many frames, drawn offscreen at 1280 x 720
//   alc run examples/gfx_starter/game.al -- --record tmp/rec.rgba --frames 1320 [--seed 7]
//                                                        the autopilot of pilot.al plays; every
//                                                        frame raw into tmp/rec.rgba.000, .001, ...
//                                                        (60 frames each), the sound into
//                                                        tmp/rec.rgba.wav: material for a video
//
// Arrows / WASD / D-pad / left stick move, Space / pad A shoots, M music on / off, F11 or
// Alt+Enter fullscreen, Escape / pad Back quits; once the panel at the end is up, fire plays
// again. The game pauses while its window does not have the focus. --warp draws with the
// software rasterizer. At the end the renderer's statistics of the last frame (draw calls,
// passes, dropped primitives) and the frame rate go to standard error.
use std.window
use std.audio
use std.image
use std.gfx
use std.gfx_text
use "../starter/logic.al"
use "../dx12_starter/sound.al"
use "../dx12_starter/headless.al"
use "../gamekit/options.al"
use "art.al"
use "fx.al"
use "post.al"
use "pilot.al"

const WHITE: u32 = 0xFFFFFFFF
const SPACE: u32 = 0xFF140804    // behind everything (0xAABBGGRR: R 4, G 8, B 20)
const LABEL: u32 = 0xFFEBBE78    // pale sky blue
const TEXT_PX: f32 = 8.0         // em sizes of the fonts in virtual pixels
const MID_PX: f32 = 13.0
const TITLE_PX: f32 = 22.0
const SHIP_SIZE: f32 = 20.0      // the ship sprite in virtual pixels (its hit radius is 5)
const SHOT_W = 1280              // --shot draws at this size
const SHOT_H = 720

// A font of the system; without one, the font that std.font is tested with (its own letters
// are only A, V, H, o and W: the others show as its missing glyph, a box).
const FONT_PATHS = [_]str{
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
}
const TEST_FONT = embed("../../tests/std/data/font_test.ttf")

fn load_font() -> Font {
    for p in FONT_PATHS {
        f, err := font_load(p)
        if err == "" {
            return f
        }
    }
    eprint("no system font found: the text is drawn with the test font of std.font")
    f, _ := font_parse(TEST_FONT)
    f
}

// The fonts of the HUD. They are rasterised at the size they have on the screen (their size in
// virtual pixels times the scale of the view) and drawn at their virtual size, so the text is
// as sharp in a large window as in a small one; a new window size makes them anew.
struct Text { font: Font, scale: f32, small: GfxFont, mid: GfxFont, big: GfxFont }

text_mem: Region                 // the atlases of the fonts in use (reset when they are made anew)

fn fonts_for(g: *Gfx, t: *Text, scale: f32) {
    if scale == t.scale || !(scale > 0.0) {
        return
    }
    if t.scale > 0.0 {
        gfx_font_free(g, t.small)
        gfx_font_free(g, t.mid)
        gfx_font_free(g, t.big)
    }
    reset(&text_mem)
    enter(&text_mem)
    err := ""
    t.small, err = gfx_font(g, t.font, TEXT_PX * scale, char_range(32, 126))
    assert err == "", err
    t.mid, err = gfx_font(g, t.font, MID_PX * scale, char_range(32, 126))
    assert err == "", err
    t.big, err = gfx_font(g, t.font, TITLE_PX * scale, char_range(32, 126))
    assert err == "", err
    leave()
    t.small.size = TEXT_PX
    t.mid.size = MID_PX
    t.big.size = TITLE_PX
    t.scale = scale
}

// Everything the drawing needs besides the game.
struct Look { art: Art, post: Post, fx: Fx, text: Text }

fn look_new(g: *Gfx) -> Look {
    Look{art: make_art(g), post: post_new(g), fx: fx_new(1), text: Text{font: load_font()}}
}

// Where an entity is shown: `alpha` of the way to its next step.
fn shown(e: *Entity, alpha: f32) -> vec2 { e.pos + e.vel * (alpha / f32(HZ)) }

// A rock's looks from its slot and generation: which of the painted rocks, and how it tumbles.
fn rock_sprite(lk: *Look, i: i64, gen: u32) -> (vec4, f32) {
    h := hash((i, gen))
    spin := (f32((h >> 8) % 1000) / 1000.0 - 0.5) * 2.2
    (lk.art.rock[i64(h % ROCKS)], f32((h >> 24) % 628) / 100.0 + spin * lk.fx.time)
}

// The engines' flames under the ship at p, longer when it climbs.
fn draw_flames(g: *Gfx, lk: *Look, p: vec2, vel: vec2) {
    fx := &lk.fx
    a := &lk.art
    frame := i64(fx.time * 30.0) % FLAME_FRAMES
    long := (1.0 - vel.y / 110.0 * 0.4) * (0.92 + 0.08 * sin(fx.time * 47.0))
    for k in 0..2 {
        side := f32(k * 2 - 1)
        at := p + vec2(side * 2.6 * (1.0 - 0.3 * fabs(fx.bank)) - fx.bank * 0.5, 6.0)
        size := vec2(3.8, 11.0 * long)
        g.sprite(a.tex, a.flame[frame], at, size, 0.0, vec2(size.x * 0.5, 0.0), WHITE)
        g.sprite(a.tex, a.glow, at + vec2(0.0, 1.5), vec2(12.0), 0.0, vec2(6.0), color_u32(vec4(0.3, 0.7, 1.0, 0.6)))
    }
}

// What emits light: drawn additively into the scene, and again into the glow texture for bloom.
fn draw_light(g: *Gfx, lk: *Look, game: *Game, alpha: f32) {
    a := &lk.art
    fx := &lk.fx
    draw_particles(g, a, fx, true)
    for i in 0..game.ents.len {
        if !game.ents.is_live(i) {
            continue
        }
        e := &game.ents.items[i]
        p := shown(e, alpha)
        match e.kind {
            Shot => {
                g.sprite(a.tex, a.glow, p, vec2(16.0), 0.0, vec2(8.0), color_u32(vec4(0.2, 0.6, 1.0, 0.4)))
                g.sprite(a.tex, a.bolt, p, vec2(3.6, 10.8), 0.0, vec2(1.8, 3.0), WHITE)
            }
            Spark => {
                // the game's own sparks; after the end it stops, so they drift on and fade here
                c := color_vec4(e.color)
                c.w = saturate(e.life * 3.0)
                if game.over {
                    p = p + e.vel * fx.over_t * 0.6
                    c.w = c.w * saturate(1.0 - fx.over_t * 1.5)
                }
                long := 2.5 + length(e.vel) * 0.05
                g.sprite(a.tex, a.streak, p, vec2(long, 1.4), atan2(e.vel.y, e.vel.x), vec2(long * 0.8, 0.7), color_u32(c))
            }
            Rock => {
                if fx.hit[i] > 0.0 {
                    src, rot := rock_sprite(lk, i, game.ents.gens[i])
                    s := e.radius * 2.75
                    g.sprite(a.tex, src, p, vec2(s), rot, vec2(s * 0.5), color_u32(vec4(0.8, 0.95, 1.0, fx.hit[i] * 8.0)))
                }
            }
            _ => {}
        }
    }
}

// The world: backdrop, rocks, smoke and debris, the ship, then the light.
fn draw_world(g: *Gfx, lk: *Look, game: *Game, alpha: f32) {
    a := &lk.art
    draw_backdrop(g, a, &lk.fx)
    for i in 0..game.ents.len {
        if game.ents.is_live(i) && game.ents.items[i].kind == Rock {
            e := &game.ents.items[i]
            src, rot := rock_sprite(lk, i, game.ents.gens[i])
            s := e.radius * 2.75
            g.sprite(a.tex, src, shown(e, alpha), vec2(s), rot, vec2(s * 0.5), WHITE)
        }
    }
    draw_particles(g, a, &lk.fx, false)
    p := game.ents.get(game.player)
    if p != nil {
        at := shown(p, alpha)
        g.set_blend(BlendAdd)
        draw_flames(g, lk, at, p.vel)
        g.set_blend(BlendAlpha)
        frame := clamp(i64(round((lk.fx.bank + 1.0) * 0.5 * f32(SHIP_FRAMES - 1))), 0, SHIP_FRAMES - 1)
        g.sprite(a.tex, a.ship[frame], at, vec2(SHIP_SIZE), 0.0, vec2(SHIP_SIZE * 0.5), WHITE)
    }
    g.set_blend(BlendAdd)
    draw_light(g, lk, game, alpha)
    g.set_blend(BlendAlpha)
}

// How far a panel is up: 0 while playing, 1 while paused or a moment after the end.
fn panel_amount(lk: *Look, game: *Game, paused: bool) -> f32 {
    if paused { 1.0 } else if game.over { smoothstep(0.9, 1.7, lk.fx.over_t) } else { 0.0 }
}

fn alpha_of(c: u32, a: f32) -> u32 { (c & 0x00FFFFFF) | (u32(saturate(a) * 255.0) << 24) }

// A panel at the centre of the view: a title, the final score if `score` >= 0, a hint. With
// `glow` only the title, for the glow texture (the title then blooms like the lights).
fn draw_panel(g: *Gfx, lk: *Look, title: str, title_color: u32, score: i64, hint: str, amount: f32, glow: bool) {
    t := &lk.text
    a := &lk.art
    h: f32 = if score >= 0 { 92.0 } else { 62.0 }
    box := vec4(76.0, (f32(WORLD_H) - h) * 0.5 - (1.0 - amount) * 6.0, 168.0, h)
    cx := f32(WORLD_W) * 0.5
    if glow {
        g.draw_text(t.big, cx, box.y + 7.0, title, alpha_of(title_color, amount * 0.8), AlignCenter)
        return
    }
    nine_slice(g, a.tex, a.panel, box, 5.0, color_u32(vec4(0.03, 0.05, 0.12, 0.80 * amount)))
    nine_slice(g, a.tex, a.frame, box, 5.0, color_u32(vec4(0.35, 0.75, 1.0, 0.45 * amount)))
    g.rect(vec4(box.x + 14.0, box.y, box.z - 28.0, 1.0), alpha_of(title_color, amount * 0.9))   // an accent on top
    g.draw_text(t.big, cx, box.y + 7.0, title, alpha_of(title_color, amount), AlignCenter)
    g.rect(vec4(cx - 36.0, box.y + 37.0, 72.0, 0.5), color_u32(vec4(0.35, 0.75, 1.0, 0.6 * amount)))
    y := box.y + 43.0
    if score >= 0 {
        g.draw_text(t.small, cx, y, "FINAL SCORE", alpha_of(LABEL, amount), AlignCenter)
        g.draw_text(t.mid, cx, y + 10.0, fmt(score), alpha_of(0xFF80E0FF, amount), AlignCenter)
        y += 30.0
    }
    g.draw_text(t.small, cx, y, hint, alpha_of(0xFFC8B4A0, amount), AlignCenter)
}

// The pause and game-over panels, once they are up.
fn draw_panels(g: *Gfx, lk: *Look, game: *Game, paused: bool, glow: bool) {
    amount := panel_amount(lk, game, paused)
    if paused {
        draw_panel(g, lk, "PAUSED", 0xFFFFE0A0, -1, "Click the window to go on", 1.0, glow)
    } else if amount > 0.0 {
        draw_panel(g, lk, "GAME OVER", 0xFF5070FF, game.score, "Fire to play again, Escape to quit", amount, glow)
    }
}
// The HUD, sharp, in virtual pixels over everything.
fn draw_hud(g: *Gfx, lk: *Look, game: *Game, paused: bool, note: str) {
    t := &lk.text
    a := &lk.art
    fx := &lk.fx
    w := f32(WORLD_W)
    // a shade behind the top line
    top := color_u32(vec4(0.0, 0.0, 0.05, 0.55))
    clear := color_u32(vec4(0.0, 0.0, 0.05, 0.0))
    g.triangle(vec2(0.0, 0.0), vec2(w, 0.0), vec2(0.0, 30.0), top, top, clear)
    g.triangle(vec2(w, 0.0), vec2(w, 30.0), vec2(0.0, 30.0), top, clear, clear)
    g.draw_text(t.small, 9.0, 5.0, "SCORE", LABEL)
    bump := color_u32(lerp(vec4(1.0), vec4(1.0, 0.85, 0.45, 1.0), fx.bump))
    g.draw_text(t.mid, 9.0, 13.0, fmt(i64(fx.score + 0.5)), bump)
    g.draw_text(t.small, w - 9.0, 5.0, "HULL", LABEL, AlignRight)
    hp := player_hp(game)
    for k in 0..3 {
        tint := if k < hp { WHITE } else { 0x5A806050 }
        g.sprite(a.tex, a.ship[SHIP_FRAMES / 2], vec4(w - 19.0 - f32(k) * 12.0, 14.0, 10.0, 10.0), tint)
    }
    // +10 where a rock broke, rising and fading
    for i in 0..fx.npops {
        q := &fx.pops[i]
        k := q.age / 0.9
        y := q.pos.y - 12.0 - ease_out_cubic(k) * 18.0
        fade := 1.0 - k * k
        g.draw_text(t.small, q.pos.x + 0.5, y + 0.5, fmt("+", q.value), color_u32(vec4(0.0, 0.0, 0.0, fade * 0.7)), AlignCenter)
        g.draw_text(t.small, q.pos.x, y, fmt("+", q.value), color_u32(vec4(1.0, 0.88, 0.5, fade)), AlignCenter)
    }
    draw_panels(g, lk, game, paused, false)

    if note != "" {
        g.draw_text(t.small, 4.0, f32(WORLD_H) - line_height(t.small) - 1.0, note, 0xFF60C0FF)
    }
}

// Drawing only reads the game (and the effects that look at it). `alpha` is how far the display
// is between two simulation steps.
fn render(g: *Gfx, lk: *Look, game: *Game, alpha: f32, paused: bool, note: str) -> str {
    if !g.begin_frame(0xFF000000) {
        return ""                                          // minimized
    }
    shake := fx_shake(&lk.fx)
    frost := panel_amount(lk, game, paused)
    // the world into the scene texture, at the size it has on the screen
    sc := lk.post.scene
    g.set_target(sc)
    g.clear(SPACE)
    g.set_transform(xform_mul(xform_scale(vec2(f32(sc.w) / f32(WORLD_W), f32(sc.h) / f32(WORLD_H))), shake))
    draw_world(g, lk, game, alpha)
    // what shines, again, into the glow texture; then the blur chains
    g.set_target(lk.post.glow)
    g.clear(0xFF000000)
    g.set_transform(shake)
    g.set_blend(BlendAdd)
    p := game.ents.get(game.player)
    if p != nil {
        draw_flames(g, lk, shown(p, alpha), p.vel)
    }
    draw_light(g, lk, game, alpha)
    g.set_transform(xform_identity())
    draw_panels(g, lk, game, paused, true)
    post_blur(g, &lk.post, frost > 0.0)
    // the screen: the view letterboxed, the post-processing, the HUD
    g.reset_target()
    g.set_view(f32(WORLD_W), f32(WORLD_H))
    post_composite(g, &lk.post, &lk.art, frost, lk.fx.flash)
    draw_hud(g, lk, game, paused, note)
    g.end_frame()
}

fn print_stats(g: *Gfx) {
    s := g.stats
    eprint(fmt("gfx: ", g.device, ": ", s.draw_calls, " draw calls, ", s.passes, " passes, ", s.vertices,
        " vertices, ", s.dropped, " dropped (the last frame)"))
}

fn run_window(o: GameOptions) {
    w, ok := window_open(WindowDesc{title: "AL starter (std.gfx)", width: WORLD_W * 3, height: WORLD_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    g, err := gfx_open(w, GfxDesc{software: o.warp})
    if err != "" {
        panic(err)
    }
    g.vsync = o.vsync
    lk := look_new(g)
    snd := starter_sound()
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)   // no sound device: the audio calls do nothing
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    pad := &w.input.pad
    gamepad_open(pad, 0)
    game := game_new(u64(time_ns()))
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    slow := 0                                              // frames that took longer than 1/50 s
    worst: f64 = 0.0
    worst_at := 0
    pad_retry: f64 = 0.0
    while !w.should_close() && frames != o.frames {
        w.poll()
        inp := &w.input
        if pad.connected {
            gamepad_poll(pad)
        } else if clock.elapsed >= pad_retry {             // plugged in later: look every 2 s
            gamepad_open(pad, 0)
            pad_retry = clock.elapsed + 2.0
        }
        if game.keys.action_pressed(inp, game.act.quit) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if inp.key_pressed(KEY_M) {
            toggle_music(&snd)
        }
        if game.over && lk.fx.over_t > 1.0 && game.keys.action_pressed(inp, game.act.fire) {
            game = game_new(u64(time_ns()))
            snd.mixer.set_volume(snd.music_voice, 0.55)
        }
        paused := !inp.focused
        dt := clock.tick()
        if frames > 2 && dt > 0.02 {
            slow += 1
        }
        if frames > 2 && dt > worst {
            worst = dt
            worst_at = frames
        }
        if !paused {
            for k in 0..steps.advance(dt) {
                update(&game, inp, f32(steps.step))
            }
        }
        fx_frame(&lk.fx, &lk.art, &game, if paused { 0.0 } else { f32(fmin(dt, 0.1)) })
        play_events(&snd, &game)
        snd.mixer.set_paused(snd.music_voice, paused || !snd.music_on)
        audio_pump(dev, snd.mixer)
        note := if dev != nil && dev.lost { "Sound device lost, reconnecting" } else { "" }
        ww, wh := w.size()                                 // the size begin_frame will draw at
        if ww > 0 && wh > 0 && !w.minimized {
            view, _, _, vw, vh := fit_view(f32(WORLD_W), f32(WORLD_H), ww, wh)
            fonts_for(g, &lk.text, view.x.x)               // (not in the frame's scratch memory)
            post_size(g, &lk.post, vw, vh)
        }
        frame_begin()                                      // the texts of this frame are scratch memory
        rerr := render(g, &lk, &game, steps.alpha(), paused, note)
        if rerr != "" {
            panic(rerr)                                    // the GPU was lost (the text is scratch too: use it before frame_end)
        }
        frame_end()
        frames += 1
    }
    print("score", game.score, "frames", frames, "sound underruns", if dev == nil { 0 } else { dev.underruns })
    print_stats(g)
    eprint(fmt("frames slower than 1/50 s: ", slow, ", slowest ", fmtf(worst * 1000.0, 1), " ms (frame ", worst_at, "), ", fmtf(f64(frames) / clock.elapsed, 1), " fps"))
    audio_close(dev)
    gfx_close(g)
    w.close()
}

// --shot: the scripted input of the headless run drives the game and its effects for `frames`
// frames of 1/60 s, then one frame is drawn offscreen and saved as a PNG.
fn run_shot(o: GameOptions, path: str, paused: bool) {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        exit(1)
    }
    lk := look_new(g)
    game := game_new(7)
    inp: Input
    frames := if o.frames > 0 { o.frames } else { 600 }
    for f in 0..frames {
        inp.begin_frame()
        starter_script(&inp, f)
        for k in 0..2 {
            update(&game, &inp, 1.0 / f32(HZ))
        }
        fx_frame(&lk.fx, &lk.art, &game, 1.0 / 60.0)
        game.events.clear()
    }
    view, _, _, vw, vh := fit_view(f32(WORLD_W), f32(WORLD_H), SHOT_W, SHOT_H)
    fonts_for(g, &lk.text, view.x.x)
    post_size(g, &lk.post, vw, vh)
    rerr := render(g, &lk, &game, 0.0, paused, "")
    if rerr != "" {
        panic(rerr)
    }
    if !png_save(path, read_pixels(g)) {
        eprint(fmt("cannot write ", path))
        exit(1)
    }
    print("frames", frames, "score", game.score, "hp", player_hp(&game), "over", game.over, "particles", lk.fx.nparts)
    print_stats(g)
    gfx_close(g)
}

// --record FILE: the autopilot of pilot.al plays (game seed `seed`) for `frames` frames of
// 1/60 s, each drawn offscreen at 1280 x 720; the frames go raw (RGBA, top row first) into
// FILE.000, FILE.001, ... (60 frames each: join them in order), the sound of the game, mixed
// in step with the frames as the headless run does, into FILE.wav (16-bit stereo, 48 kHz).
// FILE `-` writes nothing (to try a seed): either way it prints what happened.
const CHUNK_FRAMES = 60

fn run_record(o: GameOptions, path: str, seed: u64) {
    g, err := gfx_offscreen(SHOT_W, SHOT_H, GfxDesc{software: o.warp})
    if err != "" {
        eprint(fmt("no device for std.gfx: ", err))
        exit(1)
    }
    write := path != "-"
    lk := look_new(g)
    view, _, _, vw, vh := fit_view(f32(WORLD_W), f32(WORLD_H), SHOT_W, SHOT_H)
    fonts_for(g, &lk.text, view.x.x)
    post_size(g, &lk.post, vw, vh)
    game := game_new(seed)
    snd := starter_sound()
    inp: Input
    pl := Pilot{ram_from: 9.0, ram_to: 12.0}
    frames := if o.frames > 0 { o.frames } else { 1320 }
    per := MIX_FRAMES * 2                                 // samples of one frame (stereo)
    pcm := alloc[i16](frames * per)
    size := SHOT_W * SHOT_H * 4
    chunk := if write { alloc[u8](CHUNK_FRAMES * size) } else { []u8{} }
    kills := 0
    hits := 0
    hit_at := -1
    over_at := -1
    for f in 0..frames {
        inp.begin_frame()
        pilot_input(&pl, &inp, &game, f)
        for k in 0..2 {
            update(&game, &inp, 1.0 / f32(HZ))
        }
        for e in game.events {
            match e.sfx {
                SfxBreak => { kills += 1 }
                SfxHurt => {
                    hits += 1
                    hit_at = f
                }
                SfxOver => { over_at = f }
                _ => {}
            }
        }
        fx_frame(&lk.fx, &lk.art, &game, 1.0 / 60.0)
        play_events(&snd, &game)
        snd.mixer.mix_i16(pcm[f * per..(f + 1) * per], MIX_FRAMES)
        if write {
            frame_begin()
            rerr := render(g, &lk, &game, 0.0, false, "")
            if rerr != "" {
                panic(rerr)
            }
            n := f % CHUNK_FRAMES
            copy(chunk[n * size..(n + 1) * size], read_pixels(g).pix)
            frame_end()
            if n == CHUNK_FRAMES - 1 || f == frames - 1 {
                name := fmt(path, ".", fmti(f / CHUNK_FRAMES, 3, '0'))
                if !write_file(name, chunk[..(n + 1) * size]) {
                    eprint(fmt("cannot write ", name))
                    exit(1)
                }
            }
        }
    }
    if write && !write_file(fmt(path, ".wav"), wav_i16(pcm, AUDIO_RATE, 2)) {
        eprint(fmt("cannot write ", path, ".wav"))
        exit(1)
    }
    print("frames", frames, "seed", seed, "score", game.score, "kills", kills, "hits", hits, fmt("(last at frame ", hit_at, ")"), "hp", player_hp(&game), "over at frame", over_at)
    print_stats(g)
    gfx_close(g)
}

// A WAV file image of 16-bit samples (interleaved channels).
fn wav_i16(pcm: []i16, rate: i64, channels: i64) -> str {
    data := len(pcm) * 2
    b := alloc[u8](44 + data)
    fn put(b: []u8, at: i64, v: i64, n: i64) {
        for i in 0..n {
            b[at + i] = u8(v >> (8 * i))
        }
    }
    copy(b[0..4], "RIFF")
    put(b, 4, 36 + data, 4)
    copy(b[8..16], "WAVEfmt ")
    put(b, 16, 16, 4)
    put(b, 20, 1, 2)                                      // PCM
    put(b, 22, channels, 2)
    put(b, 24, rate, 4)
    put(b, 28, rate * channels * 2, 4)
    put(b, 32, channels * 2, 2)
    put(b, 34, 16, 2)
    copy(b[36..40], "data")
    put(b, 40, data, 4)
    for i, x in pcm {
        put(b, 44 + i * 2, i64(x), 2)
    }
    b
}

fn main() {
    // --shot FILE, --paused, --record FILE and --seed N are this front end's; the rest are the
    // options of both games
    a := vec[str]()
    shot := ""
    record := ""
    seed: u64 = 7
    paused := false
    k := 0
    while k < len(args()) {
        s := args()[k]
        if s == "--shot" && k + 1 < len(args()) {
            shot = args()[k + 1]
            k += 1
        } else if s == "--record" && k + 1 < len(args()) {
            record = args()[k + 1]
            k += 1
        } else if s == "--seed" && k + 1 < len(args()) {
            n, ok := parse_u64(args()[k + 1])
            if !ok {
                eprint(fmt("--seed: not a number: ", args()[k + 1]))
                exit(2)
            }
            seed = n
            k += 1
        } else if s == "--paused" {
            paused = true
        } else {
            a.push(s)
        }
        k += 1
    }
    o, err := parse_options(a[..])
    if err != "" {
        eprint(err)
        exit(2)
    }
    if o.headless {
        starter_headless(o.frames)
        return
    }
    if shot != "" {
        run_shot(o, shot, paused)
        return
    }
    if record != "" {
        run_record(o, record, seed)
        return
    }
    run_window(o)
}
