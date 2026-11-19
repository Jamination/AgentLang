// The starter game (examples/starter) drawn with Direct3D 12 and heard through WASAPI: the same
// rules (../starter/logic.al), art painted at start-up (art.al), effects that only watch the
// game (fx.al), an HDR renderer with additive light, bloom and a tone curve (render.al) drawing
// what scene.al lays out, sound effects and a music loop generated at start-up (sound.al),
// keyboard and gamepad. Windows only:
//
//   alc build --target windows --gui examples/dx12_starter/game.al     then run game.exe
//   game.exe --headless           no window, GPU or sound device: prints checksums (headless.al)
//   game.exe --shot FILE.png      no window: plays the scripted input of the headless run for
//                                 --frames N frames (default 600), draws that frame offscreen
//                                 (1280 x 720, or --shot-size WxH) and saves it as PNG
//   game.exe --record FILE.rgba   no window: an autopilot plays (record.al); every frame, drawn as
//                                 --shot draws, is appended raw (RGBA, top row first) to FILE.rgba,
//                                 the sound mixed in step goes to FILE.wav; at most --frames N
//                                 (default 1500, 25 s at 60 fps), less if the game ends first
//   game.exe --debug-layer        the Direct3D 12 debug layer, its messages on standard error
//
// Arrows / WASD / D-pad / left stick move, Space / pad A shoots, M music on / off, F11 or
// Alt+Enter fullscreen, Escape / pad Back quits; after the end, fire plays again. The game
// pauses while its window does not have the focus. More options: gamekit/options.al.
use std.window
use std.audio
use std.image
use "../starter/logic.al"
use "../gamekit/options.al"
use "sound.al"
use "headless.al"
use "art.al"
use "fx.al"
use "render.al"
use "scene.al"
use "record.al"

// This front end's own options, next to those of gamekit/options.al.
struct Extra {
    shot: str                     // "": play in a window
    record: str                   // "": no recording
    shot_w: i64
    shot_h: i64
    debug: bool
}

// Takes --shot FILE, --record FILE, --shot-size WxH and --debug-layer out of the command line;
// the rest is for parse_options. Returns what is left, the options, and "" or what is wrong.
fn own_options(a: []str) -> ([]str, Extra, str) {
    x := Extra{shot_w: 1280, shot_h: 720}
    rest := vec[str]()
    k := 0
    while k < len(a) {
        s := a[k]
        if k > 0 && s == "--shot" && k + 1 < len(a) {
            x.shot = a[k + 1]
            k += 1
        } else if k > 0 && s == "--record" && k + 1 < len(a) {
            x.record = a[k + 1]
            k += 1
        } else if k > 0 && s == "--shot-size" && k + 1 < len(a) {
            parts := split(a[k + 1], 'x')
            w, wok := parse_i64(parts[0])
            h, hok := if len(parts) == 2 { parse_i64(parts[1]) } else { (0, false) }
            if !wok || !hok || w < 16 || h < 16 {
                return (rest.items(), x, fmt("--shot-size: not WIDTHxHEIGHT: ", a[k + 1]))
            }
            x.shot_w = w
            x.shot_h = h
            k += 1
        } else if k > 0 && s == "--debug-layer" {
            x.debug = true
        } else {
            rest.push(s)
        }
        k += 1
    }
    (rest.items(), x, "")
}

fn run_window(o: GameOptions, x: Extra) {
    w, ok := window_open(WindowDesc{title: "AL starter (Direct3D 12)", width: WORLD_W * 3, height: WORLD_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    art := make_art()
    r, err := renderer_window(w, WORLD_W, WORLD_H, &art, o.warp, x.debug)
    if err != "" {
        panic(err)
    }
    r.vsync = o.vsync
    snd := starter_sound()
    // no sound device is not an error: the audio calls then do nothing
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    pad := &w.input.pad
    gamepad_open(pad, 0)
    g := game_new(u64(time_ns()))
    fx := fx_new(&g)
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
        if g.keys.action_pressed(inp, g.act.quit) {
            w.closing = true
        }
        if inp.key_pressed(KEY_F11) || (inp.key_pressed(KEY_ENTER) && inp.alt_down()) {
            w.set_fullscreen(!w.fullscreen)
        }
        if inp.key_pressed(KEY_M) {
            toggle_music(&snd)
        }
        if g.over && g.keys.action_pressed(inp, g.act.fire) {
            g = game_new(u64(time_ns()))
            fx_reset(&fx, &g)
            snd.mixer.set_volume(snd.music_voice, 0.55)
        }
        // simulation: fixed steps, none while the window is in the background
        paused := !inp.focused
        dt := clock.tick()
        if !paused {
            for k in 0..steps.advance(dt) {
                update(&g, inp, f32(steps.step))
            }
        }
        // output: sound first (Present waits for the display), then the picture; the effects
        // step with the frame (not while paused) and only look at the game
        play_events(&snd, &g)
        snd.mixer.set_paused(snd.music_voice, paused || !snd.music_on)
        audio_pump(dev, snd.mixer)
        fx_update(&fx, &g, if paused { 0.0 } else { f32(dt) })
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { "" }
        b := render_begin(r)
        frame_begin()                                     // the frame's text is scratch
        post := draw_frame(b, &art, &g, &fx, steps.alpha(), paused, note)
        _, rerr := render_end(r, post, false)
        frame_end()
        if rerr != "" {
            panic(rerr)
        }
        frames += 1
    }
    print("score", g.score, "frames", frames, "resizes", r.resizes, "sound underruns", if dev == nil { 0 } else { dev.underruns })
    audio_close(dev)
    renderer_close(r)
    w.close()
}

// --shot: the headless run's scripted input for o.frames frames (the effects stepping at
// 60 Hz along), then that frame drawn offscreen and saved.
fn run_shot(o: GameOptions, x: Extra) {
    frames := if o.frames < 0 { 600 } else { o.frames }
    art := make_art()
    r, err := renderer_offscreen(x.shot_w, x.shot_h, WORLD_W, WORLD_H, &art, o.warp, x.debug)
    if err != "" {
        panic(err)
    }
    g := game_new(7)
    fx := fx_new(&g)
    inp: Input
    for f in 0..frames {
        inp.begin_frame()
        starter_script(&inp, f)
        for k in 0..2 {
            update(&g, &inp, 1.0 / f32(HZ))
        }
        g.events.clear()
        fx_update(&fx, &g, 1.0 / f32(HEADLESS_FPS))
    }
    b := render_begin(r)
    post := draw_frame(b, &art, &g, &fx, 0.0, false, "")
    img, rerr := render_end(r, post, true)
    if rerr != "" {
        panic(rerr)
    }
    print("frame", frames, "score", g.score, "hp", player_hp(&g), "particles", fx.n, "sprites", b.count,
        "device", r.g.adapter_name, "debug layer", r.info != nil, "saved", x.shot, png_save(x.shot, img))
    renderer_close(r)
}

fn main() {
    rest, x, xerr := own_options(args())
    o, err := parse_options(rest)
    if xerr != "" || err != "" {
        eprint(if xerr != "" { xerr } else { err })
        exit(2)
    }
    if o.headless {
        starter_headless(o.frames)
        return
    }
    if x.shot != "" {
        run_shot(o, x)
        return
    }
    if x.record != "" {
        run_record(o, x.record, x.shot_w, x.shot_h, x.debug)
        return
    }
    run_window(o, x)
}
