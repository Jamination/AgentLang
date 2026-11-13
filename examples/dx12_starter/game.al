// The starter game (examples/starter) drawn with Direct3D 12 and heard through WASAPI: the same
// rules (../starter/logic.al), sprites from an atlas generated at start-up, sound effects and a
// music loop generated at start-up (sound.al), keyboard and gamepad. Windows only:
//
//   alc build --target windows --gui examples/dx12_starter/game.al     then run game.exe
//   game.exe --headless           no window, GPU or sound device: prints checksums (headless.al)
//
// Arrows / WASD / D-pad / left stick move, Space / pad A shoots, M music on / off, F11 or
// Alt+Enter fullscreen, Escape / pad Back quits; after the end, fire plays again. The game
// pauses while its window does not have the focus. More options: gamekit/options.al.
use std.window
use std.audio
use std.image
use "../starter/logic.al"
use "../gamekit/screen.al"
use "../gamekit/options.al"
use "sound.al"
use "headless.al"

const DISC_X = 0                 // the entity sprite in the atlas: a soft white disc
const DISC_Y = FONT_ATLAS_H
const DISC_SIZE = 16
const WHITE: u32 = 0xFFFFFFFF

// The atlas: the font, and below it a disc that every entity is drawn with, tinted.
fn make_atlas() -> (Image, Font) {
    img := image_new(FONT_ATLAS_W, FONT_ATLAS_H + DISC_SIZE, 4)
    font := font_bake(&img, 0, 0)
    c := f32(DISC_SIZE) / 2.0
    for y in 0..DISC_SIZE {
        for x in 0..DISC_SIZE {
            d := length(vec2(f32(x) + 0.5, f32(y) + 0.5) - vec2(c))
            a := clamp(c - d, 0.0, 1.0)                     // one pixel of soft edge
            img.set(DISC_X + x, DISC_Y + y, vec4(1.0, 1.0, 1.0, a))
        }
    }
    (img, font)
}

// Drawing only reads the game. `alpha` is how far the display is between two simulation steps.
fn render(sc: *Screen, font: Font, g: *Game, alpha: f32, paused: bool, audio_note: str) -> str {
    s := sc.screen_begin(0xFF201810)
    for i in 0..g.ents.len {
        if !g.ents.is_live(i) {
            continue
        }
        e := &g.ents.items[i]
        p := e.pos + e.vel * (alpha / f32(HZ))
        r := e.radius + 0.5
        s.sprite(p.x - r, p.y - r, 2.0 * r, 2.0 * r, f32(DISC_X), f32(DISC_Y), f32(DISC_SIZE), f32(DISC_SIZE), e.color)
    }
    draw_text(s, font, 4.0, 4.0, 1.0, fmt("SCORE ", g.score), WHITE)
    hp := fmt("HP ", player_hp(g))
    draw_text(s, font, f32(WORLD_W) - 4.0 - text_width(hp, 1.0), 4.0, 1.0, hp, 0xFF40E0FF)
    cx := f32(WORLD_W) / 2.0
    if g.over {
        draw_text_centered(s, font, cx, 70.0, 2.0, "GAME OVER", 0xFF4060FF)
        draw_text_centered(s, font, cx, 96.0, 1.0, "FIRE TO PLAY AGAIN, ESCAPE TO QUIT", WHITE)
    }
    if paused {
        s.sprite_rect(0.0, 0.0, f32(WORLD_W), f32(WORLD_H), 0x99000000)
        draw_text_centered(s, font, cx, 76.0, 2.0, "PAUSED", WHITE)
        draw_text_centered(s, font, cx, 100.0, 1.0, "CLICK THE WINDOW TO GO ON", WHITE)
    }
    if audio_note != "" {
        draw_text(s, font, 4.0, f32(WORLD_H) - 11.0, 1.0, audio_note, 0xFF60C0FF)
    }
    sc.screen_end()
}

fn run_window(o: GameOptions) {
    w, ok := window_open(WindowDesc{title: "AL starter (Direct3D 12)", width: WORLD_W * 3, height: WORLD_H * 3,
        resizable: true, fullscreen: o.fullscreen})
    if !ok {
        panic("cannot open a window")
    }
    atlas, font := make_atlas()
    sc, err := screen_open(w, WORLD_W, WORLD_H, atlas, 2048, o.warp)
    if err != "" {
        panic(err)
    }
    sc.vsync = o.vsync
    snd := starter_sound()
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
        // output: sound first (Present waits for the display), then the picture
        play_events(&snd, &g)
        snd.mixer.set_paused(snd.music_voice, paused || !snd.music_on)
        audio_pump(dev, snd.mixer)
        note := if dev != nil && dev.lost { "SOUND DEVICE LOST, RECONNECTING" } else { "" }
        rerr := render(sc, font, &g, steps.alpha(), paused, note)
        if rerr != "" {
            panic(rerr)
        }
        frames += 1
    }
    print("score", g.score, "frames", frames, "resizes", sc.resizes, "sound underruns", if dev == nil { 0 } else { dev.underruns })
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
        starter_headless(o.frames)
        return
    }
    run_window(o)
}
