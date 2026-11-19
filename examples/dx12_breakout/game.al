// Breakout with Direct3D 12 and WASAPI (Windows), in neon: a title screen, a pause menu with
// volume settings, a fixed-step simulation that pauses when the window loses the focus, a
// window of any size and fullscreen with the picture letterboxed, and keyboard or gamepad.
// Glass bricks that shatter, sparks, a glowing ball with a trail, screen shake, bloom.
//
//   alc build --target windows --gui examples/dx12_breakout/game.al     then run game.exe
//   game.exe --headless           no window, GPU or sound device: prints checksums (headless.al)
//   game.exe --shot FILE.png --frames N [--shot-idle F]
//                                 no window or sound: the scripted player of the headless run
//                                 plays N frames (from frame F on it only launches the ball, so
//                                 the game ends), then the last frame is drawn offscreen at
//                                 1280 x 720 and saved as a PNG
//   game.exe --record FILE.rgba [--frames N]
//                                 no window or sound device: the video run of record.al (title,
//                                 then a bot playing a nearly cleared wall to the end; N frames,
//                                 default 1290 at 60 fps) drawn offscreen at 1280 x 720; every
//                                 frame's RGBA pixels (top row first) one after another in FILE,
//                                 and the sound mixed in step as FILE with .wav for .rgba
//                                 (16-bit stereo, 48 kHz). About 3.7 MB a frame
//   --d3d-debug                   the Direct3D debug layer, its messages on standard error
//
// Arrows / A D / D-pad / left stick move, Space / Up / pad A launches, Escape / P / pad Start
// pauses (the menu: arrows or D-pad, Enter or A; Escape or B goes back), F11 or Alt+Enter
// toggles fullscreen, Escape on the title screen quits. More options: gamekit/options.al.
//
// The parts: logic.al (the game: rules, menus, the fixed step), sound.al (generated sounds),
// headless.al (the scripted run), record.al (the video run), fx.al (effects made from the
// game's events), draw.al (what a frame shows), render.al (Direct3D 12: background, sprites,
// bloom), this file (window, sound device, the loop), and ../gamekit (device set-up, options,
// synthesizer). The sprites are tiles.png (made by make_tiles.al, laid out by sheet.al), built
// into the executable with embed.
use std.os
use std.window
use std.audio
use std.image
use "logic.al"
use "sound.al"
use "headless.al"
use "../gamekit/options.al"
use "render.al"
use "fx.al"
use "draw.al"
use "record.al"

const TILES_PNG = embed("tiles.png")
const SHOT_W = 1280
const SHOT_H = 720

// The sprite sheet with the letters of a system font added below the sprites, its alpha
// premultiplied (render.al blends so).
fn load_sheet() -> Image {
    tiles, ok := image_decode(TILES_PNG)
    if !ok {
        panic("tiles.png cannot be decoded")
    }
    img := image_new(SHEET_W, LETTERS_H, 4)
    blit(&img, convert(tiles, 4), 0, 0)
    letters_build(&img, LETTERS_Y)
    premultiply_alpha(&img)
    img
}

// The options of this front end that gamekit/options.al does not know.
struct Extra {
    shot: str            // "": no screenshot run
    idle: i64            // the frame from which the screenshot run's player only launches; -1: never
    debug: bool          // --d3d-debug
    record: str          // "": no video run
}

// Takes this file's options out of the command line; the rest is for parse_options.
fn split_options(a: []str) -> ([]str, Extra, str) {
    x := Extra{idle: -1}
    rest := vec[str]()
    k := 0
    while k < len(a) {
        s := a[k]
        if s == "--shot" && k + 1 < len(a) {
            x.shot = a[k + 1]
            k += 1
        } else if s == "--shot-idle" && k + 1 < len(a) {
            n, ok := parse_i64(a[k + 1])
            if !ok {
                return (rest.items(), x, fmt("--shot-idle: not a number: ", a[k + 1]))
            }
            x.idle = n
            k += 1
        } else if s == "--record" && k + 1 < len(a) {
            x.record = a[k + 1]
            k += 1
        } else if s == "--d3d-debug" {
            x.debug = true
        } else {
            rest.push(s)
        }
        k += 1
    }
    (rest.items(), x, "")
}

