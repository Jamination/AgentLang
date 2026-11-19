// Crypt's platform shell (Windows): the window loop with GPU, sound device, gamepad and save
// file, the test run that draws the scripted game offscreen and checks pixels, and --still,
// one frame of the scripted run drawn offscreen into a PNG.
use std.window
use std.audio
use std.image
use "logic.al"
use "sound.al"
use "save.al"
use "headless.al"
use "record.al"
use "render.al"

fn run_window(o: Options) {
    w, ok := window_open(WindowDesc{title: "Crypt (AL, Direct3D 12)", width: 1280, height: 720, resizable: true,
        fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    r, err := renderer_window(w, o.warp, o.debug)
    if err != "" {
        panic(err)
    }
    r.vsync = o.vsync
    snd := crypt_sound()
    dev, opened := audio_open(o.audio, AUDIO_RATE, 2, 60)
    if !opened {
        eprint(fmt("no sound: ", audio_error()))
    }
    g := game_new(u64(time_ns()))
    path := save_path(o.save_dir)
    if load_save(&g, path) {
        print("save file:", path, "best", g.best)
    }
    pad := &w.input.pad
    watch: GamepadWatch
    bot: Bot
    clock := frame_clock()
    steps := fixed_step(HZ)
    frames := 0
    save_error := ""
    settled: i64 = 0                     // memory in use after frame 100: it must stay the same
    while !w.should_close() && frames != o.frames {
        frame_begin()
        // input: the only place the outside world enters
        w.poll()
        inp := &w.input
        if gamepad_changed(&watch) && !pad.connected {
            gamepad_open(pad, 0)
        }
        gamepad_poll(pad)
        if o.script {
            script(&g, inp, &bot, frames)
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
        // mouse-look while playing, a free pointer in the menus
        playing := g.mode == Playing
        if w.cursor_locked != playing {
            w.set_cursor_locked(playing)
        }
        // simulation
        for k in 0..steps.advance(clock.tick()) {
            update(&g, inp, f32(steps.step))
        }
        if bot_track(&g, &bot) && o.script {
            print("frame", frames, mode_name(g.mode), "gems", g.got, "hp", g.hp, "score", g.score)
        }
        // the save file: when the menu closes after a change, and at once for a new best score
        if g.best_changed || (g.settings_changed && g.mode != Paused) {
            save_error = store_save(&g, path)
        }
        // output: sound first (Present waits for the display), then the picture
        play_events(&snd, &g)
        audio_pump(dev, snd.mixer)
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { save_error }
        shot := frames == o.shot_frame
        img, rerr := render_frame(r, &g, steps.alpha(), note, shot)
        if rerr != "" {
            panic(rerr)
        }
        if shot {
            print("screenshot:", o.shot_file, img.w, "x", img.h, png_save(o.shot_file, img))
        }
        frames += 1
        frame_end()
        if frames == 100 {
            settled = mem_used()
        }
    }
    growth := if frames > 100 { mem_used() - settled } else { 0 }
    g.settings_changed = true
    save_error = store_save(&g, path)
    if save_error != "" {
        eprint(save_error)
    }
    print("best", g.best, "frames", frames, "memory growth after frame 100", growth, "fps", fmtf(clock.fps, 1), "resizes", r.resizes, "sound underruns",
        if dev == nil { 0 } else { dev.underruns }, "adapter", r.g.adapter_name)
    if o.debug {
        print("debug layer messages", r.messages)
    }
    audio_close(dev)
    gamepad_watch_close(&watch)
    renderer_close(r)
    w.close()
}

// ---- the test: the scripted run drawn offscreen on WARP --------------------------------------

const TEST_W = 480
const TEST_H = 270

// A picture of the scripted run to take and check.
enum Shot { ShotTitle, ShotPlay, ShotMenu, ShotWraith, ShotWon, ShotLost }


priv const SHOT_NAMES = [variant_count[Shot]()]str{"title", "play", "menu", "wraith", "won", "lost"}
priv fn shot_name(s: Shot) -> str { SHOT_NAMES[i64(s)] }

// The colour of a pixel, 0..1.
priv fn pixel(img: Image, x: i64, y: i64) -> vec4 { img.get(x, y) }

// --still FILE: the scripted run without window or sound for --frames N frames (default 120),
// then that frame drawn offscreen (--size W H, default 1280 x 720) and saved as a PNG. Nothing
// depends on a window or its focus, so it works while other windows come and go.
fn run_still(o: Options) -> i64 {
    r, err := renderer_offscreen(o.still_w, o.still_h, o.warp, o.debug)
    if err != "" {
        eprint(err)
        return 1
    }
    h := headless_new(false)
    frames := if o.frames >= 0 { o.frames } else { 120 }
    for f in 0..frames {
        headless_frame(&h)
    }
    img, rerr := render_frame(r, &h.g, 0.5, "", true)
    if rerr != "" {
        eprint(rerr)
        return 1
    }
    g := &h.g
    print("still:", o.still_file, img.w, "x", img.h, png_save(o.still_file, img), "frame", frames, mode_name(g.mode),
        "at", fmtf(g.pos.x, 2), fmtf(g.pos.y, 2), "gems", g.got, "adapter", r.g.adapter_name)
    if o.debug {
        print("debug layer messages", r.messages)
    }
    renderer_close(r)
    0
}

// --record FILE: the video's game (record.al) drawn offscreen frame by frame and read back. AL
// writes whole files only, so the raw frames go out in chunks of 30 (FILE.000, FILE.001, ...);
// the sound, mixed in step with the frames, goes to FILE.wav. The grain is lighter than on the
// screen: it costs a video encoder many bits in the dark.
fn run_record(o: Options) -> i64 {
    r, err := renderer_offscreen(o.still_w, o.still_h, o.warp, o.debug)
    if err != "" {
        eprint(err)
        return 1
    }
    r.grain = 0.012
    rec := recording_new()
    frames := if o.frames >= 0 { o.frames } else { 1230 }
    chunk := 30
    size := o.still_w * o.still_h * 4
    buf := alloc[u8](chunk * size)
    held := 0
    parts := 0
    for f in 0..frames {
        recording_frame(&rec)
        m := mark()
        img, rerr := render_frame(r, &rec.g, 0.5, "", true)
        if rerr != "" {
            eprint(rerr)
            return 1
        }
        copy(buf[held * size..(held + 1) * size], img.pix)
        release(m)
        held += 1
        if held == chunk || f == frames - 1 {
            name := fmt(o.record_file, ".", fmti(parts, 3, '0'))
            if !write_file(name, buf[..held * size]) {
                eprint(fmt("cannot write ", name))
                return 1
            }
            parts += 1
            held = 0
        }
    }
    wav_ok := write_file(fmt(o.record_file, ".wav"), recording_wav(&rec))
    print("record:", frames, "frames of", o.still_w, "x", o.still_h, "in", parts, "chunks", fmt(o.record_file, ".000 ..."), "sound", wav_ok,
        "final mode", mode_name(rec.g.mode), "gems", rec.g.got)
    if o.debug {
        print("debug layer messages", r.messages)
    }
    renderer_close(r)
    0
}

fn run_test(o: Options) -> i64 {
    r, err := renderer_offscreen(TEST_W, TEST_H, true, o.debug)
    if err != "" {
        print(err)                         // the first line: tests/run.al shows it with SKIP
        return 77
    }
    h := headless_new(true)
    taken: [variant_count[Shot]()]bool
    wrong := 0
    for f in 0..14000 {
        headless_frame(&h)
        g := &h.g
        shot := Shot.ShotTitle
        want := false
        if f == 10 {
            want = true
        } else if f == 120 {
            shot = ShotPlay
            want = true
        } else if f == 340 {
            shot = ShotMenu
            want = true
        } else if !taken[i64(ShotWraith)] && g.mode == Playing && h.bot.games == 2 && near_wraith(g) {
            shot = ShotWraith
            want = true
        } else if !taken[i64(ShotWon)] && g.mode == Won && g.end_time > 1.2 {
            shot = ShotWon
            want = true
        } else if !taken[i64(ShotLost)] && g.mode == Lost && g.end_time > 1.2 {
            shot = ShotLost
            want = true
        }
        if !want || taken[i64(shot)] {
            continue
        }
        taken[i64(shot)] = true
        m := mark()
        img, rerr := render_frame(r, g, 0.5, "", true)
        if rerr != "" {
            print(rerr)
            return 1
        }
        wrong += check_shot(shot, img, f)
        if o.shots_dir != "" {
            png_save(path_join(o.shots_dir, fmt("crypt_", shot_name(shot), ".png")), img)
        }
        release(m)
    }
    headless_report(&h)
    renderer_close(r)
    for i in 0..variant_count[Shot]() {
        if !taken[i] {
            print("  WRONG: no picture of", shot_name(Shot(i)))
            wrong += 1
        }
    }
    if wrong == 0 { 0 } else { 1 }
}

// A wraith close in front of the player, for a picture of one.
priv fn near_wraith(g: *Game) -> bool {
    for i in 0..g.n_enemies {
        to := g.enemies[i].pos - g.pos
        if length(to) < 2.5 && dot(normalize(to), forward_of(g.yaw)) > 0.9 {
            return true
        }
    }
    false
}

// A check of a picture: at least `least` pixels of the rectangle x0..x1, y0..y1 pass `like`.
struct Probe { shot: Shot, x0: i64, y0: i64, x1: i64, y1: i64, least: i64, like: fn(vec4) -> bool, what: str }

priv fn yellow(c: vec4) -> bool { c.r > 0.8 && c.g > 0.75 && c.b < 0.4 }
priv fn white(c: vec4) -> bool { c.r > 0.85 && c.g > 0.85 && c.b > 0.85 }
priv fn red(c: vec4) -> bool { c.r > 0.7 && c.g < 0.3 && c.b < 0.3 }
priv fn green(c: vec4) -> bool { c.g > 0.7 && c.r < 0.5 && c.b < 0.5 }
priv fn grey(c: vec4) -> bool { c.r > 0.5 && fabs(c.r - c.g) < 0.05 && fabs(c.r - c.b) < 0.05 }
priv fn bright(c: vec4) -> bool { c.r > 0.75 && c.g > 0.75 && c.b > 0.75 }
priv fn stone(c: vec4) -> bool { c.b > c.r + 0.03 && c.r > 0.25 && c.r < 0.6 }
priv fn lit(c: vec4) -> bool { c.r + c.g + c.b > 0.6 }
priv fn dark(c: vec4) -> bool { c.r + c.g + c.b < 0.45 }
priv fn wraith(c: vec4) -> bool { c.b > c.r + 0.08 && c.b > c.g + 0.08 }

// The pictures are TEST_W x TEST_H, which is also the HUD's virtual size: HUD pixels are pixels.
const PROBES = [_]Probe{
    Probe{ShotTitle, 100, 40, 380, 100, 1500, yellow, "the title in large yellow letters"},
    Probe{ShotTitle, 40, 195, 440, 235, 300, grey, "the help lines in grey"},
    Probe{ShotPlay, 8, 8, 110, 24, 110, yellow, "GEMS 0/6 at the top left"},
    Probe{ShotPlay, 8, 28, 48, 38, 170, red, "three hearts"},
    Probe{ShotPlay, 236, 131, 245, 140, 10, bright, "the crosshair"},
    Probe{ShotPlay, 160, 80, 320, 190, 10000, lit, "lantern-lit walls in front"},
    Probe{ShotPlay, 120, 0, 330, 25, 4000, dark, "the dark ceiling"},
    Probe{ShotPlay, 418, 208, 474, 264, 300, stone, "the walls on the map"},
    Probe{ShotMenu, 250, 98, 320, 126, 300, white, "PAUSED"},
    Probe{ShotMenu, 140, 145, 240, 163, 100, yellow, "the selected menu line"},
    Probe{ShotWraith, 120, 40, 360, 240, 6000, wraith, "a wraith in front of the player"},
    Probe{ShotWon, 100, 65, 380, 100, 1500, green, "YOU ESCAPED"},
    Probe{ShotLost, 160, 65, 320, 100, 1000, red, "CAUGHT"},
}

// Checks the probes of one picture; prints one line per probe. Returns the number that failed.
priv fn check_shot(s: Shot, img: Image, f: i64) -> i64 {
    print("picture", shot_name(s), "frame", f)
    wrong := 0
    for p in PROBES {
        if p.shot != s {
            continue
        }
        n := 0
        for y in p.y0..p.y1 {
            for x in p.x0..p.x1 {
                if p.like(img.get(x, y)) {
                    n += 1
                }
            }
        }
        if n >= p.least {
            print("  ok", p.what)
        } else {
            print("  WRONG", p.what, "(", n, "pixels, want", p.least, ")")
            wrong += 1
        }
    }
    wrong
}
