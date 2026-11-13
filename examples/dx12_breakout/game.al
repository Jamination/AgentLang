// Breakout with Direct3D 12 and WASAPI (Windows): a title screen, a pause menu with volume
// settings, a fixed-step simulation that pauses when the window loses the focus, a window of
// any size and fullscreen with the picture letterboxed, and keyboard or gamepad.
//
//   alc build --target windows --gui examples/dx12_breakout/game.al     then run game.exe
//   game.exe --headless           no window, GPU or sound device: prints checksums (headless.al)
//
// Arrows / A D / D-pad / left stick move, Space / Up / pad A launches, Escape / P / pad Start
// pauses (the menu: arrows or D-pad, Enter or A; Escape or B goes back), F11 or Alt+Enter
// toggles fullscreen, Escape on the title screen quits. More options: gamekit/options.al.
//
// The parts: logic.al (the game: rules, menus, the fixed step), sound.al (generated sounds),
// headless.al (the scripted run), this file (window, GPU, sound device, drawing), and
// ../gamekit (the Direct3D 12 screen, the bitmap font, the synthesizer). The sprites are
// tiles.png (made by make_tiles.al), built into the executable with embed.
use std.window
use std.audio
use std.image
use "logic.al"
use "sound.al"
use "headless.al"
use "../gamekit/screen.al"
use "../gamekit/options.al"

const TILES_PNG = embed("tiles.png")
const TILES_Y = FONT_ATLAS_H             // the tiles' place in the atlas, below the font

const WHITE: u32 = 0xFFFFFFFF
const YELLOW: u32 = 0xFF40E0FF
const GREY: u32 = 0xFFA0A0A0
const BACKGROUND: u32 = 0xFF281810
const WALL: u32 = 0xFF706860

// The atlas: the font, and below it the tiles decoded from the PNG.
fn make_atlas() -> (Image, Font) {
    tiles, ok := image_decode(TILES_PNG)
    if !ok {
        panic("tiles.png cannot be decoded")
    }
    tiles = convert(tiles, 4)
    img := image_new(FONT_ATLAS_W, FONT_ATLAS_H + tiles.h, 4)
    font := font_bake(&img, 0, 0)
    blit(&img, tiles, 0, TILES_Y)
    (img, font)
}

// ---- drawing: reads the game, never changes it ------------------------------------------

fn render(sc: *Screen, font: Font, g: *Game, alpha: f32, note: str) -> str {
    s := sc.screen_begin(BACKGROUND)
    draw_field(s, g, alpha)
    draw_hud(s, font, g)
    cx := f32(VIEW_W) / 2.0
    blink := fmod(g.time, 1.0) < 0.6
    match g.mode {
        Title => {
            s.sprite_rect(0.0, 0.0, f32(VIEW_W), f32(VIEW_H), 0x99000000)
            draw_text_centered(s, font, cx, 34.0, 4.0, "BREAKOUT", YELLOW)
            if blink {
                draw_text_centered(s, font, cx, 90.0, 1.0, "PRESS ENTER OR A TO PLAY", WHITE)
            }
            if g.best > 0 {
                draw_text_centered(s, font, cx, 108.0, 1.0, fmt("BEST ", g.best), GREY)
            }
            draw_text_centered(s, font, cx, 140.0, 1.0, "ARROWS / STICK MOVE    SPACE / A LAUNCH", GREY)
            draw_text_centered(s, font, cx, 150.0, 1.0, "ESC / START PAUSE    F11 FULLSCREEN", GREY)
            draw_text_centered(s, font, cx, 164.0, 1.0, "ESC: QUIT", GREY)
        }
        Playing => {
            if g.banner > 0.0 {
                draw_text_centered(s, font, cx, 104.0, 2.0, fmt("LEVEL ", g.level), WHITE)
            } else if g.stuck && blink {
                draw_text_centered(s, font, cx, 120.0, 1.0, "SPACE OR A TO LAUNCH", GREY)
            }
        }
        Paused => draw_menu(s, font, g)
        GameOver => {
            s.sprite_rect(0.0, 0.0, f32(VIEW_W), f32(VIEW_H), 0x99000000)
            draw_text_centered(s, font, cx, 50.0, 3.0, "GAME OVER", 0xFF5050F0)
            draw_text_centered(s, font, cx, 90.0, 1.0, fmt("SCORE ", g.score, "    BEST ", g.best), WHITE)
            if blink {
                draw_text_centered(s, font, cx, 120.0, 1.0, "PRESS ENTER OR A", WHITE)
            }
        }
    }
    if note != "" {
        draw_text(s, font, 2.0, f32(VIEW_H) - 9.0, 1.0, note, 0xFF60C0FF)
    }
    sc.screen_end()
}