// One picture: the look, the background, the sprites, bloom and composite.
fn render(r: *Renderer, fx: *Fx, g: *Game, alpha: f32, note: str, capture: bool) -> (Image, str) {
    look := make_look(g, fx)
    b := render_begin(r, &look)
    draw_frame(b, g, fx, alpha, note)
    render_end(r, &look, capture)
}

// ---- the platform shell ------------------------------------------------------------------

fn run_window(o: GameOptions, x: Extra) {
    w, ok := window_open(WindowDesc{title: "AL breakout (Direct3D 12)", width: VIEW_W * 3, height: VIEW_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    r, err := renderer_window(w, VIEW_W, VIEW_H, load_sheet(), o.warp, x.debug)
    if err != "" {
        panic(err)
    }
    r.vsync = o.vsync
    snd := breakout_sound()
    // no sound device is not an error: the audio calls then do nothing
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    pad := &w.input.pad
    gamepad_open(pad, 0)
    g := game_new(u64(time_ns()))
    fx := fx_new(u64(time_ns()))
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    pad_retry: f64 = 0.0
    settled: i64 = 0                     // memory in use after frame 100: it must stay the same
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
        dt := clock.tick()
        for k in 0..steps.advance(dt) {
            update(&g, inp, f32(steps.step))
        }
        // the effects read the frame's events before the sound plays (and forgets) them
        alpha := steps.alpha()
        fx_frame(fx, &g, f32(fmin(dt, 0.1)), ball_at(&g, alpha))
        // output: sound first (Present waits for the display), then the picture
        play_events(&snd, &g)
        audio_pump(dev, snd.mixer)
        frame_begin()
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { "" }
        _, rerr := render(r, fx, &g, alpha, note, false)
        if rerr != "" {
            panic(rerr)
        }
        frame_end()
        frames += 1
        if frames == 100 {
            settled = mem_used()
        }
    }
    print("best", max(g.best, g.score), "frames", frames, "resizes", r.resizes, "sound underruns",
        if dev == nil { 0 } else { dev.underruns })
    growth := if frames > 100 { mem_used() - settled } else { 0 }
    print("fps", fmtf(clock.fps, 1), "memory growth after frame 100", growth, "adapter", r.g.adapter_name,
        "debug messages", r.messages)
    audio_close(dev)
    renderer_close(r)
    w.close()
}

// ---- screenshots ---------------------------------------------------------------------------

priv fn tap(inp: *Input, k: i64) {
    inp.feed(Event{kind: EventKeyDown, key: k})
    inp.feed(Event{kind: EventKeyUp, key: k})
}

// The scripted player of the screenshot run after --shot-idle: it lets go of the keys and only
// launches the ball, so the balls are lost and the game ends.
priv fn idle_player(g: *Game, inp: *Input, f: i64) {
    for k in [_]i64{KEY_LEFT, KEY_RIGHT} {
        if inp.key_down(k) {
            inp.feed(Event{kind: EventKeyUp, key: k})
        }
    }
    gamepad_event(&inp.pad, 2, u8(PAD_AXIS_LX), 0)
    if g.stuck && f % 60 == 0 {
        tap(inp, KEY_SPACE)
    }
}

// The headless run's game, driven as there, then its last frame drawn offscreen and saved.
fn run_shot(o: GameOptions, x: Extra) -> i64 {
    r, err := renderer_offscreen(SHOT_W, SHOT_H, VIEW_W, VIEW_H, load_sheet(), o.warp, x.debug)
    if err != "" {
        eprint(err)
        return 1
    }
    g := game_new(11)
    fx := fx_new(5)
    inp: Input
    inp.focused = true
    frames := if o.frames > 0 { o.frames } else { 600 }
    for f in 0..frames {
        inp.begin_frame()
        if x.idle < 0 || f < x.idle {
            breakout_script(&g, &inp, f)
        } else {
            idle_player(&g, &inp, f)
        }
        if !inp.focused {
            lose_focus(&g)
        }
        handle_input(&g, &inp)
        g.want_fullscreen = false
        g.want_quit = false
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        fx_frame(fx, &g, 1.0 / 60.0, ball_at(&g, 1.0))
        g.events.clear()
    }
    img, rerr := render(r, fx, &g, 1.0, "", true)
    if rerr != "" {
        eprint(rerr)
        renderer_close(r)
        return 1
    }
    mode := match g.mode { Title => "title"; Playing => "playing"; Paused => "paused"; GameOver => "over" }
    saved := png_save(x.shot, img)
    print("shot", x.shot, img.w, "x", img.h, "frames", frames, "mode", mode, "level", g.level, "score", g.score,
        "lives", g.lives, "saved", saved, "adapter", r.g.adapter_name)
    renderer_close(r)
    if saved && r.messages == 0 { 0 } else { 1 }
}

// ---- the video -----------------------------------------------------------------------------

const RECORD_CHUNK = 30              // frames per piece: AL writes whole files, cmd joins them

// record.al's video run drawn offscreen, the frames into x.record, the sound beside it.
fn run_record(o: GameOptions, x: Extra) -> i64 {
    r, err := renderer_offscreen(SHOT_W, SHOT_H, VIEW_W, VIEW_H, load_sheet(), o.warp, x.debug)
    if err != "" {
        eprint(err)
        return 1
    }
    v := video_new()
    fx := fx_new(5)
    snd := breakout_sound()
    frames := if o.frames > 0 { o.frames } else { 1290 }
    size := SHOT_W * SHOT_H * 4
    chunk := alloc[u8](RECORD_CHUNK * size)
    sound := vec[i16]()
    sound.reserve(frames * VIDEO_MIX * 2)
    mix := alloc[i16](VIDEO_MIX * 2)
    parts := vec[str]()
    n := 0
    for f in 0..frames {
        video_frame(&v, fx)
        play_events(&snd, &v.g)                      // the frame's sounds (and forgets the events)
        snd.mixer.mix_i16(mix, VIDEO_MIX)
        sound.extend(mix)
        m := mark()
        img, rerr := render(r, fx, &v.g, 1.0, "", true)
        if rerr != "" {
            eprint(rerr)
            renderer_close(r)
            return 1
        }
        copy(chunk[n * size..(n + 1) * size], img.pix)
        release(m)
        n += 1
        if n == RECORD_CHUNK || f == frames - 1 {
            part := fmt(x.record, ".", fmti(len(parts), 3, '0'))
            if !write_file(part, chunk[..n * size]) {
                eprint(fmt("cannot write ", part))
                return 1
            }
            parts.push(replace(part, "/", "\\"))
            n = 0
        }
    }
    renderer_close(r)
    wav := if ends_with(x.record, ".rgba") { fmt(x.record[..len(x.record) - 5], ".wav") } else { fmt(x.record, ".wav") }
    if !write_file(wav, wav_bytes(sound.items(), AUDIO_RATE)) {
        eprint(fmt("cannot write ", wav))
        return 1
    }
    // the pieces into one file, then away
    out := replace(x.record, "/", "\\")
    joined := run([]str{"cmd", "/c", "copy", "/b", "/y", join(parts.items(), "+"), out})
    for p in parts {
        run([]str{"cmd", "/c", "del", p})
    }
    print("record", x.record, "frames", frames, "wav", wav, "wall cleared at frame", v.cleared, "level", v.g.level,
        "score", v.g.score, "lives", v.g.lives, "join status", joined, "debug messages", r.messages)
    if joined == 0 { 0 } else { 1 }
}

fn main() -> i64 {
    rest, x, xerr := split_options(args())
    if xerr != "" {
        eprint(xerr)
        return 2
    }
    o, err := parse_options(rest)
    if err != "" {
        eprint(err)
        return 2
    }
    if o.headless {
        breakout_headless(o.frames)
        return 0
    }
    if x.shot != "" {
        return run_shot(o, x)
    }
    if x.record != "" {
        return run_record(o, x)
    }
    run_window(o, x)
    0
}