fn draw_field(s: *Sprites, g: *Game, alpha: f32) {
    s.sprite_rect(FIELD_L - 6.0, FIELD_T - 6.0, FIELD_R - FIELD_L + 12.0, 6.0, WALL)
    s.sprite_rect(FIELD_L - 6.0, FIELD_T, 6.0, f32(VIEW_H) - FIELD_T, WALL)
    s.sprite_rect(FIELD_R, FIELD_T, 6.0, f32(VIEW_H) - FIELD_T, WALL)
    layout := LEVELS[(max(g.level, 1) - 1) % len(LEVELS)]
    for i in 0..ROWS * COLS {
        hp := g.bricks[i]
        if hp == 0 {
            continue
        }
        r := brick_rect(i)
        full := i64(layout[i / COLS][i % COLS] - '0')
        // armoured while it has 3 hit points, cracked once hit
        sx: f32 = if hp >= 3 { 24.0 } else { 0.0 }
        sy: f32 = if i64(hp) < full && hp < 3 { 8.0 } else { 0.0 }
        s.sprite(r.x, r.y, r.z, r.w, sx, f32(TILES_Y) + sy, BRICK_W, BRICK_H, row_color(i / COLS))
    }
    for i in 0..g.sparks.len {
        if g.sparks.is_live(i) {
            p := &g.sparks.items[i]
            a := u32(clamp(p.life * 2.0, 0.0, 1.0) * 255.0)
            s.sprite_rect(p.pos.x - 1.0, p.pos.y - 1.0, 2.0, 2.0, (p.color & 0xFFFFFF) | (a << 24))
        }
    }
    if g.mode == Title {
        return
    }
    x := lerp(g.paddle_prev, g.paddle, alpha)
    s.sprite(x - PADDLE_W / 2.0, PADDLE_Y, PADDLE_W, PADDLE_H, 0.0, f32(TILES_Y) + 16.0, PADDLE_W, PADDLE_H, WHITE)
    b := if g.mode == Playing { lerp(g.ball_prev, g.ball, alpha) } else { g.ball }
    s.sprite(b.x - BALL_R, b.y - BALL_R, 2.0 * BALL_R, 2.0 * BALL_R, 40.0, f32(TILES_Y) + 16.0, 6.0, 6.0, WHITE)
}

fn draw_hud(s: *Sprites, font: Font, g: *Game) {
    if g.mode == Title {
        return
    }
    draw_text(s, font, FIELD_L, 3.0, 1.0, fmt("SCORE ", fmti(g.score, 5, '0')), WHITE)
    draw_text_centered(s, font, f32(VIEW_W) / 2.0, 3.0, 1.0, fmt("LEVEL ", g.level), GREY)
    for k in 0..g.lives {
        s.sprite(FIELD_R - 6.0 - f32(k) * 9.0, 3.0, 6.0, 6.0, 40.0, f32(TILES_Y) + 16.0, 6.0, 6.0, WHITE)
    }
}

fn draw_menu(s: *Sprites, font: Font, g: *Game) {
    s.sprite_rect(0.0, 0.0, f32(VIEW_W), f32(VIEW_H), 0xAA000000)
    cx := f32(VIEW_W) / 2.0
    draw_text_centered(s, font, cx, 30.0, 2.0, "PAUSED", WHITE)
    labels := [MENU_ITEMS]str{"RESUME", "MUSIC", "SOUND", "FULLSCREEN", "QUIT TO TITLE"}
    for i, label in labels {
        y := 62.0 + f32(i) * 16.0
        color := if i == g.menu { YELLOW } else { WHITE }
        if i == g.menu {
            draw_text(s, font, 90.0, y, 1.0, ">", YELLOW)
        }
        draw_text(s, font, 100.0, y, 1.0, label, color)
        level := if i == MENU_MUSIC { g.settings.music } else if i == MENU_SOUND { g.settings.sound } else { -1 }
        if level >= 0 {
            for k in 0..VOLUME_STEPS {
                on := k < level
                s.sprite_rect(170.0 + f32(k) * 6.0, y, 4.0, 7.0, if on { color } else { 0xFF404040 })
            }
        }
    }
    draw_text_centered(s, font, cx, 150.0, 1.0, "LEFT / RIGHT CHANGE    ESC / B BACK", GREY)
}

// ---- the platform shell ------------------------------------------------------------------

fn run_window(o: GameOptions) {
    w, ok := window_open(WindowDesc{title: "AL breakout (Direct3D 12)", width: VIEW_W * 3, height: VIEW_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    atlas, font := make_atlas()
    sc, err := screen_open(w, VIEW_W, VIEW_H, atlas, 2048, o.warp)
    if err != "" {
        panic(err)
    }
    sc.vsync = o.vsync
    snd := breakout_sound()
    // no sound device is not an error: the audio calls then do nothing
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    pad := &w.input.pad
    gamepad_open(pad, 0)
    g := game_new(u64(time_ns()))
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    pad_retry: f64 = 0.0
    while !w.should_close() && frames != o.frames {
        // input: the only place the outside world enters
        w.poll()
        inp := &w.input
        if pad.connected {
            gamepad_poll(pad)
        } else if clock.elapsed >= pad_retry {            // plugged in later: look every 2 s
            gamepad_open(pad, 0)
            pad_retry = clock.elapsed + 2.0
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        } else {
            if !inp.focused {
                lose_focus(&g)
            }
            handle_input(&g, inp)
        }
        if g.want_fullscreen {
            g.want_fullscreen = false
            w.set_fullscreen(!w.fullscreen)
        }
        if g.want_quit {
            w.closing = true
        }
        // simulation: fixed steps (update itself does nothing while paused)
        for k in 0..steps.advance(clock.tick()) {
            update(&g, inp, f32(steps.step))
        }
        // output: sound first (Present waits for the display), then the picture
        play_events(&snd, &g)
        audio_pump(dev, snd.mixer)
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { "" }
        rerr := render(sc, font, &g, steps.alpha(), note)
        if rerr != "" {
            panic(rerr)
        }
        frames += 1
    }
    print("best", max(g.best, g.score), "frames", frames, "resizes", sc.resizes, "sound underruns",
        if dev == nil { 0 } else { dev.underruns })
    audio_close(dev)
    screen_close(sc)
    w.close()
}

fn main() {
    o, err := parse_options(args())
    if err != "" {
        eprint(err)
        exit(2)
    }
    if o.headless {
        breakout_headless(o.frames)
        return
    }
    run_window(o)
}
